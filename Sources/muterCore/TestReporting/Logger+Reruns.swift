/// What the Logger says about the runs repeated to settle a verdict: the control run, timeout, property, unproven and
/// suspect-kill reruns, and runs repeated after a launch failure.
extension Logger {
    /// "⚠️ Control run 2 of 3, with no mutant on, failed: timing() at TimingTests.swift:9:5. …": a control run that
    /// didn't pass, while the progress bar is still to be redrawn. Nothing for one that passed. Not a progress line:
    /// the progress counts only mutants.
    func controlRunFinished(_ control: ControlRunFinished) {
        let record = control.record
        guard ![.passed, .noCoverage].contains(record.outcome) else { return }
        let verdict = switch record.outcome {
        case .passed, .noCoverage, .failed: "failed"
        case .runtimeError: "crashed"
        case .timeout: "timed out"
        case .buildError: "couldn't run its tests"
        }
        let run = "⚠️ Control run \(record.number) of \(control.count), with no mutant on, \(verdict)"
        let log = "Its log is \(record.log)."
        guard let first = record.failedTests?.first else {
            print("\(run), naming no failed test. \(log)")
            return
        }
        let count = record.failedTestCount ?? record.failedTests?.count ?? 1
        let more = count > 1 ? " (+\(count - 1))" : ""
        print(
            "\(run): \(first.nameAndLocation)\(more). A test that fails with no mutant on is flaky, and the reports "
                + "count a kill only such tests failed for as suspect. \(log)"
        )
    }

    /// "🔁 Running 3 timeouts again, 2 at a time, under the same 72 s limit: at most 4 min.": the timeouts tested
    /// again once every mutant is tested, after the progress bar's last redraw, which needs no room after it.
    func timeoutRerunsStarted(_ reruns: TimeoutReruns) {
        let timeouts = reruns.count == 1 ? "1 timeout" : "\(reruns.count) timeouts"
        let atATime = reruns.count == 1 ? ""
            : reruns.workers == 1 ? ", one at a time" : ", \(reruns.workers) at a time"
        var limit = ""
        if let seconds = reruns.limitSeconds, let longest = reruns.longestSeconds {
            limit = ", under the same \(Self.seconds(seconds)) limit: at most "
                + SimpleTimeEstimate.text(secondsLeft: longest)
        }
        print("🔁 Running \(timeouts) again\(atATime)\(limit).")
    }

    /// "🔁 1 of 3 killed at Rules.swift:42:17 (changed == to !=), in 41.2 s": what a timeout tested again came to. Not
    /// a progress line: the progress counted its first run.
    func timeoutRerunFinished(_ rerun: TimeoutRerun) {
        let mutant = rerun.rerun
        let verdict = switch mutant.testSuiteOutcome {
        case .failed, .runtimeError: "killed"
        case .passed: "survived"
        case .timeout: "timed out again"
        case .buildError: "failed to build"
        case .noCoverage: "not covered"
        }
        let place = "\(mutant.point.fileName):\(mutant.point.position.line):\(mutant.point.position.column)"
        let change = mutant.snapshot.description.isEmpty ? "" : " (\(mutant.snapshot.description))"
        print("🔁 \(rerun.number) of \(rerun.count) \(verdict) at \(place)\(change), in \(Self.seconds(rerun.seconds))")
    }

    /// "🧪 Running the property tests again for 12 kills only examples were recorded making, 4 at a time.": once every
    /// mutant is tested, and after any timeouts tested again.
    func propertyRerunsStarted(_ reruns: PropertyReruns) {
        let kills = reruns.count == 1 ? "1 kill" : "\(reruns.count) kills"
        let atATime = reruns.count == 1 ? ""
            : reruns.workers == 1 ? ", one at a time" : ", \(reruns.workers) at a time"
        print("🧪 Running the property tests again for \(kills) only examples were recorded making\(atATime).")
    }

    /// "🧪 Ran the property tests again for 12 kills: a property test failed too for 5, and every one passed for 7."
    func propertyRerunsFinished(_ tally: PropertyRerunTally) {
        let kills = tally.rerun == 1 ? "1 kill" : "\(tally.rerun) kills"
        var sentence = "🧪 Ran the property tests again for \(kills): a property test failed too for \(tally.killed), "
            + "and every one passed for \(tally.passed)"
        if tally.unsettled > 0 {
            sentence += "; \(tally.unsettled) timed out or didn't build, which settles nothing"
        }
        print(sentence + ".")
    }

    /// "⚠️ No kill was tested again with the property tests alone: propertyTestFilter selected no test: …. The
    /// reports count what the runs recorded. Its log is property tests with no mutant on.log."
    func propertyRerunsSkipped(reason: String, log: String?) {
        let logSentence = log.map { " Its log is \($0)." } ?? ""
        print(
            "⚠️ No kill was tested again with the property tests alone: \(reason). The reports count what the runs "
                + "recorded, so the count by both may be low.\(logSentence)"
        )
    }

