"""verdicts.py's checks, on small results files written here: `python3 -I -m unittest test_verdicts` in this folder,
or `make slow-acceptance-selftest`. Each check must fail on what it exists to catch, and pass on correct runs."""
import contextlib
import io
import json
import os
import re
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verdicts  # noqa: E402


OPERATORS = ["RelationalOperatorReplacement", "SwapTernary"]


def header(session=1, discovered=3, to_test=3, reused=None, **extra):
    # As today's runs write them: 4 for a session that tests mutants without keepAllLogs, as the tier's do, and 3 for
    # a resumed one that tests none.
    return {"kind": "header", "formatVersion": 4 if session == 1 or to_test else 3, "session": session,
            "mutantsDiscovered": discovered, "mutantsToTest": to_test, "configuration": {"executable": "swift"},
            "operators": OPERATORS,
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

    def reference(self, *runs, allowlist=None, operators=OPERATORS):
        out = os.path.join(self.folder, "reference.json")
        args = ["reference", *runs, "--pin", "abc", "--resolved-sha256", "ff", "--out", out, "--operators", *operators]
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
        path = self.write("r.jsonl", {**header(), "formatVersion": 5})
        with self.assertRaises(SystemExit):
            verdicts.Results(path)

    # Every format SwiftMutator has written reads, and lines of kinds the checks don't use are skipped.
    def test_everyFormatSoFar_reads_andOtherKindsAreSkipped(self):
        for version in (1, 2, 3, 4):
            path = self.write(f"v{version}.jsonl", {**header(), "formatVersion": version}, mutant(1), end())
            self.assertEqual(len(verdicts.Results(path).latest), 1, version)
        others = [{"kind": kind, "session": 1, **{k: v for k, v in mutant(1, "passed").items() if k != "kind"}}
                  for kind in ("control", "propertyRerun", "exampleRerun", "propertySurvivorRerun")]
        path = self.write("kinds.jsonl", header(), mutant(1), *others, end())
        self.assertEqual([verdicts.verdict(r) for r in verdicts.Results(path).latest.values()], ["killed"])

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

    # The reference records the operators its runs mutated with, which must be those target.env pins, and the same.
    def test_theReference_recordsItsOperators_andRefusesRunsWithOthers(self):
        code, output, out = self.reference(self.full())
        self.assertEqual(code, 0, output)
        self.assertEqual(verdicts.load_json(out)["operators"], OPERATORS)
        code, output, _ = self.reference(self.full(), operators=[*OPERATORS, "NegateConditional"])
        self.assertEqual(code, 1, output)
        self.assertIn("as target.env pins", output)
        fewer = self.write("b.jsonl", header(operators=["SwapTernary"]), mutant(1), mutant(2, "passed"),
                           mutant(3, "timeout"), end())
        code, output, _ = self.reference(self.full(), fewer)
        self.assertEqual(code, 1, output)
        self.assertIn("unlike", output)

    # Another operator list changes every mutant: the check names that cause once, and the driver's own check refuses
    # before any run, as it does a reference from before the operators were recorded.
    def test_otherOperators_failTheChecks_andTheDriversCheck(self):
        _, _, reference = self.reference(self.full())
        added = self.write("added.jsonl", header(operators=[*OPERATORS, "NegateConditional"]), mutant(1),
                           mutant(2, "passed"), mutant(3, "timeout"), end())
        code, output = self.run_command("check", added, "--reference", reference)
        self.assertEqual(code, 1, output)
        self.assertIn("added ['NegateConditional'], missing []", output)
        self.assertEqual(self.run_command("expect-operators", reference, *reversed(OPERATORS))[0], 0)
        code, output = self.run_command("expect-operators", reference, *OPERATORS, "NegateConditional")
        self.assertEqual(code, 1, output)
        self.assertIn("add ['NegateConditional'] and drop []", output)
        old = self.write("old.json")
        with open(old, "w") as file:
            json.dump({k: v for k, v in verdicts.load_json(reference).items() if k != "operators"}, file)
        code, output = self.run_command("expect-operators", old, *OPERATORS)
        self.assertEqual(code, 1, output)
        self.assertIn("records no operators", output)
        code, output = self.run_command("check", self.full("same.jsonl"), "--reference", old)
        self.assertEqual(code, 1, output)
        self.assertIn("records no operators", output)

    # A survivor whose code didn't run is SwiftMutator's "not covered", unlike one whose did; a line that doesn't say,
    # as before SwiftMutator recorded it, stays a survivor.
    def test_aSurvivorWhoseCodeDidntRun_isNotCovered(self):
        self.assertEqual(verdicts.verdict(mutant(1, "passed", activated=False)), "notCovered")
        self.assertEqual(verdicts.verdict(mutant(1, "passed", activated=True)), "survived")
        self.assertEqual(verdicts.verdict(mutant(1, "passed")), "survived")
        _, _, reference = self.reference(self.full())
        uncovered = self.write("u.jsonl", header(), mutant(1), mutant(2, "passed", activated=False), mutant(3, "timeout"), end())
        code, output = self.run_command("check", uncovered, "--reference", reference)
        self.assertEqual(code, 1, output)
        self.assertIn("verdict notCovered, the reference's survived", output)

    # A run a check would refuse can't vote in the reference: one that didn't finish, or left a timeout not run again.
    def test_theReference_refusesARunThatDidntFinish(self):
        stopped = self.write("b.jsonl", header(), mutant(1), mutant(2, "passed"), mutant(3, "timeout"),
                             end(reason="interrupted", detail="SIGINT"))
        code, output, _ = self.reference(self.full(), stopped)
        self.assertEqual(code, 1, output)
        self.assertIn("the last session ended interrupted", output)
        code, output, _ = self.reference(self.full(), self.full("c.jsonl"))
        self.assertEqual(code, 0, output)
        self.assertIn("0 timeout flips against the majority", output)

    # SwiftMutator drops a repeated operator, so a repeat in target.env pins the same list.
    def test_aRepeatedOperator_pinsTheSameList(self):
        code, output, reference = self.reference(self.full(), operators=[*OPERATORS, OPERATORS[0]])
        self.assertEqual(code, 0, output)
        self.assertEqual(self.run_command("expect-operators", reference, *OPERATORS, OPERATORS[0])[0], 0)

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

    # since-nothing takes no time, and whole seconds give no ratio under a minute: no division by its median.
    def test_times_giveNoRatio_forAMedianUnderAMinute(self):
        runs = os.path.join(self.folder, "runs.tsv")
        with open(runs, "w") as file:
            file.write("name\twall_s\tload_at_start\n" "since-nothing\t0\t1\n" "full\t120\t1\n")
        times = os.path.join(self.folder, "times.json")
        with open(times, "w") as file:
            json.dump({"since-nothing": {"runs": 1, "wall_s": 0.0}, "full": {"runs": 1, "wall_s": 100}}, file)
        code, output = self.run_command("times", runs, "--baseline", times)
        self.assertEqual(code, 0, output)
        self.assertIn("under a minute: no ratio", output)
        self.assertIn("1.20× its median", output)

    # The since check leaves out what SwiftMutator does by default: the same list as its sources'.
    def test_defaultExcludes_areSwiftMutators(self):
        here = os.path.dirname(os.path.abspath(__file__))
        source = os.path.join(here, "..", "..", "Sources", "muterCore", "MutationSteps", "SourceFileExcludes.swift")
        with open(source) as file:
            text = file.read()
        lists = [re.findall(r'"([^"]*)"', re.search(rf"static let {name}: \[FilePath\] = \[(.*?)\]", text, re.S).group(1))
                 for name in ("alwaysExcluded", "excludedByDefault")]
        self.assertEqual(verdicts.DEFAULT_EXCLUDES, lists[0] + lists[1])

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
