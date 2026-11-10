import Foundation

/// What the Logger says around the mutant runs: how they're built and run, and the results file and the checks made
/// on it afterwards.
extension Logger {
    func mutationTestingStarted() {
        printMessage(
            """
            🚀 Mutation testing will now begin
            ⚙️ Running your test suite to determine a baseline for mutation testing...
            """
        )
    }

    func stopAtFirstFailureTurnedOff(reason: String) {
        print("⚠️ stopAtFirstFailure is off for this run, so every mutant's tests run to the end: \(reason)")
    }

    func testBundlesNotRunDirectly(reason: String) {
        print("ℹ️ Each mutant's tests run through `swift test`, which takes about a second longer per mutant: \(reason)")
    }

    func stoppedRunRecorded(path: String) {
        print("📝 Why the run stopped before its first mutant is in \(path), which `report` reads.")
    }

    func timedTestRunStopped(seconds: TimeInterval, log: String?) {
        let kept = log.map { " Its log is in \($0)." } ?? ""
        print(
            "⚠️ The timed test run, with no mutant on, didn't end within \(String(format: "%g", seconds)) s, so "
                + "SwiftMutator stopped it, and takes each mutant's time limit from the baseline instead.\(kept)"
        )
    }

    func buildingAgainWithoutMutants(count: Int) {
        let mutants = count == 1 ? "1 mutant is, so SwiftMutator is building again without it"
            : "\(count) mutants are, so SwiftMutator is building again without them"
        print("🔁 The build failed where \(mutants).")
    }

    func buildingAgainWithSwitchesInAClosure(count: Int) {
        let mutants = count == 1 ? "1 mutant" : "\(count) mutants"
        print(
            "🔁 The build failed where a result builder can't take an `if`, so SwiftMutator is building again with "
                + "the switch of \(mutants) in a closure called on the spot."
        )
    }

    func stoppedTakingOutMutants(afterBuilds builds: Int) {
        print(
            "⚠️ SwiftMutator takes mutants out after at most \(builds) failed builds, so the errors below may still be "
                + "mutants'. Leave their files out with --files-to-mutate or `exclude`, or their operators with "
                + "--skip-operators."
        )
    }

    /// Which mutants the run won't test, and why, each as `--mutant` takes it. A list long enough to scroll the run's
    /// start away is cut short: each mutant's log, and the results file, have the rest. No line says `warning:` or
    /// `error:` after a file's place, which Xcode would take for an issue of its own.
    func mutantsLeftOutOfTheBuild(_ leftOut: MutantsLeftOut) {
        let count = leftOut.mutants.count
        let shown = leftOut.mutants.prefix(MutantsLeftOut.namedAtMost).map { "  \($0.line)" }
        let more = count > shown.count ? ["  … and \(count - shown.count) more: each one's log says why"] : []
        let withOthers = leftOut.mutants.count { $0.mutant.blame != .itself }
        let said = switch (count, withOthers) {
        case (1, 0):
            "1 mutant doesn't compile, so SwiftMutator took it out of the build, and won't test it. The score leaves "
                + "it out, the reports list it as a build error, and --resume tries it again:"

        case (_, 0):
            "\(count) mutants don't compile, so SwiftMutator took them out of the build, and won't test them. The "
                + "score leaves them out, the reports list them as build errors, and --resume tries them again:"

        default:
            "SwiftMutator took \(count) mutants out of the build, and won't test them: the compiler's errors could be "
                + "pinned on \(count - withOthers), and \(withOthers) went with others around the errors, and may "
                + "compile. The score leaves them out, the reports list them as build errors, and --resume tries them "
                + "again:"
        }
        let nothingLeft = leftOut.toTest == 0 ? ["⚠️ That leaves no mutant to test."] : []
        print((["⚠️ \(said)"] + shown + more + nothingLeft).joined(separator: "\n"))
    }

    func workersShareUserDefaults() {
        print(
            "ℹ️ Workers running through `swift test` share `UserDefaults.standard`: tests that write to it can fail "
                + "each other and kill mutants they don't check. See \"Tests that share state across workers\" in "
                + "the README."
        )
    }

    func testBundlesWroteInTheProject(path: String) {
        let place = path.isEmpty ? "the top folder" : path
        print("ℹ️ Workers can't share one build: a run of your tests, with no mutant on, changed \(place) in the copy.")
    }

    func resultsFileCreated(atPath path: String) {
        print("💾 SwiftMutator saves each mutant's result as it finishes, in \(path.bold)")
    }

    func resultsFileUnavailable(reason: String) {
        print(
            "⚠️ SwiftMutator can't save each mutant's result as it goes: \(reason). "
                + "The report at the end doesn't depend on it."
        )
        leaveRoomForTheProgressBar()
    }

    func resultsFileKept(atPath path: String) {
        print("💾 Each mutant's result is in \(path.bold)")
    }

    /// The verdict on the score against the run's threshold, as the run's last line, on standard output with the rest:
    /// ✅ when it passes, ❌ when it is below, ⚠️ when it isn't checked. Nothing for a run that ended early.
    func scoreGateChecked(_ gate: ScoreGate) {
        guard let line = gate.line else { return }
        let emoji = switch gate.passed {
        case .some(true): "✅"
        case .some(false): "❌"
        case .none: "⚠️"
        }
        print("\(emoji) \(line)")
    }

    /// The verdict on the survivors against `--baseline`'s file, after the score's, on standard output with the rest:
    /// ✅ when it passes, ❌ when too many survivors are new, ⚠️ when they aren't compared, then each new survivor, up
    /// to `NewSurvivorsCheck.shownNewSurvivors`. A line before it notes a baseline file another SwiftMutator version
    /// wrote. Nothing for a run that ended early.
    func newSurvivorsChecked(_ check: NewSurvivorsCheck) {
        check.consoleLines.forEach { print($0) }
    }

    /// The verdict on the score against `--baseline`'s file's, after the survivors', on standard output with the rest:
    /// ✅ when it passes, ❌ when the score fell too far, ⚠️ when the scores aren't compared. Nothing for a run that
    /// ended early.
    func scoreDropChecked(_ check: ScoreDropCheck) {
        check.consoleLines.forEach { print($0) }
    }

    /// The verdict on the kills the run's evidence doesn't back, last, on standard output with the rest: ✅ when it
    /// passes, ❌ when too many are doubtful, then each, up to `DoubtfulKillsCheck.shownDoubtfulKills`. Nothing for a
    /// run that ended early.
    func doubtfulKillsChecked(_ check: DoubtfulKillsCheck) {
        check.consoleLines.forEach { print($0) }
    }

    /// Where a finished run saved its survivors as `--write-baseline` asked, or why it saved none.
    func baselineFileSaved(_ saving: BaselineFileSaving) {
        print(saving.line)
    }
}
