#!/bin/bash
# The slow acceptance tier: whole SwiftMutator runs on pinned projects, the targets in targets/, checked mutant by
# mutant against the reference verdicts in reference/. See README.md.
#
#   slow-acceptance.sh [--target T] [--scenarios a,b,...] [--work DIR]   run the scenarios (all by default) and check them
#   slow-acceptance.sh [--target T] --preflight [--work DIR]             one run, stopped once its baseline passes
#   slow-acceptance.sh [--target T] --reference N [--work DIR]           N full runs, and the reference made from them
#   slow-acceptance.sh [--target T] --list                               the target's scenarios
#   slow-acceptance.sh --targets                                         the targets
#   slow-acceptance.sh [--target T] --print-configuration KIND           a configuration, written as a run gets it
#
# A target is a file in targets/: swiftprojectlint by default. Everything happens in the work folder (by default
# ~/Library/Caches/SwiftMutatorSlowTier/<time>-<target>): a fresh clone of the target, the configurations, the runs'
# logs and reports. Exits 1 if a check fails, 2 if the setup does.
set -u -o pipefail
set -m # Each background run gets a process group of its own, which keeps SIGINT's default action: see `stop_when`.
# Awake from start to end, the waits between runs included: once the Mac sleeps, a run goes on only in short dark
# wakes, and its tests time out on the time spent asleep.
if [ -z "${SLOW_TIER_AWAKE:-}" ]; then SLOW_TIER_AWAKE=1 exec caffeinate -i -s "$0" "$@"; fi

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
SCENARIOS="full release no-stop reuse-nochange reuse-testchange reuse-sourcechange stop-resume since"
MODE=check
REFERENCE_RUNS=0
WORK=""
TARGET=swiftprojectlint
LIST=""
MAX_LOAD=${MAX_LOAD:-4}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET=$2; shift 2 ;;
    --scenarios) SCENARIOS=$(echo "$2" | tr ',' ' '); shift 2 ;;
    --work) WORK=$2; shift 2 ;;
    --preflight) MODE=preflight; shift ;;
    --reference) MODE=reference; REFERENCE_RUNS=$2; shift 2 ;;
    --list) LIST=1; shift ;;
    --print-configuration) MODE=print; PRINT_KIND=$2; shift 2 ;; # for the self-test: full, release or no-stop
    --targets) for file in "$HERE"/targets/*.env; do basename "$file" .env; done; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -f "$HERE/targets/$TARGET.env" ] || { echo "no target $TARGET: see --targets" >&2; exit 2; }
# What a target's file may set, with the values a SwiftPM target on main takes. Arrays stay empty unless it sets them.
BRANCH=main
BUILD_SYSTEM=swift        # swift: `swift test`; xcodebuild: XCODEBUILD_ARGUMENTS, then `test`
XCODEBUILD_ARGUMENTS=()   # an xcodebuild target's arguments for every run but the release scenario's
XCODEBUILD_RELEASE_ARGUMENTS=()
PINS_PACKAGES=yes         # whether the target's Package.resolved is kept in reference/ (no: it has no dependencies)
RELEASE_DEBUG_LINK=""     # where the release scenario points .build/debug, for tests that look for products there
TEST_CHANGE_EDIT=suites   # suites: disable each @Suite; xctest: rename each XCTest `func test…`
TEST_FILES_GLOB='Tests/*Tests.swift'
NOT_APPLICABLE=()         # "scenario: why", for scenarios the target can't take
SKIP_TESTS=() EXCLUDES=() OPERATORS=()
TEST_CHANGE_FILE="" SOURCE_CHANGE_FILE="" SINCE_BASE="" REFERENCE_STEM=""
# shellcheck source=targets/swiftprojectlint.env
. "$HERE/targets/$TARGET.env"
REFERENCE_STEM=${REFERENCE_STEM:-$PIN}

# not_applicable SCENARIO: why the target can't take it, or nothing.
not_applicable() {
  local entry
  for entry in ${NOT_APPLICABLE[@]+"${NOT_APPLICABLE[@]}"}; do
    [ "${entry%%:*}" = "$1" ] && { echo "${entry#*: }"; return; }
  done
}
if [ -n "$LIST" ]; then
  for scenario in $SCENARIOS; do
    why=$(not_applicable "$scenario"); echo "$scenario${why:+ (not applicable: $why)}"
  done
  exit 0
fi

WORK=${WORK:-$HOME/Library/Caches/SwiftMutatorSlowTier/$(date +%Y%m%d-%H%M%S)-$TARGET}
CLONE=$WORK/$(basename "$REPO" .git)
BIN=$WORK/swift-mutator
REFERENCE=$HERE/reference/$REFERENCE_STEM.json
RESOLVED=$HERE/reference/$REFERENCE_STEM.Package.resolved
TIMES=$HERE/reference/$REFERENCE_STEM-times.json
ALLOWLIST=$HERE/targets/$TARGET.allowlist.json
# --allowlist ALLOWLIST when the target has one.
ALLOW=(); [ -f "$ALLOWLIST" ] && ALLOW=(${ALLOW[@]+"${ALLOW[@]}"})
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
  # One target a work folder: its clone, configurations and runs are that target's. One with no stamp predates targets.
  local stamped=$TARGET
  if [ -f "$WORK/target" ]; then stamped=$(cat "$WORK/target")
  elif [ -f "$RUNS" ]; then stamped=swiftprojectlint
  fi
  [ "$stamped" = "$TARGET" ] || die "$WORK is a work folder for $stamped, not $TARGET"
  echo "$TARGET" > "$WORK/target"
  [ -f "$RUNS" ] || printf 'name\tstart\tend\twall_s\twait_s\tload_at_start\tload_mean\tforeign_cpu_mean\tstatus\tresults\tworkers\n' > "$RUNS"
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
  git -C "$CLONE" merge-base --is-ancestor "$PIN" "origin/$BRANCH" || die "$PIN isn't on the target's $BRANCH"
  # A work folder made for another pin would test that pin's tree.
  [ "$(git -C "$CLONE" rev-parse HEAD)" = "$(git -C "$CLONE" rev-parse "$PIN^{commit}")" ] \
    || die "the clone in $WORK is at another commit than $PIN: use a new work folder"

  if [ "$PINS_PACKAGES" = no ]; then
    : # no dependencies to resolve
  elif [ -f "$RESOLVED" ]; then
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
  [ -n "$(not_applicable no-stop)" ] || write_configuration no-stop "$WORK/conf/no-stop.yml"
  assert_clean
}

write_configuration() {
  local kind=$1 file=$2 argument
  {
    if [ "$BUILD_SYSTEM" = xcodebuild ]; then
      echo "executable: /usr/bin/xcodebuild"
      echo "arguments:"
      if [ "$kind" = release ]; then
        for argument in "${XCODEBUILD_RELEASE_ARGUMENTS[@]}"; do yaml_item "$argument"; done
      else
        for argument in "${XCODEBUILD_ARGUMENTS[@]}"; do yaml_item "$argument"; done
      fi
      for test in ${SKIP_TESTS[@]+"${SKIP_TESTS[@]}"}; do yaml_item "-skip-testing:$test"; done
      echo "- test"
    else
      echo "executable: /usr/bin/swift"
      echo "arguments:"
      echo "- test"
      if [ "$kind" = release ]; then printf -- '- -c\n- release\n- -Xswiftc\n- -enable-testing\n'; fi
      for test in ${SKIP_TESTS[@]+"${SKIP_TESTS[@]}"}; do printf -- '- --skip\n- %s\n' "$test"; done
    fi
    if [ ${#EXCLUDES[@]} -eq 0 ]; then echo "exclude: []"; else echo "exclude:"; fi
    for exclude in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do echo "- '$exclude'"; done
    echo "excludeCalls: []"
    echo "operators:"
    for operator in "${OPERATORS[@]}"; do echo "- $operator"; done
    echo "mutationTestWorkers: $WORKERS"
    if [ "$kind" = no-stop ]; then echo "stopAtFirstFailure: false"; fi
  } > "$file"
}

# yaml_item VALUE: a YAML sequence item, quoted only when a plain scalar couldn't hold it.
yaml_item() {
  case "$1" in
    *[!A-Za-z0-9_./=,:+-]*|[!A-Za-z0-9./-]*|*:|*': '*) printf -- "- '%s'\n" "$(printf %s "$1" | sed "s/'/''/g")" ;;
    *) printf -- '- %s\n' "$1" ;;
  esac
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
  local mode; mode=$(workers_mode "$WORK/logs/$name.console" "$RESULTS")
  local stats; stats=$(awk '{s+=$1; f+=$2; n++} END {if (n) printf "%.1f\t%.0f", s/n, f/n; else printf "-\t-"}' \
    "$WORK/logs/$name.load")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$start" "$end" "$((end - start))" \
    "$((start - waited_from))" "$load_at_start" "$stats" "$STATUS" "$RESULTS" "$mode" >> "$RUNS"
  say "done $name: exit $STATUS, $(( (end - start) / 60 )) min, workers $mode, ${RESULTS:-no results file}"
}

# The results file a run's console names.
results_file() {
  sed -n 's/^💾 SwiftMutator saves each mutant.s result as it finishes, in //p' "$1" | tail -1
}

# How a run's workers tested, as its console says: from one build ("shared"), each from a clone of its own
# ("clones"), one mutant at a time ("one"), or "-" when it tested no mutant. The choice is SwiftMutator's own, made
# from the run with no mutant on. One worker, as on an xcodebuild Mac destination, may print no line, so its results
# header says.
workers_mode() {
  if grep -q 'mutants at a time, from one build' "$1"; then echo shared
  elif grep -q 'mutants at a time' "$1"; then echo clones
  elif grep -q 'one mutant at a time' "$1" || { [ -n "${2:-}" ] && [ -f "$2" ] && grep -q '"kind":"mutant"' "$2" \
    && head -1 "$2" | grep -q '"workers":1[,}]'; }; then echo one
  else echo -
  fi
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

real_path() { echo "$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"; }

restore() { git -C "$CLONE" checkout -q -- . && git -C "$CLONE" clean -fdq -e Package.resolved; }

# MARK: - Scenarios

FULL=""
full_results() { # The full run, which the reuse scenarios start from: this suite's own, made first if need be.
  [ -n "$FULL" ] || scenario_full
}

scenario_full() {
  run full "$WORK/conf/full.yml"
  need_results full && FULL=$RESULTS && check full check "$RESULTS" --reference "$REFERENCE" ${ALLOW[@]+"${ALLOW[@]}"}
}

# Release-mode tests that look for products in .build/debug get a link there to the release products, during this run
# only (RELEASE_DEBUG_LINK).
scenario_release() {
  if [ -n "$RELEASE_DEBUG_LINK" ]; then ln -s "$RELEASE_DEBUG_LINK" "$CLONE/.build/debug" || die "can't link .build/debug"; fi
  run release "$WORK/conf/release.yml"
  rm -f "$CLONE/.build/debug"
  need_results release && check release check "$RESULTS" --reference "$REFERENCE" ${ALLOW[@]+"${ALLOW[@]}"}
}

scenario_no_stop() {
  run no-stop "$WORK/conf/no-stop.yml"
  need_results no-stop && check no-stop check "$RESULTS" --reference "$REFERENCE" ${ALLOW[@]+"${ALLOW[@]}"}
}

scenario_reuse_nochange() {
  full_results
  run reuse-nochange "$WORK/conf/full.yml" --reuse "$FULL"
  need_results reuse-nochange || return
  check reuse-nochange check "$RESULTS" --reference "$REFERENCE" ${ALLOW[@]+"${ALLOW[@]}"}
  check reuse-nochange-kept expect-reuse "$FULL" "$RESULTS"
}

# The suites of a test file whose tests alone killed some mutants are disabled: those kills must be tested again, and
# become what a full run of the edited tree finds; other files' kills are kept.
scenario_reuse_testchange() {
  full_results
  python3 -I - "$CLONE/$TEST_CHANGE_FILE" "$TEST_CHANGE_EDIT" <<'EOF' || die "can't disable $TEST_CHANGE_FILE's tests"
import re, sys
path, edit = sys.argv[1:]
text = open(path).read()
if edit == "xctest":  # XCTest runs only the methods whose names start with "test"
    disabled = re.sub(r'\bfunc test(\w*)\s*\(', r'func disabled_test\1(', text)
else:
    disabled = re.sub(r'@Suite\b(\((.*?)\))?', lambda m: f'@Suite({m.group(2) + ", " if m.group(2) else ""}.disabled("slow tier"))', text)
if disabled == text:
    sys.exit(f"{path} has nothing to disable as {edit}")
open(path, "w").write(disabled)
EOF
  run reuse-testchange "$WORK/conf/full.yml" --reuse "$FULL"
  local reuse=$RESULTS reuse_status=$STATUS
  run full-testchange "$WORK/conf/full.yml"
  local fresh=$RESULTS fresh_status=$STATUS
  restore
  # Each run under its own name, so a missing file is never another run's, and neither check is skipped unsaid.
  local ok=1
  RESULTS=$reuse STATUS=$reuse_status need_results reuse-testchange || ok=0
  RESULTS=$fresh STATUS=$fresh_status need_results full-testchange || ok=0
  [ "$ok" = 1 ] && check reuse-testchange expect-test-change "$FULL" "$reuse" "$fresh" --test-file "$TEST_CHANGE_FILE" \
    $([ "$TEST_CHANGE_EDIT" = xctest ] && echo --kills-never-hold) \
    ${ALLOW[@]+"${ALLOW[@]}"}
}

# A comment at the end of a source file with no mutants, which no test reads: a plain reuse plans to test everything
# again; with --reuse-ignoring it keeps what a reuse with nothing changed keeps.
scenario_reuse_sourcechange() {
  full_results
  printf '\n// The slow acceptance tier changed this file.\n' >> "$CLONE/$SOURCE_CHANGE_FILE"
  STOP_AT=header run reuse-sourcechange "$WORK/conf/full.yml" --reuse "$FULL"
  local plain=$RESULTS plain_status=$STATUS
  run reuse-sourcechange-ignoring "$WORK/conf/full.yml" --reuse "$FULL" --reuse-ignoring "$SOURCE_CHANGE_FILE"
  restore
  RESULTS=$plain STATUS=$plain_status need_results reuse-sourcechange \
    && check reuse-sourcechange expect-none-reused "$plain"
  need_results reuse-sourcechange-ignoring || return
  check reuse-sourcechange-ignoring check "$RESULTS" --reference "$REFERENCE" ${ALLOW[@]+"${ALLOW[@]}"}
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
  # A refused or failed resume would otherwise show as hundreds of mutants neither session tested.
  if [ "$STATUS" -ne 0 ] || [ -z "$RESULTS" ] || [ "$(real_path "$RESULTS")" != "$(real_path "$stopped")" ]; then
    FAILED=1
    echo "- ❌ stop-resume: the continued run exited $STATUS, results ${RESULTS:-none}, not $stopped's; see" \
      "$WORK/logs/stop-resume-continued.console" >> "$SUMMARY"
    return
  fi
  check stop-resume expect-stop-resume "$stopped" --reference "$REFERENCE" ${ALLOW[@]+"${ALLOW[@]}"}
}

# --since --changed-lines from SINCE_BASE: between what git's own diff requires and the changed files. And --since the
# pin itself, which changes nothing: nothing to mutate, exit 0, no results file.
scenario_since() {
  local base
  base=$(git -C "$CLONE" merge-base "$SINCE_BASE" HEAD) || die "no merge base for $SINCE_BASE"
  git -C "$CLONE" diff -U0 --no-renames "$base" -- '*.swift' > "$WORK/logs/since.diff"
  run since "$WORK/conf/full.yml" --since "$SINCE_BASE" --changed-lines
  local excludes=(); for e in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do excludes+=(--exclude "$e"); done
  need_results since && check since expect-since "$RESULTS" --reference "$REFERENCE" --diff "$WORK/logs/since.diff" \
    ${excludes[@]+"${excludes[@]}"} ${ALLOW[@]+"${ALLOW[@]}"}
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

# kept_run NAME: the results file of an earlier run NAME in this work folder that exited 0 with today's binary and
# today's full.yml, or nothing. A reference the checker refuses then costs only its verdicts once the target's allowlist
# explains the refusal: the runs themselves are kept.
kept_run() {
  local name=$1 results
  results=$(awk -F'\t' -v name="$1" '$1 == name && $9 == 0 {print $10}' "$RUNS" | tail -1)
  [ -n "$results" ] && [ -f "$results" ] && cmp -s "$WORK/logs/$name.yml" "$WORK/conf/full.yml" || return 0
  [ "$(head -1 "$results" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["provenance"]["swiftMutator"]["executableSHA256"])')" \
    = "$(shasum -a 256 "$BIN" | cut -d' ' -f1)" ] && echo "$results"
}

reference() {
  local runs=() name kept
  for i in $(seq 1 "$REFERENCE_RUNS"); do
    name=reference-$i
    kept=$(kept_run "$name")
    if [ -n "$kept" ]; then
      say "keeping $name, made with this binary and configuration: $kept"
      runs+=("$kept")
      continue
    fi
    # Recorded only once the run finishes: a run of this name stopped or failed later must not vouch for an older one.
    rm -f "$WORK/logs/$name.yml"
    run "$name" "$WORK/conf/full.yml"
    [ -n "$RESULTS" ] || die "reference run $i wrote no results"
    [ "$STATUS" -ne 0 ] || cp "$WORK/conf/full.yml" "$WORK/logs/$name.yml"
    runs+=("$RESULTS")
  done
  mkdir -p "$HERE/reference"
  local resolved_sha256=none
  if [ "$PINS_PACKAGES" != no ]; then
    cp "$CLONE/Package.resolved" "$RESOLVED"
    resolved_sha256=$(shasum -a 256 "$RESOLVED" | cut -d' ' -f1)
  fi
  verdicts reference "${runs[@]}" --pin "$PIN" --resolved-sha256 "$resolved_sha256" \
    --operators "${OPERATORS[@]}" ${ALLOW[@]+"${ALLOW[@]}"} --out "$REFERENCE" || exit 1
  # The times of the runs that made it, not of earlier runs of the same name.
  { head -1 "$RUNS"; for results in "${runs[@]}"; do awk -F'\t' -v r="$results" '$10 == r' "$RUNS" | tail -1; done; } \
    | sed 's/^reference-[0-9]*/full/' > "$WORK/full-runs.tsv"
  rm -f "$TIMES" # a new reference, so every scenario's time is recorded again
  verdicts times "$WORK/full-runs.tsv" --baseline "$TIMES" --update
  [ -n "$(not_applicable reuse-testchange)" ] && return
  # Test files' paths have no spaces in a target worth choosing; one that has would be split here.
  # shellcheck disable=SC2046
  say "a test file to disable for reuse-testchange: $(cd "$CLONE" && verdicts pick-test-change "${runs[0]}" \
    $([ "$TEST_CHANGE_EDIT" = xctest ] && echo --xctest) $(git ls-files "$TEST_FILES_GLOB"))"
}

