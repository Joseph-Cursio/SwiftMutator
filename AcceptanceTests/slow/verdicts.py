"""The slow acceptance tier's checks: reads SwiftMutator results files, builds the reference from whole runs, and
compares a run with it. Run as `python3 -I verdicts.py <command> ...`; each command exits 1 when its check fails.

A results file is read as SwiftMutator reads it (Docs/results-file.md): in order, a `mutant` line setting its key's
result and a `retired` line dropping the keys it lists, so the results left are those the run stands by.
"""
import argparse
import collections
import json
import os
import re
import statistics
import sys

FORMAT_VERSIONS = {1, 2}
VERDICTS = {"failed": "killed", "runtimeError": "killed", "passed": "survived", "timeout": "timedOut"}
# Signals a stopped run's test process can end by, and the shell's 128 + n form of them: a run recorded with one of
# these was cancelled, not tested.
STOP_STATUSES = {2, 9, 15, 130, 137, 143}
# The target's tests now and then hang, or slow down past the time limit, under some random mutant: a run may differ
# from the reference by this many timeouts alone. Any other difference fails at once.
MAX_TIMEOUT_FLIPS = 3
DEFAULT_EXCLUDES = ["/.swiftpm/", "/.build/", "/Build/", "/Carthage/", "/muter_tmp/", "/Pods/", "/Spec/", "/Tests/",
                    "Tests.swift", "/fastlane/", "/Package.swift", "/Package@swift-"]


class Results:
    """A results file's headers, end lines and the results it stands by, by key."""

    def __init__(self, path):
        self.path = path
        self.headers, self.ends, self.retired = [], [], collections.defaultdict(list)
        self.latest, self.lines = {}, []
        with open(path) as file:
            for text in file:
                try:
                    record = json.loads(text)
                except ValueError:
                    continue  # A line a stopped run left half-written.
                kind = record.get("kind")
                if kind == "header":
                    if record.get("formatVersion") not in FORMAT_VERSIONS:
                        sys.exit(f"{path}: formatVersion {record.get('formatVersion')} isn't one this reads")
                    self.headers.append(record)
                elif kind == "mutant":
                    self.lines.append(record)
                    self.latest[key(record)] = record
                elif kind == "retired":
                    for retired in record.get("keys", []):
                        self.retired[record["session"]].append(key(retired))
                        self.latest.pop(key(retired), None)
                elif kind == "end":
                    self.ends.append(record)

    def session_lines(self, session):
        return [line for line in self.lines if line["session"] == session]


def key(record):
    return f"{record['path']}:{record['line']}:{record['column']}:{record['mutationOperatorId']}:{record.get('occurrence', 0)}"


def place(record_key):
    """A key without its occurrence: what `ResumePlan` counts repeats of."""
    return record_key.rsplit(":", 1)[0]


def verdict(record):
    return VERDICTS.get(record["outcome"], record["outcome"])


def mutation(record):
    snapshot = record.get("snapshot") or {}
    return {"before": snapshot.get("before"), "after": snapshot.get("after")}


def load_json(path):
    with open(path) as file:
        return json.load(file)


def allowlist(path):
    return load_json(path).get("mutants", {}) if path else {}


def fail(problems, title):
    if problems:
        print(f"FAIL {title}: {len(problems)}")
        for problem in problems[:60]:
            print(f"  {problem}")
        if len(problems) > 60:
            print(f"  … and {len(problems) - 60} more")
    return 1 if problems else 0


def timeout_only(verdicts):
    """Whether verdicts differ only by timeouts: without them, at most one verdict is left."""
    return len(set(verdicts) - {"timedOut"}) <= 1


def timeouts_not_rerun(run):
    """The keys of the timeouts a finished session on more than one worker left without running them again at lower
    load, which it does before it ends: each session's workers from the last header of its number, as SwiftMutator
    reads them."""
    workers = {header["session"]: header.get("workers", 1) for header in run.headers}
    finished = {end["session"] for end in run.ends if end.get("reason") == "finished"}
    return sorted(k for k, record in run.latest.items()
                  if record["outcome"] == "timeout" and not record.get("rerun")
                  and record["session"] in finished and workers.get(record["session"], 1) > 1)


