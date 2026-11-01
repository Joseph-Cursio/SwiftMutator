#!/bin/bash
# The slow acceptance tier: whole SwiftMutator runs on a pinned SwiftProjectLint, checked mutant by mutant against
# the reference verdicts in reference/. See README.md.
#
#   slow-acceptance.sh [--scenarios a,b,...] [--work DIR]   run the scenarios (all by default) and check them
#   slow-acceptance.sh --preflight [--work DIR]             one run, stopped once its baseline passes
#   slow-acceptance.sh --reference N [--work DIR]           N full runs, and the reference made from them
#   slow-acceptance.sh --list                               the scenarios
#
# Everything happens in the work folder (by default ~/Library/Caches/SwiftMutatorSlowTier/<time>): a fresh clone of
# the target, the configurations, the runs' logs and reports. Exits 1 if a check fails, 2 if the setup does.
set -u -o pipefail
set -m # Each background run gets a process group of its own, which keeps SIGINT's default action: see `run_stopped`.

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=target.env
. "$HERE/target.env"
SCENARIOS="full release no-stop reuse-nochange reuse-testchange reuse-sourcechange stop-resume since"
MODE=check
REFERENCE_RUNS=0
WORK=""
MAX_LOAD=${MAX_LOAD:-4}

while [ $# -gt 0 ]; do
  case "$1" in
    --scenarios) SCENARIOS=$(echo "$2" | tr ',' ' '); shift 2 ;;
    --work) WORK=$2; shift 2 ;;
    --preflight) MODE=preflight; shift ;;
    --reference) MODE=reference; REFERENCE_RUNS=$2; shift 2 ;;
    --list) echo "$SCENARIOS"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

WORK=${WORK:-$HOME/Library/Caches/SwiftMutatorSlowTier/$(date +%Y%m%d-%H%M%S)}
CLONE=$WORK/SwiftProjectLint
BIN=$WORK/swift-mutator
REFERENCE=$HERE/reference/$PIN.json
RESOLVED=$HERE/reference/$PIN.Package.resolved
TIMES=$HERE/reference/$PIN-times.json
ALLOWLIST=$HERE/allowlist.json
RUNS=$WORK/runs.tsv
SUMMARY=$WORK/summary.md
FAILED=0

say() { echo "$(date +%T) $*" | tee -a "$WORK/driver.log" >&2; }
die() { say "SETUP FAILED: $*"; exit 2; }
verdicts() { python3 -I "$HERE/verdicts.py" "$@"; }
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
foreign_cpu() { ps -Ao pcpu=,args= | grep -v "$CLONE" | awk '{s+=$1} END {printf "%.0f", s}'; }

# MARK: - Setup

setup() {
  mkdir -p "$WORK/conf" "$WORK/logs" "$WORK/reports" || die "can't make $WORK"
  [ -f "$RUNS" ] || printf 'name\tstart\tend\twall_s\twait_s\tload_at_start\tload_mean\tforeign_cpu_mean\tstatus\tresults\n' > "$RUNS"
  say "work folder: $WORK"

  say "building swift-mutator (release) from $REPO_ROOT"
  (cd "$REPO_ROOT" && swift build -c release --product swift-mutator > "$WORK/logs/build.log" 2>&1) \
    || die "the build failed: $WORK/logs/build.log"
  cp "$REPO_ROOT/.build/release/swift-mutator" "$BIN" || die "no binary"

  if [ ! -d "$CLONE/.git" ]; then
    say "cloning $REPO at $PIN"
    git clone -q "$REPO" "$CLONE" || die "the clone failed"
    git -C "$CLONE" fetch -q origin "$PIN" || die "can't fetch $PIN"
    git -C "$CLONE" checkout -q --detach "$PIN" || die "can't check out $PIN"
  fi
  git -C "$CLONE" merge-base --is-ancestor "$PIN" origin/main || die "$PIN isn't on the target's main"

  if [ -f "$RESOLVED" ]; then
    cp "$RESOLVED" "$CLONE/Package.resolved"
    (cd "$CLONE" && swift package --only-use-versions-from-resolved-file resolve > "$WORK/logs/resolve.log" 2>&1) \
      || die "resolving from $RESOLVED failed: $WORK/logs/resolve.log"
    cmp -s "$RESOLVED" "$CLONE/Package.resolved" || die "resolving changed Package.resolved"
  elif [ "$MODE" = check ]; then
    die "no $RESOLVED: make the reference first (--reference N)"
  else
    (cd "$CLONE" && swift package resolve > "$WORK/logs/resolve.log" 2>&1) || die "resolve failed"
  fi

  # Outside the clone, so the reuse and resume checks never see them as project files.
  write_configuration full "$WORK/conf/full.yml"
  write_configuration release "$WORK/conf/release.yml"
  write_configuration no-stop "$WORK/conf/no-stop.yml"
  assert_clean
}