    /// "🔁 Ran 3 timeouts again, and 1 changed: 1 killed, 2 timed out again."
    func timeoutRerunsFinished(_ tally: TimeoutRerunTally) {
        let timeouts = tally.rerun == 1 ? "1 timeout" : "\(tally.rerun) timeouts"
        let changed = tally.changed == 0 ? "none" : "\(tally.changed)"
        let counts = [
            (tally.killed, "killed"),
            (tally.survived, "survived"),
            (tally.notCovered, "not covered"),
            (tally.buildErrors, tally.buildErrors == 1 ? "build error" : "build errors"),
            (tally.timedOutAgain, "timed out again"),
        ]
        let came = counts.compactMap { count, words in count > 0 ? "\(count) \(words)" : nil }
        print("🔁 Ran \(timeouts) again, and \(changed) changed: \(came.joined(separator: ", ")).")
    }

    /// "⚠️ None of 40 mutants' test runs showed whether their code ran…": a run that can't tell survivors from mutants
    /// no test reached, or kills from flaky tests, as a test host that can't write there can't.
    func activationNotShown(runs: Int) {
        let (these, its, itsHost, itsCommand) = runs == 1
            ? ("The 1 mutant's test run didn't show", "its", "Its test host", "its test command")
            : ("None of \(runs) mutants' test runs showed", "their", "Their test host", "their test command")
        print(
            "⚠️ \(these) whether \(its) code ran, so verdicts stand as the runs had them, and no survivor reads as not "
                + "covered. \(itsHost) may be unable to write beside the mutated project, \(itsCommand) may not pass "
                + "the marker on, or a test plan's code may come from an older SwiftMutator."
        )
    }

    /// "🔁 Running 3 failed test runs again, one at a time: their mutants' code didn't run in them."
    func unprovenRunsRerunStarted(count: Int) {
        let runs = count == 1 ? "1 failed test run" : "\(count) failed test runs"
        let them = count == 1 ? "its mutant's code didn't run in it" : "their mutants' code didn't run in them"
        print("🔁 Running \(runs) again, one at a time: \(them).")
    }

    /// "🔁 Tested them again: 1 killed, 2 not covered."
    func unprovenRunsRerunFinished(_ tally: UnprovenRunTally) {
        let counts = [
            (tally.killed, "killed"),
            (tally.killedWithoutRunning, "failed again without their code running"),
            (tally.survived, "survived"),
            (tally.notCovered, "not covered"),
            (tally.timedOut, "timed out"),
            (tally.buildErrors, tally.buildErrors == 1 ? "build error" : "build errors"),
        ]
        let came = counts.compactMap { count, words in count > 0 ? "\(count) \(words)" : nil }
        print("🔁 Tested them again: \(came.joined(separator: ", ")).")
    }

    /// "⚠️ Not testing any kill again alone: the tests didn't pass alone with no mutant on. Its log: tests alone.log"
    func suspectKillRerunsSkipped(log: String?) {
        let itsLog = log.map { " Its log: \($0)" } ?? ""
        print("⚠️ Not testing any kill again alone: the tests didn't pass alone with no mutant on.\(itsLog)")
    }

    /// "🔁 Running 3 kills again, one at a time: only tests that may fail whatever the mutant failed for them."
    func suspectKillRerunsStarted(_ reruns: SuspectKillReruns) {
        let kills = reruns.count == 1 ? "1 kill" : "\(reruns.count) kills"
        let them = reruns.count == 1 ? "it" : "them"
        let leftOut = switch reruns.leftOut {
        case 0: ""
        case 1: " 1 more is over suspectKillReruns."
        default: " \(reruns.leftOut) more are over suspectKillReruns."
        }
        print(
            "🔁 Running \(kills) again, one at a time: only tests that may fail whatever the mutant failed for "
                + "\(them).\(leftOut)"
        )
    }

    /// "🔁 Tested them again: 1 still killed, 2 survived."
    func suspectKillRerunsFinished(_ tally: SuspectKillRerunTally) {
        let counts = [
            (tally.killed, "still killed"),
            (tally.survived, "survived"),
            (tally.notCovered, "not covered"),
            (tally.unsettled, "timed out or failed to build, so still count as killed"),
        ]
        let came = counts.compactMap { count, words in count > 0 ? "\(count) \(words)" : nil }
        print("🔁 Tested them again: \(came.joined(separator: ", ")).")
    }

    /// "🔁 The simulator didn't launch the tests for Rules.swift:42:17 (changed == to !=), so they ran again: …": a
    /// mutant's run that ran again in place of one the simulator failed to launch, with the line that showed it, while
    /// the progress bar is still to be redrawn. Not a progress line: the progress counts the second run.
    func runRepeatedAfterLaunchFailure(_ repeated: RepeatedRun) {
        let mutant = repeated.mutant
        let place = "\(mutant.point.fileName):\(mutant.point.position.line):\(mutant.point.position.column)"
        let change = mutant.snapshot.description.isEmpty ? "" : " (\(mutant.snapshot.description))"
        print(
            "🔁 The simulator didn't launch the tests for \(place)\(change), so they ran again. "
                + "The first run's log, \(repeated.log.keptFileName), says: \(repeated.line)"
        )
        leaveRoomForTheProgressBar()
    }

    /// "🔁 The simulator didn't launch the baseline's tests, so they ran again. …": an xcodebuild baseline that ran
    /// again in place of one the simulator failed to launch, with the line that showed it, before any progress is
    /// drawn.
    func baselineRepeatedAfterLaunchFailure(line: String, keptFileName: String) {
        print(
            "🔁 The simulator didn't launch the baseline's tests, so they ran again. "
                + "The first run's log, \(keptFileName), says: \(line)"
        )
    }
}