def killers(record):
    return ", ".join(f"{test.get('name')} ({test.get('location')})" for test in (record.get("killedBy") or [])[:3])


# MARK: - reference

def command_reference(args):
    """The majority verdict of each mutant over whole runs, with its mutation. Refuses runs that discover different
    mutants or mutations, and verdicts the runs disagree on that the allowlist doesn't explain, unless they differ
    only by a minority of timeouts or by a timeout of the majority's."""
    runs = [Results(path) for path in args.runs]
    keys = [set(run.latest) for run in runs]
    problems = []
    for run, found in zip(runs[1:], keys[1:]):
        if found != keys[0]:
            problems.append(f"{run.path} discovers {len(found ^ keys[0])} mutants unlike {runs[0].path}'s")
    explained = allowlist(args.allowlist)
    mutants, tolerated = {}, []
    for record_key in sorted(keys[0]):
        records = [run.latest[record_key] for run in runs if record_key in run.latest]
        mutations = {json.dumps(mutation(record), sort_keys=True) for record in records}
        if len(mutations) > 1:
            problems.append(f"{record_key}: the runs made different mutations {sorted(mutations)}")
        counts = collections.Counter(verdict(record) for record in records)
        majority, votes = counts.most_common(1)[0]
        if len(counts) > 1 and record_key not in explained:
            if timeout_only(counts) and votes * 2 > len(records):
                tolerated.append(f"{record_key}: {dict(counts)}")
            else:
                problems.append(f"{record_key}: the runs disagree {dict(counts)}, and the allowlist doesn't explain it")
        mutants[record_key] = {"verdict": majority, **mutation(records[0])}
    for line in tolerated:
        print(f"  timeouts only, the majority's verdict kept: {line}")
    if fail(problems, "reference"):
        return 1
    reference = {
        "pin": args.pin,
        "packageResolvedSHA256": args.resolved_sha256,
        "runs": [{"resultsFile": run.path, "swiftMutatorSHA256": run.headers[0]["provenance"]["swiftMutator"].get(
            "executableSHA256"), "mutantsDiscovered": run.headers[0]["mutantsDiscovered"]} for run in runs],
        "mutants": mutants,
    }
    with open(args.out, "w") as file:
        json.dump(reference, file, indent=1, sort_keys=True)
        file.write("\n")
    print(f"reference: {len(mutants)} mutants from {len(runs)} runs, {dict(collections.Counter(m['verdict'] for m in mutants.values()))}")
    return 0


# MARK: - check

def compare(run, reference, explained, keys_to_check, against="the reference's"):
    """Each mutation unlike the reference's, which nothing excuses, and each verdict unlike it the allowlist doesn't
    explain. Up to MAX_TIMEOUT_FLIPS verdicts that differ from it only by a timeout are reported, not failed.
    `against` names the reference in the messages."""
    problems, flips = [], []
    for record_key in sorted(keys_to_check):
        record, expected = run.latest[record_key], reference["mutants"][record_key]
        if mutation(record) != {"before": expected["before"], "after": expected["after"]}:
            problems.append(f"{record_key}: mutation {mutation(record)} is not {against} "
                            f"{ {'before': expected['before'], 'after': expected['after']} }")
        if verdict(record) != expected["verdict"] and record_key not in explained:
            difference = f"{record_key}: verdict {verdict(record)}, {against} {expected['verdict']}; {killers(record)}"
            (flips if timeout_only({verdict(record), expected["verdict"]}) else problems).append(difference)
    if len(flips) > MAX_TIMEOUT_FLIPS:
        problems += [f"{flip} (one of {len(flips)} timeout flips, more than {MAX_TIMEOUT_FLIPS})" for flip in flips]
    else:
        for flip in flips:
            print(f"  a timeout flip, tolerated: {flip}")
    return problems