write_configuration() {
  local kind=$1 file=$2
  {
    echo "executable: /usr/bin/swift"
    echo "arguments:"
    echo "- test"
    if [ "$kind" = release ]; then printf -- '- -c\n- release\n- -Xswiftc\n- -enable-testing\n'; fi
    for test in "${SKIP_TESTS[@]}"; do printf -- '- --skip\n- %s\n' "$test"; done
    echo "exclude:"
    for exclude in "${EXCLUDES[@]}"; do echo "- '$exclude'"; done
    echo "excludeCalls: []"
    echo "mutationTestWorkers: $WORKERS"
    if [ "$kind" = no-stop ]; then echo "stopAtFirstFailure: false"; fi
  } > "$file"
}

# The clone as the pin has it: no scenario sees another's edits.
assert_clean() {
  local dirty
  dirty=$(git -C "$CLONE" status --porcelain --untracked-files=all | grep -v '^?? Package.resolved$')
  [ -z "$dirty" ] || die "the clone isn't the pin's tree:\n$dirty"
  [ ! -e "$CLONE/.build/debug" ] && [ ! -L "$CLONE/.build/debug" ] || die "the clone has a .build/debug link left"
}

# MARK: - Runs

# run NAME CONFIG [ARGUMENTS...]: `swift-mutator run` with CONFIG, from the clone, its report in the work folder.
run() {
  local name=$1 config=$2; shift 2
  launch "$name" run -c "$config" --skip-coverage --skip-update-check -o "$WORK/reports/$name.txt" "$@"
}

# launch NAME ARGUMENTS...: swift-mutator with ARGUMENTS, started once the machine is idle, under caffeinate. Sets
# RESULTS to its results file ("" if it wrote none) and STATUS to its exit status. STOP_AT, if set, stops it with
# SIGINT once its results file holds that many mutant lines, or with "header", once the header is there.
launch() {
  local name=$1; shift
  local waited_from start end sampler pid
  waited_from=$(date +%s)
  while [ "$(load1 | awk -v max="$MAX_LOAD" '{print ($1 < max)}')" != 1 ]; do sleep 30; done
  local load_at_start; load_at_start=$(load1)
  say "start $name (load $load_at_start, waited $(( $(date +%s) - waited_from ))s)"
  : > "$WORK/logs/$name.load"
  ( while :; do echo "$(load1) $(foreign_cpu)" >> "$WORK/logs/$name.load"; sleep 60; done ) &
  sampler=$!
  disown "$sampler" # so its kill below prints no job notice
  start=$(date +%s)
  (cd "$CLONE" && exec caffeinate -i "$BIN" "$@") > "$WORK/logs/$name.console" 2>&1 &
  pid=$!
  [ -n "${STOP_AT:-}" ] && stop_when "$name" "$pid" "$STOP_AT" &
  wait "$pid"; STATUS=$?
  end=$(date +%s)
  kill "$sampler" 2>/dev/null
  RESULTS=$(results_file "$WORK/logs/$name.console")
  local stats; stats=$(awk '{s+=$1; f+=$2; n++} END {if (n) printf "%.1f\t%.0f", s/n, f/n; else printf "-\t-"}' \
    "$WORK/logs/$name.load")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$start" "$end" "$((end - start))" \
    "$((start - waited_from))" "$load_at_start" "$stats" "$STATUS" "$RESULTS" >> "$RUNS"
  say "done $name: exit $STATUS, $(( (end - start) / 60 )) min, ${RESULTS:-no results file}"
}

# The results file a run's console names.
results_file() {
  sed -n 's/^💾 SwiftMutator saves each mutant.s result as it finishes, in //p' "$1" | tail -1
}

# stop_when NAME PID AT: sends SIGINT to the run's process group, as Ctrl-C does, once AT is reached.
stop_when() {
  local name=$1 pid=$2 at=$3 results lines
  while kill -0 "$pid" 2>/dev/null; do
    results=$(results_file "$WORK/logs/$name.console")
    if [ -n "$results" ] && [ -f "$results" ]; then
      if [ "$at" = header ]; then
        grep -q '"kind":"header"' "$results" && break
      else
        lines=$(grep -c '"kind":"mutant"' "$results")
        [ "$lines" -ge "$at" ] && break
      fi
    fi
    sleep 5
  done
  kill -INT -- "-$pid" 2>/dev/null
}