if [ "$MODE" = print ]; then write_configuration "$PRINT_KIND" /dev/stdout; exit 0; fi
setup
case "$MODE" in
  preflight) preflight ;;
  reference) reference ;;
  check)
    [ -f "$REFERENCE" ] || die "no reference for $TARGET at $PIN: run --reference N first"
    # Hours of runs would each fail on every mutant: say so before the first.
    verdicts expect-operators "$REFERENCE" "${OPERATORS[@]}" >&2 || die "make a new reference (README)"
    echo "# Slow acceptance tier, $TARGET: $(date)" > "$SUMMARY"
    echo "" >> "$SUMMARY"
    echo "SwiftMutator $(git -C "$REPO_ROOT" rev-parse --short HEAD), target $TARGET ($BUILD_SYSTEM) at $PIN" >> "$SUMMARY"
    echo "" >> "$SUMMARY"
    for scenario in $SCENARIOS; do
      why=$(not_applicable "$scenario")
      if [ -n "$why" ]; then echo "- ⏭️ $scenario: not applicable to $TARGET: $why" >> "$SUMMARY"; continue; fi
      assert_clean
      "scenario_$(echo "$scenario" | tr '-' '_')"
    done
    { echo ""; echo "## Times"; echo '```'; verdicts times "$RUNS" --baseline "$TIMES"; echo '```'; } >> "$SUMMARY"
    cat "$SUMMARY"
    exit "$FAILED"
    ;;
esac