def command_check(args):
    """A run's results against the reference: the same mutants, each with its mutation and verdict."""
    run, reference = Results(args.results), load_json(args.reference)
    expected, found = set(reference["mutants"]), set(run.latest)
    problems = [f"{k}: not discovered" for k in sorted(expected - found)]
    problems += [f"{k}: not in the reference" for k in sorted(found - expected)]
    problems += compare(run, reference, allowlist(args.allowlist), found & expected)
    if not run.ends or run.ends[-1].get("reason") != "finished":
        problems.append(f"the last session ended {run.ends[-1].get('reason') if run.ends else 'without an end line'}")
    problems += [f"{k}: a timeout its session never ran again at lower load" for k in timeouts_not_rerun(run)]
    # A result `--reuse` kept keeps the `rerun` it was tested with, though its own session never ran it again.
    reruns = [line for line in run.lines if line.get("rerun") and not line.get("reusedFrom")]
    print(f"check {args.results}: {len(found)} mutants, {dict(collections.Counter(verdict(r) for r in run.latest.values()))}, "
          f"{len(reruns)} timeouts run again, {sum(line['outcome'] != 'timeout' for line in reruns)} changed")
    return fail(problems, "check")


# MARK: - reuse

def expected_kept(full, changed_paths=()):
    """What a reuse of `full` keeps, by `ResumePlan`'s rules with nothing else changed: every result but timeouts,
    build errors, mutants at a place discovered more than once, and those in `changed_paths`."""
    places = collections.Counter(place(k) for k in full.latest)
    return {k for k, record in full.latest.items()
            if record["outcome"] not in ("timeout", "buildError") and places[place(k)] == 1
            and record["path"] not in changed_paths}


def reused(run):
    return {k for k, record in run.latest.items() if record.get("reusedFrom")}


def command_expect_reuse(args):
    """A reuse of `full` kept exactly what `ResumePlan`'s rules keep, and its header says so."""
    full, run = Results(args.full), Results(args.reuse)
    expected = expected_kept(full, set(args.changed_path or []))
    header = run.headers[-1]
    problems = [f"{k}: tested again, though nothing it depends on changed" for k in sorted(expected - reused(run))]
    problems += [f"{k}: kept, though it should be tested again" for k in sorted(reused(run) - expected)]
    if header.get("mutantsReused") != len(expected):
        problems.append(f"mutantsReused is {header.get('mutantsReused')}, not {len(expected)}")
    if header.get("mutantsToTest") != header["mutantsDiscovered"] - len(expected):
        problems.append(f"mutantsToTest is {header.get('mutantsToTest')}, not {header['mutantsDiscovered'] - len(expected)}")
    problems += same_setup(full, run, waived=args.waived or [])
    return fail(problems, "expect-reuse")


def command_expect_none_reused(args):
    """A reuse after a change to a file other than a test retests everything: its header plans to keep nothing."""
    run = Results(args.reuse)
    if not run.headers:
        return fail(["no header: the run stopped before its baseline passed"], "expect-none-reused")
    header = run.headers[-1]
    problems = [f"{k}: kept" for k in sorted(reused(run))]
    if header.get("mutantsReused", 0) != 0:
        problems.append(f"mutantsReused is {header.get('mutantsReused')}, not 0")
    if header.get("mutantsToTest") != header["mutantsDiscovered"]:
        problems.append(f"mutantsToTest is {header.get('mutantsToTest')}, not every one of {header['mutantsDiscovered']}")
    return fail(problems, "expect-none-reused")


