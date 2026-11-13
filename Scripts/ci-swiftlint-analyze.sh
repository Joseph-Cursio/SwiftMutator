#!/usr/bin/env bash
# Runs one of SwiftLint's analyzer rules over this package, from the compiler log of a `swift build --build-tests -v`,
# and fails unless SwiftLint analyzed every file it was given: a file the log holds no compile command for is dropped
# without a word. CI's "SwiftLint analyzer" job runs it; ../SwiftLintConfig/scripts/swiftlint-analyze.sh is the way to
# run every rule locally.
#
#   Scripts/ci-swiftlint-analyze.sh <compile.log> <rule> all [--jobs N]
#   Scripts/ci-swiftlint-analyze.sh <compile.log> <rule> changed-since <commit> [--jobs N]
#
# `all` is every file .swiftlint.yml lints; `changed-since` those of them changed, added or renamed since <commit>.
# --jobs N runs N SwiftLint processes at once, each over a share of the files: only for a rule that looks at one file
# at a time, as unused_import does. A collecting rule (capture_variable, unused_declaration) needs every file at once.
# SWIFTLINT_REPORTER picks SwiftLint's reporter (default: xcode).
set -euo pipefail

die() { echo "error: $*" >&2; exit 2; }
usage() { sed -n '7,8p' "$0" | sed 's/^# *//' >&2; exit 2; }

[ $# -ge 3 ] || usage
[ -f "$1" ] || die "No compiler log at $1."
log="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
rule=$2
scope=$3
shift 3
base=""
if [ "$scope" = changed-since ]; then
    [ $# -ge 1 ] || usage
    base=$1
    shift
elif [ "$scope" != all ]; then
    usage
fi
jobs=1
while [ $# -gt 0 ]; do
    case $1 in
        --jobs) [ $# -ge 2 ] || usage; jobs=$2; shift 2 ;;
        *) usage ;;
    esac
done
case $jobs in '' | *[!0-9]* | 0) die "--jobs takes a whole number, at least 1." ;; esac
case $rule in
    capture_variable | unused_declaration)
        [ "$jobs" = 1 ] || die "$rule collects across files: it can't be split between processes." ;;
esac
[ -f Package.swift ] && [ -f .swiftlint.yml ] || die "Run from the package's root."
reporter=${SWIFTLINT_REPORTER:-xcode}

# .swiftlint.yml's `included` takes the place of any paths given on the command line, and a relative path given there
# is dropped, so the rule runs with a config of the shared rules alone, over absolute paths listed here from
# `included` and `excluded`. Any other key would be lost that way.
others=$(grep -vE '^(#.*|[[:space:]]*|  - .*|parent_config: .*|included:|excluded:)$' .swiftlint.yml || true)
[ -z "$others" ] || die ".swiftlint.yml has keys this script doesn't carry over: $others"
parent=$(awk '$1 == "parent_config:" { print $2 }' .swiftlint.yml)
[ -f "$parent" ] || die "No shared config at $parent."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf 'parent_config: %s/%s\n' "$(cd "$(dirname "$parent")" && pwd)" "$(basename "$parent")" > "$work/analyze.yml"

listed() { awk -v key="$1:" '$1 == key { f = 1; next } f && /^  - / { print $2; next } f { f = 0 }' .swiftlint.yml; }

# Every Swift file under `included` and not under `excluded`, relative to the package's root, sorted.
listed included > "$work/included"
listed excluded > "$work/excluded"
[ -s "$work/included" ] || die ".swiftlint.yml includes nothing."
while read -r path; do
    if [ -e "$path" ]; then find "$path" -type f -name '*.swift'; fi
done < "$work/included" | while read -r file; do
    kept=yes
    while read -r excluded; do
        case $file in "$excluded" | "$excluded"/*) kept=no ;; esac
    done < "$work/excluded"
    if [ $kept = yes ]; then echo "$file"; fi
done | LC_ALL=C sort -u > "$work/lintable"

# The listing must be what SwiftLint itself lints, or a file could go unanalyzed with every count still matching.
linted=$(swiftlint lint --only-rule trailing_newline 2>&1 >/dev/null | sed -n 's/^Done linting!.* in \([0-9]*\) files*\.$/\1/p' | tail -n 1 || true)
listing=$(wc -l < "$work/lintable" | tr -d ' ')
[ "$linted" = "$listing" ] || die "swiftlint lint lints ${linted:-no} files, and this script listed $listing."

if [ "$scope" = all ]; then
    cp "$work/lintable" "$work/files"
else
    # Unquoted, as find lists them: git otherwise quotes a path with a byte above 0x7F, which then matches nothing.
    git -c core.quotePath=false diff --name-only --diff-filter=AMR "$base" HEAD | LC_ALL=C sort -u > "$work/changed"
    LC_ALL=C comm -12 "$work/lintable" "$work/changed" > "$work/files"
fi
count=$(wc -l < "$work/files" | tr -d ' ')
if [ "$count" = 0 ]; then
    echo "$rule: no Swift file to analyze."
    exit 0
fi
[ "$jobs" -le "$count" ] || jobs=$count
echo "$rule: analyzing $count files ($scope${base:+ $base}) in $jobs process(es)."

# Each process gets every jobs-th file, so that each share has files from every folder.
awk -v n="$jobs" -v dir="$work" '{ print > (dir "/share." (NR % n)) }' "$work/files"
pids=()
shares=()
for share in "$work"/share.*; do
    files=()
    while read -r file; do files+=("$PWD/$file"); done < "$share"
    swiftlint analyze --config "$work/analyze.yml" --strict --reporter "$reporter" \
        --compiler-log-path "$log" --only-rule "$rule" -- "${files[@]}" > "$share.out" 2> "$share.err" &
    pids+=("$!")
    shares+=("$share")
done

status=0
for index in "${!pids[@]}"; do
    share=${shares[$index]}
    if ! wait "${pids[$index]}"; then status=1; fi
    cat "$share.out"
    given=$(wc -l < "$share" | tr -d ' ')
    analyzed=$(sed -n 's/^Done analyzing!.* in \([0-9]*\) files*\.$/\1/p' "$share.err" | tail -n 1)
    if [ "$analyzed" != "$given" ]; then
        echo "error: $rule analyzed ${analyzed:-no} of the $given files it was given: the compiler log holds no" \
            "compile command for the others. SwiftLint said:" >&2
        # Nothing but progress, from a process that died, leaves grep nothing to print: that mustn't end the loop.
        grep -vE "^Analyzing '|^Analyzing Swift files at paths " "$share.err" | tail -n 20 >&2 || true
        status=1
    else
        grep -E '^Done analyzing!' "$share.err" | tail -n 1
    fi
done
exit $status