check() { # check NAME COMMAND...: one check, recorded in the summary.
  local name=$1; shift
  if verdicts "$@" > "$WORK/logs/$name.check" 2>&1; then
    echo "- ✅ $name" >> "$SUMMARY"
  else
    FAILED=1
    echo "- ❌ $name: see $WORK/logs/$name.check" >> "$SUMMARY"
    sed 's/^/    /' "$WORK/logs/$name.check" | head -40 >> "$SUMMARY"
  fi
  tail -n +1 "$WORK/logs/$name.check" | head -5 >&2
}

need_results() { # need_results NAME: fails the scenario when its run wrote no results.
  [ -n "$RESULTS" ] && [ -f "$RESULTS" ] && return 0
  FAILED=1
  echo "- ❌ $1: no results file (exit $STATUS); see $WORK/logs/$1.console" >> "$SUMMARY"
  return 1
}

restore() { git -C "$CLONE" checkout -q -- . && git -C "$CLONE" clean -fdq -e Package.resolved; }

# MARK: - Scenarios

FULL=""
full_results() { # The full run, which the reuse scenarios start from: this suite's own, made first if need be.
  [ -n "$FULL" ] || scenario_full
}

scenario_full() {
  run full "$WORK/conf/full.yml"
  need_results full && FULL=$RESULTS && check full check "$RESULTS" --reference "$REFERENCE" --allowlist "$ALLOWLIST"
}

# Release-mode tests look for the CLI in .build/debug, which links to the release products during this run only.
scenario_release() {
  ln -s out/Products/Release "$CLONE/.build/debug" || die "can't link .build/debug"
  run release "$WORK/conf/release.yml"
  rm -f "$CLONE/.build/debug"
  need_results release && check release check "$RESULTS" --reference "$REFERENCE" --allowlist "$ALLOWLIST"
}

scenario_no_stop() {
  run no-stop "$WORK/conf/no-stop.yml"
  need_results no-stop && check no-stop check "$RESULTS" --reference "$REFERENCE" --allowlist "$ALLOWLIST"
}

scenario_reuse_nochange() {
  full_results
  run reuse-nochange "$WORK/conf/full.yml" --reuse "$FULL"
  need_results reuse-nochange || return
  check reuse-nochange check "$RESULTS" --reference "$REFERENCE" --allowlist "$ALLOWLIST"
  check reuse-nochange-kept expect-reuse "$FULL" "$RESULTS"
}

# The suites of a test file whose tests alone killed some mutants are disabled: those kills must be tested again, and
# become what a full run of the edited tree finds; other files' kills are kept.
scenario_reuse_testchange() {
  full_results
  python3 -I - "$CLONE/$TEST_CHANGE_FILE" <<'EOF' || die "can't disable $TEST_CHANGE_FILE's suites"
import re, sys
path = sys.argv[1]
text = open(path).read()
disabled = re.sub(r'@Suite\b(\((.*?)\))?', lambda m: f'@Suite({m.group(2) + ", " if m.group(2) else ""}.disabled("slow tier"))', text)
if disabled == text:
    sys.exit(f"{path} has no @Suite")
open(path, "w").write(disabled)
EOF
  run reuse-testchange "$WORK/conf/full.yml" --reuse "$FULL"
  local reuse=$RESULTS
  run full-testchange "$WORK/conf/full.yml"
  local fresh=$RESULTS
  restore
  need_results reuse-testchange && [ -n "$fresh" ] && check reuse-testchange expect-test-change "$FULL" "$reuse" \
    "$fresh" --test-file "$TEST_CHANGE_FILE" --allowlist "$ALLOWLIST"
}

# A comment at the end of a source file with no mutants, which no test reads: a plain reuse plans to test everything
# again; with --reuse-ignoring it keeps what a reuse with nothing changed keeps.
scenario_reuse_sourcechange() {
  full_results
  printf '\n// The slow acceptance tier changed this file.\n' >> "$CLONE/$SOURCE_CHANGE_FILE"
  STOP_AT=header run reuse-sourcechange "$WORK/conf/full.yml" --reuse "$FULL"
  local plain=$RESULTS
  run reuse-sourcechange-ignoring "$WORK/conf/full.yml" --reuse "$FULL" --reuse-ignoring "$SOURCE_CHANGE_FILE"
  restore
  [ -n "$plain" ] && check reuse-sourcechange expect-none-reused "$plain"
  need_results reuse-sourcechange-ignoring || return
  check reuse-sourcechange-ignoring check "$RESULTS" --reference "$REFERENCE" --allowlist "$ALLOWLIST"
  check reuse-sourcechange-ignoring-kept expect-reuse "$FULL" "$RESULTS" --waived "$SOURCE_CHANGE_FILE"
}