def command_expect_test_change(args):
    """A reuse after a test file changed: no kill only that file's tests made is kept, and kills by other files' tests
    are; its verdicts are those of a full run of the same edited tree."""
    full, run, fresh = Results(args.full), Results(args.reuse), Results(args.fresh)
    name = args.test_file.rsplit("/", 1)[-1]
    problems = []
    kept = reused(run)
    for k, record in full.latest.items():
        locations = [(test.get("location") or "").split(":")[0] for test in record.get("killedBy") or []]
        if record["outcome"] in ("failed", "runtimeError") and locations and all(loc == name for loc in locations):
            if k in kept:
                problems.append(f"{k}: kept, though only {name}'s tests killed it")
    if not any(full.latest[k]["outcome"] in ("failed", "runtimeError") for k in kept):
        problems.append("no kill was kept: every kill was tested again")
    if any(full.latest[k]["outcome"] == "passed" for k in kept):
        problems.append("a survivor was kept, though a test file changed")
    found, expected = set(run.latest), set(fresh.latest)
    problems += [f"{k}: not discovered" for k in sorted(expected - found)]
    problems += [f"{k}: not in the full run" for k in sorted(found - expected)]
    # The full run of the edited tree stands in for the reference.
    edited = {"mutants": {k: {"verdict": verdict(r), **mutation(r)} for k, r in fresh.latest.items()}}
    problems += compare(run, edited, allowlist(args.allowlist), found & expected, "the full run of the edited tree's")
    moved = [k for k in expected if verdict(fresh.latest[k]) != verdict(full.latest[k])] if expected else []
    if not moved:
        problems.append("the edit changed no verdict, so the check shows nothing")
    print(f"expect-test-change: {len(kept)} kept, {len(moved)} verdicts the edit moved")
    return fail(problems, "expect-test-change")


def same_setup(full, run, waived):
    header, first = run.headers[-1], full.headers[0]
    problems = []
    if header.get("configuration") != first.get("configuration"):
        problems.append("the configuration differs from the full run's")
    if header.get("forced"):
        problems.append(f"forced {header['forced']}")
    if sorted(header.get("waived") or []) != sorted(waived):
        problems.append(f"waived {header.get('waived')}, not {sorted(waived)}")
    return problems


# MARK: - stop and resume

def command_expect_stop_resume(args):
    """A run stopped by SIGINT and resumed: the first session ended by the signal, recorded no cancelled run, and the
    second tested what the first left; the results it stands by then match the reference."""
    run, reference = Results(args.results), load_json(args.reference)
    problems = []
    first_end = next((end for end in run.ends if end["session"] == 1), None)
    if not first_end or first_end.get("reason") != "interrupted" or first_end.get("detail") != "SIGINT":
        problems.append(f"session 1 ended {first_end}, not interrupted by SIGINT")
    first = run.session_lines(1)
    # A timeout run again has a second line in its session, so the session's mutants are its distinct keys.
    first_keys = {key(line) for line in first}
    for line in first:
        if line.get("endedBy") == "exited" and line.get("exitStatus") in STOP_STATUSES:
            problems.append(f"{key(line)}: session 1 recorded a run that the stop ended (exit {line['exitStatus']})")
    if not first or len(first_keys) >= len(reference["mutants"]):
        problems.append(f"session 1 recorded {len(first_keys)} of {len(reference['mutants'])} mutants: the stop came too late or too early")
    tested_later = {key(line) for line in run.lines if line["session"] >= 2}
    for k in run.retired.get(2, []):
        if k not in tested_later and k in reference["mutants"]:
            problems.append(f"{k}: retired by session 2 and never tested again")
    for k in sorted(set(reference["mutants"]) - first_keys - tested_later):
        problems.append(f"{k}: neither session tested it")
    expected, found = set(reference["mutants"]), set(run.latest)
    problems += [f"{k}: not discovered" for k in sorted(expected - found)]
    problems += compare(run, reference, allowlist(args.allowlist), found & expected)
    return fail(problems, "expect-stop-resume")


# MARK: - since

def read_diff(diff_path):
    """The new side of `git diff -U0 --no-renames`: each changed file's added or changed lines, and the files it adds."""
    lines, news, current, adding = {}, set(), None, False
    with open(diff_path) as file:
        for text in file:
            if text.startswith("diff --git"):
                current, adding = None, False
            elif text.startswith("new file mode"):
                adding = True
            elif text.startswith("+++ "):
                current = None if text.startswith("+++ /dev/null") else text[6:].rstrip("\n")
                if current is not None:
                    lines.setdefault(current, set())
                    if adding:
                        news.add(current)
            elif text.startswith("@@ ") and current is not None:
                match = re.match(r"@@ -\S+ \+(\d+)(?:,(\d+))? @@", text)
                start, count = int(match.group(1)), int(match.group(2) or 1)
                lines[current].update(range(start, start + count))
    return lines, news


