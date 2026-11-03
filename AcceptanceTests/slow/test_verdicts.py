"""verdicts.py's checks, on small results files written here: `python3 -I -m unittest test_verdicts` in this folder,
or `make slow-acceptance-selftest`. Each check must fail on what it exists to catch, and pass on correct runs."""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verdicts  # noqa: E402


def header(session=1, discovered=3, to_test=3, reused=None, **extra):
    return {"kind": "header", "formatVersion": 1 if session == 1 else 2, "session": session,
            "mutantsDiscovered": discovered, "mutantsToTest": to_test, "configuration": {"executable": "swift"},
            "provenance": {"swiftMutator": {"executableSHA256": "ab"}}, **({"mutantsReused": reused} if reused is not None else {}),
            **extra}


def mutant(line, outcome="failed", session=1, path="Sources/A.swift", after="!=", killed_by=None, **extra):
    return {"kind": "mutant", "session": session, "path": path, "line": line, "column": 5, "occurrence": 0,
            "mutationOperatorId": "RelationalOperatorReplacement", "outcome": outcome,
            "snapshot": {"before": "==", "after": after, "description": "changed"},
            **({"killedBy": killed_by} if killed_by else {}), **extra}


def end(session=1, reason="finished", **extra):
    return {"kind": "end", "session": session, "reason": reason, **extra}


class VerdictsTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()

    def write(self, name, *records):
        path = os.path.join(self.folder, name)
        with open(path, "w") as file:
            for record in records:
                file.write(json.dumps(record) + "\n")
        return path

    def run_command(self, *argv):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            old, sys.argv = sys.argv, ["verdicts.py", *argv]
            try:
                verdicts.main()
            except SystemExit as exit:
                code = exit.code
            finally:
                sys.argv = old
        return code, output.getvalue()

    def reference(self, *runs, allowlist=None):
        out = os.path.join(self.folder, "reference.json")
        args = ["reference", *runs, "--pin", "abc", "--resolved-sha256", "ff", "--out", out]
        code, output = self.run_command(*args, *(["--allowlist", allowlist] if allowlist else []))
        return code, output, out

    def full(self, name="full.jsonl"):
        return self.write(name, header(), mutant(1), mutant(2, "passed"), mutant(3, "timeout"), end())

    # A retired line drops the results it lists, as SwiftMutator's reader does.
    def test_aRetiredResult_isNoLongerStoodBy(self):
        path = self.write("r.jsonl", header(), mutant(1), mutant(2), end(reason="interrupted"),
                          header(session=2), {"kind": "retired", "session": 2, "keys": [mutant(2)]}, end(session=2))
        self.assertEqual(sorted(verdicts.Results(path).latest), ["Sources/A.swift:1:5:RelationalOperatorReplacement:0"])

    def test_aNewerFormat_isRefused(self):
        path = self.write("r.jsonl", {**header(), "formatVersion": 9})
        with self.assertRaises(SystemExit):
            verdicts.Results(path)

    def test_theReference_takesTheMajority_andRefusesAnUnexplainedDisagreement(self):
        runs = [self.full("a.jsonl"), self.full("b.jsonl"),
                self.write("c.jsonl", header(), mutant(1, "passed"), mutant(2, "passed"), mutant(3, "timeout"), end())]
        code, output, _ = self.reference(*runs)
        self.assertEqual(code, 1, output)
        self.assertIn("disagree", output)
        allowed = self.write("allow.json")
        with open(allowed, "w") as file:
            json.dump({"mutants": {"Sources/A.swift:1:5:RelationalOperatorReplacement:0": "order-dependent test"}}, file)
        code, output, out = self.reference(*runs, allowlist=allowed)
        self.assertEqual(code, 0, output)
        self.assertEqual(verdicts.load_json(out)["mutants"]["Sources/A.swift:1:5:RelationalOperatorReplacement:0"]["verdict"],
                         "killed")

    # A minority of timeouts is the target's tests hanging now and then: the majority's verdict stands. A tie doesn't.
    def test_theReference_keepsTheMajority_overAMinorityOfTimeouts(self):
        hung = self.write("c.jsonl", header(), mutant(1, "timeout"), mutant(2, "passed"), mutant(3, "timeout"), end())
        code, output, out = self.reference(self.full("a.jsonl"), self.full("b.jsonl"), hung)
        self.assertEqual(code, 0, output)
        self.assertIn("timeouts only", output)
        self.assertEqual(verdicts.load_json(out)["mutants"]["Sources/A.swift:1:5:RelationalOperatorReplacement:0"]["verdict"],
                         "killed")
        code, output, _ = self.reference(self.full("a.jsonl"), hung)
        self.assertEqual(code, 1, output)
        self.assertIn("disagree", output)

    # Discovery is deterministic on a pinned tree: another mutation at the same place isn't a flaky verdict.
    def test_theReference_refusesRunsWithDifferentMutations(self):
        other = self.write("b.jsonl", header(), mutant(1, after=">="), mutant(2, "passed"), mutant(3, "timeout"), end())
        code, output, _ = self.reference(self.full(), other)
        self.assertEqual(code, 1)
        self.assertIn("different mutations", output)

    def test_check_failsOnAVerdict_aMutation_aMissingMutant_orAnUnfinishedRun(self):
        _, _, reference = self.reference(self.full())
        self.assertEqual(self.run_command("check", self.full("same.jsonl"), "--reference", reference)[0], 0)
        cases = {
            "verdict": self.write("v.jsonl", header(), mutant(1, "passed"), mutant(2, "passed"), mutant(3, "timeout"), end()),
            "mutation": self.write("m.jsonl", header(), mutant(1, after="<"), mutant(2, "passed"), mutant(3, "timeout"), end()),
            "not discovered": self.write("d.jsonl", header(), mutant(1), mutant(2, "passed"), end()),
            "ended": self.write("e.jsonl", header(), mutant(1), mutant(2, "passed"), mutant(3, "timeout"), end(reason="aborted")),
        }
        for expected, path in cases.items():
            code, output = self.run_command("check", path, "--reference", reference)
            self.assertEqual(code, 1, expected)
            self.assertIn(expected, output)

    # A few verdicts that differ from the reference's by a timeout alone are reported; more than MAX_TIMEOUT_FLIPS fail.
    def test_check_toleratesAFewTimeoutFlips_butNotMore(self):
        many = [mutant(line, "passed") for line in range(1, verdicts.MAX_TIMEOUT_FLIPS + 3)]
        _, _, reference = self.reference(self.write("f.jsonl", header(), *many, end()))
        few = [mutant(line, "timeout" if line <= verdicts.MAX_TIMEOUT_FLIPS else "passed") for line in range(1, len(many) + 1)]
        code, output = self.run_command("check", self.write("few.jsonl", header(), *few, end()), "--reference", reference)
        self.assertEqual(code, 0, output)
        self.assertIn("a timeout flip, tolerated", output)
        too_many = [mutant(line, "timeout") for line in range(1, len(many) + 1)]
        code, output = self.run_command("check", self.write("many.jsonl", header(), *too_many, end()), "--reference", reference)
        self.assertEqual(code, 1, output)
        self.assertIn("timeout flips, more than", output)

    # A finished session on several workers runs its timeouts again before it ends, and the rerun's line has `rerun`.
    # On one worker, or in a session that stopped, a timeout needn't have one.
    def test_check_failsOnATimeoutAFinishedSessionOnSeveralWorkersNeverRanAgain(self):
        _, _, reference = self.reference(self.full())
        rerun = {"rerun": {"because": "timeout", "workers": 1}}
        good = self.write("good.jsonl", header(workers=4), mutant(1), mutant(2, "passed"), mutant(3, "timeout"),
                          mutant(3, "timeout", **rerun), end())
        code, output = self.run_command("check", good, "--reference", reference)
        self.assertEqual(code, 0, output)
        self.assertIn("1 timeouts run again, 0 changed", output)
        self.assertEqual(self.run_command("check", self.full("serial.jsonl"), "--reference", reference)[0], 0)
        bad = self.write("bad.jsonl", header(workers=4), mutant(1), mutant(2, "passed"), mutant(3, "timeout"), end())
        code, output = self.run_command("check", bad, "--reference", reference)
        self.assertEqual(code, 1, output)
        self.assertIn("a timeout its session never ran again at lower load", output)
        stopped = self.write("stopped.jsonl", header(workers=4), mutant(3, "timeout"), end(reason="interrupted"))
        self.assertEqual(verdicts.timeouts_not_rerun(verdicts.Results(stopped)), [])

    # A result `--reuse` kept keeps the `rerun` it was tested with, but its session ran nothing again.
    def test_check_countsNoRerunForAResultItsSessionKept(self):
        _, _, reference = self.reference(self.full())
        kept = {"reusedFrom": {"resultsFile": "full.jsonl", "session": 1},
                "rerun": {"because": "timeout", "workers": 1}}
        reuse = self.write("reuse.jsonl", header(workers=4, to_test=2, reused=1), mutant(1), mutant(2, "passed"),
                           mutant(3, "timeout", **kept), end())
        code, output = self.run_command("check", reuse, "--reference", reference)
        self.assertEqual(code, 0, output)
        self.assertIn("0 timeouts run again, 0 changed", output)

    # A reuse with nothing changed keeps all but timeouts, build errors and repeated places.
    def test_expectReuse_keepsWhatResumePlanKeeps(self):
        full = self.write("full.jsonl", header(discovered=4, to_test=4), mutant(1), mutant(2, "passed"),
                          mutant(3, "timeout"), mutant(4, "buildError"), end())
        kept = {"reusedFrom": {"resultsFile": full, "session": 1}}
        good = self.write("reuse.jsonl", header(discovered=4, to_test=2, reused=2), mutant(1, **kept),
                          mutant(2, "passed", **kept), mutant(3, "timeout"), mutant(4, "buildError"), end())
        self.assertEqual(self.run_command("expect-reuse", full, good)[0], 0)
        over = self.write("over.jsonl", header(discovered=4, to_test=1, reused=3), mutant(1, **kept),
                          mutant(2, "passed", **kept), mutant(3, "timeout", **kept), mutant(4, "buildError"), end())
        code, output = self.run_command("expect-reuse", full, over)
        self.assertEqual(code, 1)
        self.assertIn("kept, though it should be tested again", output)

    def test_expectNoneReused_failsOnAPlanThatKeepsAny(self):
        self.assertEqual(self.run_command("expect-none-reused", self.write("a.jsonl", header()))[0], 0)
        code, _ = self.run_command("expect-none-reused", self.write("b.jsonl", header(to_test=2, reused=1)))
        self.assertEqual(code, 1)

    def test_expectTestChange_failsOnAKeptKillOnlyTheChangedFileMade(self):
        only = [{"name": "t()", "location": "ATests.swift:3:5"}]
        other = [{"name": "u()", "location": "BTests.swift:9:5"}]
        full = self.write("full.jsonl", header(), mutant(1, killed_by=only), mutant(2, killed_by=other),
                          mutant(3, "passed"), end())
        fresh = self.write("fresh.jsonl", header(), mutant(1, "passed"), mutant(2, killed_by=other), mutant(3, "passed"), end())
        kept = {"reusedFrom": {"resultsFile": full, "session": 1}}
        good = self.write("good.jsonl", header(reused=1), mutant(1, "passed"), mutant(2, killed_by=other, **kept),
                          mutant(3, "passed"), end())
        args = ["--test-file", "Tests/X/ATests.swift"]
        self.assertEqual(self.run_command("expect-test-change", full, good, fresh, *args)[0], 0)
        # A timeout against the edited tree's survivor is a timeout flip, as against the reference.
        hung = self.write("hung.jsonl", header(reused=1), mutant(1, "passed"), mutant(2, killed_by=other, **kept),
                          mutant(3, "timeout"), end())
        code, output = self.run_command("expect-test-change", full, hung, fresh, *args)
        self.assertEqual(code, 0, output)
        self.assertIn("a timeout flip, tolerated", output)
        bad = self.write("bad.jsonl", header(reused=2), mutant(1, killed_by=only, **kept),
                         mutant(2, killed_by=other, **kept), mutant(3, "passed"), end())
        code, output = self.run_command("expect-test-change", full, bad, fresh, *args)
        self.assertEqual(code, 1)
        self.assertIn("only ATests.swift's tests killed it", output)

    def test_expectStopResume_failsOnACancelledRunRecorded_orAMutantNeitherSessionTested(self):
        _, _, reference = self.reference(self.full())
        good = self.write("good.jsonl", header(), mutant(1), end(reason="interrupted", detail="SIGINT"),
                          header(session=2, to_test=2), mutant(2, "passed", session=2), mutant(3, "timeout", session=2),
                          end(session=2))
        self.assertEqual(self.run_command("expect-stop-resume", good, "--reference", reference)[0], 0)
        cancelled = self.write("bad.jsonl", header(), mutant(1, endedBy="exited", exitStatus=130),
                               end(reason="interrupted", detail="SIGINT"), header(session=2, to_test=2),
                               mutant(2, "passed", session=2), end(session=2))
        code, output = self.run_command("expect-stop-resume", cancelled, "--reference", reference)
        self.assertEqual(code, 1)
        self.assertIn("recorded a run that the stop ended", output)
        self.assertIn("neither session tested it", output)

    # A timeout run again before the stop has two lines in session 1, but is one mutant: two of three recorded is
    # still a stop in time.
    def test_expectStopResume_countsSessionOnesMutants_notItsLines(self):
        _, _, reference = self.reference(self.full())
        rerun = {"rerun": {"because": "timeout", "workers": 1}}
        good = self.write("good.jsonl", header(workers=4), mutant(1), mutant(3, "timeout"), mutant(3, "timeout", **rerun),
                          end(reason="interrupted", detail="SIGINT"), header(session=2, to_test=1),
                          mutant(2, "passed", session=2), end(session=2))
        code, output = self.run_command("expect-stop-resume", good, "--reference", reference)
        self.assertEqual(code, 0, output)

    def test_expectSince_boundsTheSelectionByGitsOwnDiff(self):
        _, _, reference = self.reference(self.write("f.jsonl", header(), mutant(1), mutant(2, "passed"),
                                                    mutant(7, path="Sources/B.swift"), end()))
        diff = os.path.join(self.folder, "diff")
        with open(diff, "w") as file:
            file.write("diff --git a/Sources/A.swift b/Sources/A.swift\n--- a/Sources/A.swift\n+++ b/Sources/A.swift\n"
                       "@@ -2 +2 @@\n-a\n+b\n"
                       "diff --git a/Tests/ATests.swift b/Tests/ATests.swift\n--- a/Tests/ATests.swift\n"
                       "+++ b/Tests/ATests.swift\n@@ -1,0 +2,3 @@\n+x\n")
        good = self.write("good.jsonl", header(), mutant(2, "passed"), end())
        self.assertEqual(self.run_command("expect-since", good, "--reference", reference, "--diff", diff)[0], 0)
        dropped = self.write("dropped.jsonl", header(), end())
        code, output = self.run_command("expect-since", dropped, "--reference", reference, "--diff", diff)
        self.assertEqual(code, 1)
        self.assertIn("on a changed line, and not tested", output)
        leaked = self.write("leaked.jsonl", header(), mutant(2, "passed"), mutant(7, path="Sources/B.swift"), end())
        code, output = self.run_command("expect-since", leaked, "--reference", reference, "--diff", diff)
        self.assertEqual(code, 1)
        self.assertIn("not in a changed file", output)

    # A new pin's first reference records its times with no times file yet.
    def test_times_makeTheFirstBaseline(self):
        runs = os.path.join(self.folder, "runs.tsv")
        with open(runs, "w") as file:
            file.write("name\twall_s\tload_at_start\n" "full\t100\t1\n" "full\t300\t2\n" "full\t900\t9\n")
        times = os.path.join(self.folder, "times.json")
        self.assertEqual(self.run_command("times", runs, "--baseline", times, "--update")[0], 0)
        self.assertEqual(verdicts.load_json(times), {"full": {"runs": 2, "wall_s": 200}})
        # A suite's update adds the scenarios not yet timed, keeps full's time, and isn't misled by reference rows.
        with open(runs, "a") as file:
            file.write("release\t50\t1\n" "full\t999\t1\n" "reference-1\t5\t1\n")
        self.assertEqual(self.run_command("times", runs, "--baseline", times, "--update")[0], 0)
        self.assertEqual(verdicts.load_json(times), {"full": {"runs": 2, "wall_s": 200}, "release": {"runs": 1, "wall_s": 50}})

    def test_excludes_matchAsSwiftMutatorDoes(self):
        excludes = verdicts.DEFAULT_EXCLUDES + ["**/BuiltInRules.swift"]
        self.assertTrue(verdicts.excluded("Tests/CoreTests/ATests.swift", excludes))
        self.assertTrue(verdicts.excluded("Packages/X/Sources/X/BuiltInRules.swift", excludes))
        self.assertTrue(verdicts.excluded("BuiltInRules.swift", excludes))
        self.assertFalse(verdicts.excluded("Sources/Core/Linter.swift", excludes))
        self.assertFalse(verdicts.excluded("Sources/A/B.swift", ["Sources/*.swift"]))
        self.assertTrue(verdicts.excluded("Packages/Rules/Sources/A/B.swift", ["./Packages/Rules/**"]))
        self.assertFalse(verdicts.excluded("Packages/Visitors/Sources/B.swift", ["Packages/Rules/**"]))
        self.assertTrue(verdicts.excluded("Sources/A2.swift", ["Sources/*[0-9].swift"]))
        self.assertFalse(verdicts.excluded("Sources/Ax.swift", ["Sources/*[!x].swift"]))
        self.assertTrue(verdicts.excluded("Sources/Ay.swift", ["Sources/*[!x].swift"]))
        self.assertTrue(verdicts.excluded("Sources/[]x.swift", ["Sources/[]*.swift"]))


if __name__ == "__main__":
    unittest.main()