# Stopped by SIGINT a third of the way through, then continued with the Continue line it printed.
scenario_stop_resume() {
  local discovered
  discovered=$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["mutants"]))' "$REFERENCE")
  STOP_AT=$((discovered / 3)) run stop-resume "$WORK/conf/full.yml"
  if [ "$STATUS" -ne 130 ] || ! need_results stop-resume; then
    FAILED=1; echo "- ❌ stop-resume: the stopped run exited $STATUS, not 130 (SIGINT)" >> "$SUMMARY"; return
  fi
  local continue_line
  continue_line=$(sed -n 's/.*▶️ Continue: swift-mutator //p' "$WORK/logs/stop-resume.console" | tail -1)
  [ -n "$continue_line" ] || { FAILED=1; echo "- ❌ stop-resume: no Continue line" >> "$SUMMARY"; return; }
  local stopped=$RESULTS
  # As a user would: the command it printed, whose words it quoted for the shell.
  eval "launch stop-resume-continued $continue_line"
  check stop-resume expect-stop-resume "$stopped" --reference "$REFERENCE" --allowlist "$ALLOWLIST"
}

# --since --changed-lines from SINCE_BASE: between what git's own diff requires and the changed files. And --since the
# pin itself, which changes nothing: nothing to mutate, exit 0, no results file.
scenario_since() {
  local base
  base=$(git -C "$CLONE" merge-base "$SINCE_BASE" HEAD) || die "no merge base for $SINCE_BASE"
  git -C "$CLONE" diff -U0 --no-renames "$base" -- '*.swift' > "$WORK/logs/since.diff"
  run since "$WORK/conf/full.yml" --since "$SINCE_BASE" --changed-lines
  local excludes=(); for e in "${EXCLUDES[@]}"; do excludes+=(--exclude "$e"); done
  need_results since && check since expect-since "$RESULTS" --reference "$REFERENCE" --diff "$WORK/logs/since.diff" \
    "${excludes[@]}" --allowlist "$ALLOWLIST"
  run since-nothing "$WORK/conf/full.yml" --since HEAD
  if [ "$STATUS" -eq 0 ] && [ -z "$RESULTS" ] && grep -q "No Swift file changed" "$WORK/logs/since-nothing.console"; then
    echo "- ✅ since-nothing" >> "$SUMMARY"
  else
    FAILED=1; echo "- ❌ since-nothing: exit $STATUS, results ${RESULTS:-none}" >> "$SUMMARY"
  fi
}

# MARK: - Modes

preflight() {
  STOP_AT=1 run preflight "$WORK/conf/full.yml"
  if [ -n "$RESULTS" ] && grep -q '"kind":"header"' "$RESULTS"; then
    say "preflight: the baseline passed with this configuration"
  else
    say "preflight: the baseline failed; see $WORK/logs/preflight.console and the baseline log it names"
    exit 1
  fi
}

reference() {
  local runs=()
  for i in $(seq 1 "$REFERENCE_RUNS"); do
    run "reference-$i" "$WORK/conf/full.yml"
    [ -n "$RESULTS" ] || die "reference run $i wrote no results"
    runs+=("$RESULTS")
  done
  mkdir -p "$HERE/reference"
  cp "$CLONE/Package.resolved" "$RESOLVED"
  verdicts reference "${runs[@]}" --pin "$PIN" --resolved-sha256 "$(shasum -a 256 "$RESOLVED" | cut -d' ' -f1)" \
    --allowlist "$ALLOWLIST" --out "$REFERENCE" || exit 1
  awk 'NR == 1 || /^reference-/' "$RUNS" | sed 's/^reference-[0-9]*/full/' > "$WORK/full-runs.tsv"
  verdicts times "$WORK/full-runs.tsv" --baseline "$TIMES" --update
  say "a test file to disable for reuse-testchange: $(cd "$CLONE" && verdicts pick-test-change "${runs[0]}" \
    $(git ls-files 'Tests/*Tests.swift'))"
}

setup
case "$MODE" in
  preflight) preflight ;;
  reference) reference ;;
  check)
    [ -f "$REFERENCE" ] || die "no reference for $PIN: run --reference N first"
    echo "# Slow acceptance tier: $(date)" > "$SUMMARY"
    echo "" >> "$SUMMARY"
    echo "SwiftMutator $(git -C "$REPO_ROOT" rev-parse --short HEAD), target $PIN" >> "$SUMMARY"
    echo "" >> "$SUMMARY"
    for scenario in $SCENARIOS; do
      assert_clean
      "scenario_$(echo "$scenario" | tr '-' '_')"
    done
    { echo ""; echo "## Times"; echo '```'; verdicts times "$RUNS" --baseline "$TIMES"; echo '```'; } >> "$SUMMARY"
    cat "$SUMMARY"
    exit "$FAILED"
    ;;
esac