def glob_pattern(glob):
    """An `exclude` glob as SwiftMutator matches one (`ExcludeGlob`): from the project's folder, `*` and `?` within a
    folder, `**/` any number of folders, any other `**` anything, and `[…]` or `[!…]` one of a set of characters."""
    rest = glob
    while rest.startswith(("./", "/")):
        rest = rest[2:] if rest.startswith("./") else rest[1:]
    pattern, index = "", 0
    while index < len(rest):
        negated = rest.startswith("[!", index)
        body = index + (2 if negated else 1)
        close = rest.find("]", body)
        if rest.startswith("**/", index):
            pattern, index = pattern + "(?:.*/)?", index + 3
        elif rest.startswith("**", index):
            pattern, index = pattern + ".*", index + 2
        elif rest[index] == "*":
            pattern, index = pattern + "[^/]*", index + 1
        elif rest[index] == "?":
            pattern, index = pattern + "[^/]", index + 1
        elif rest[index] == "[" and close > body:  # `[]` and an unclosed `[` match themselves
            members = "".join("\\" + c if c in "\\&[" else c for c in rest[body:close])
            pattern, index = pattern + ("[^/" if negated else "[") + members + "]", close + 1
        else:
            pattern, index = pattern + re.escape(rest[index]), index + 1
    return re.compile(f"^{pattern}$")


def excluded(path, excludes):
    return any(("*" not in e and e in "./" + path) or ("*" in e and glob_pattern(e).match(path)) for e in excludes)


def command_expect_since(args):
    """A `--since --changed-lines` run's mutants lie between what the diff requires and the changed files, with the
    reference's verdicts. The diff is git's own, not the run's record of it."""
    run, reference = Results(args.results), load_json(args.reference)
    lines, news = read_diff(args.diff)
    excludes = DEFAULT_EXCLUDES + (args.exclude or [])
    changed = {path for path in lines if path.endswith(".swift") and not excluded(path, excludes)}
    required = {k for k, mutant in reference["mutants"].items()
                if (path := k.split(":")[0]) in changed and (path in news or int(k.split(":")[1]) in lines[path])}
    found = set(run.latest)
    problems = []
    if not required:
        problems.append("the diff requires no mutant: choose another SINCE_BASE")
    problems += [f"{k}: on a changed line, and not tested" for k in sorted(required - found)]
    problems += [f"{k}: not in a changed file" for k in sorted(k for k in found if k.split(":")[0] not in changed)]
    problems += [f"{k}: not in the reference" for k in sorted(found - set(reference["mutants"]))]
    problems += compare(run, reference, allowlist(args.allowlist), found & set(reference["mutants"]))
    spanned = sorted(found - required)
    print(f"expect-since: {len(found)} tested, {len(required)} required, {len(spanned)} selected by their span")
    for k in spanned[:20]:
        print(f"  span: {k}")
    return fail(problems, "expect-since")


# MARK: - choices made with the reference

def command_pick_test_change(args):
    """A test file whose tests alone killed some mutants, whose name no other test file shares, and which leaves
    other files' kills: the test-change scenario empties it."""
    full = Results(args.full)
    sole = collections.Counter()
    for record in full.latest.values():
        locations = {(test.get("location") or "").split(":")[0] for test in record.get("killedBy") or []}
        if record["outcome"] in ("failed", "runtimeError") and len(locations) == 1 and "" not in locations:
            sole[locations.pop()] += 1
    names = collections.Counter(path.rsplit("/", 1)[-1] for path in args.test_files)
    for name, count in sole.most_common():
        if names[name] == 1 and count >= args.minimum:
            print(next(path for path in args.test_files if path.endswith("/" + name)), count)
            return 0
    return fail(["no test file alone kills enough mutants"], "pick-test-change")


# MARK: - times

def command_times(args):
    """Each run's times against its scenario's median from earlier idle runs. Never fails: times are tracked."""
    # A new pin's first reference has no times yet.
    baseline = load_json(args.baseline) if args.baseline and os.path.exists(args.baseline) else {}
    rows = list(csv_rows(args.runs))
    for row in rows:
        medians = baseline.get(row["name"])
        wall = float(row["wall_s"])
        note = "no baseline yet"
        if medians:
            ratio = wall / medians["wall_s"]
            note = f"{ratio:.2f}× its median {medians['wall_s'] / 60:.1f} min"
            if ratio > 1.2 and float(row["load_at_start"]) < 4:
                note += "  ⚠️ more than 20% slower, from idle"
        print(f"{row['name']:24} {wall / 60:6.1f} min  {note}")
    if args.update:
        # A scenario's time, once recorded, stays until the next reference starts the file again; a reference run's
        # own row is part of `full`'s time, which the reference records.
        for name in {row["name"] for row in rows} - set(baseline):
            if re.fullmatch(r"reference-\d+", name):
                continue
            walls = [float(r["wall_s"]) for r in rows if r["name"] == name and float(r["load_at_start"]) < 4]
            if walls:
                baseline[name] = {"wall_s": statistics.median(walls), "runs": len(walls)}
        with open(args.baseline, "w") as file:
            json.dump(baseline, file, indent=1, sort_keys=True)
            file.write("\n")
    return 0


def csv_rows(path):
    with open(path) as file:
        header = file.readline().rstrip("\n").split("\t")
        for line in file:
            yield dict(zip(header, line.rstrip("\n").split("\t")))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    reference = commands.add_parser("reference")
    reference.add_argument("runs", nargs="+")
    reference.add_argument("--pin", required=True)
    reference.add_argument("--resolved-sha256", required=True)
    reference.add_argument("--allowlist")
    reference.add_argument("--out", required=True)

    check = commands.add_parser("check")
    check.add_argument("results")
    check.add_argument("--reference", required=True)
    check.add_argument("--allowlist")

    reuse = commands.add_parser("expect-reuse")
    reuse.add_argument("full")
    reuse.add_argument("reuse")
    reuse.add_argument("--changed-path", action="append")
    reuse.add_argument("--waived", action="append")

    none = commands.add_parser("expect-none-reused")
    none.add_argument("reuse")

    test_change = commands.add_parser("expect-test-change")
    test_change.add_argument("full")
    test_change.add_argument("reuse")
    test_change.add_argument("fresh")
    test_change.add_argument("--test-file", required=True)
    test_change.add_argument("--allowlist")

    stop = commands.add_parser("expect-stop-resume")
    stop.add_argument("results")
    stop.add_argument("--reference", required=True)
    stop.add_argument("--allowlist")

    since = commands.add_parser("expect-since")
    since.add_argument("results")
    since.add_argument("--reference", required=True)
    since.add_argument("--diff", required=True)
    since.add_argument("--exclude", action="append")
    since.add_argument("--allowlist")

    pick = commands.add_parser("pick-test-change")
    pick.add_argument("full")
    pick.add_argument("test_files", nargs="+")
    pick.add_argument("--minimum", type=int, default=3)

    times = commands.add_parser("times")
    times.add_argument("runs")
    times.add_argument("--baseline")
    times.add_argument("--update", action="store_true")

    args = parser.parse_args()
    handlers = {
        "reference": command_reference, "check": command_check, "expect-reuse": command_expect_reuse,
        "expect-none-reused": command_expect_none_reused, "expect-test-change": command_expect_test_change,
        "expect-stop-resume": command_expect_stop_resume, "expect-since": command_expect_since,
        "pick-test-change": command_pick_test_change, "times": command_times,
    }
    sys.exit(handlers[args.command](args))


if __name__ == "__main__":
    main()
