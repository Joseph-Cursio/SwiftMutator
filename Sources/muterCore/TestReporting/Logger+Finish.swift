import Foundation

/// What the Logger says when mutation testing finishes or ends early, with the time estimates and shell quoting its
/// messages use.
extension Logger {
    /// "72 s", "41.2 s": `seconds` to a tenth.
    /// "4.2 s": `seconds` to a tenth.
    static func seconds(_ seconds: TimeInterval) -> String {
        String(format: "%g", (seconds * 10).rounded() / 10) + " s"
    }

    /// The time left with `tested` of `total` mutants tested on `workers` workers, `elapsed` seconds after they
    /// started. Until as many mutants have finished as there are workers, about one each, a rate would count the
    /// mutants still running as if none had started, so the `firstEstimate` counts down. After that, it is the time per
    /// mutant so far times the mutants left.
    static func secondsLeft(
        tested: Int,
        of total: Int,
        workers: Int,
        elapsed: TimeInterval?,
        firstEstimate: TimeInterval
    ) -> TimeInterval {
        let left = total - tested
        guard left > 0 else { return 0 }
        guard let elapsed, tested > 0, tested >= min(max(workers, 1), total) else {
            return max(firstEstimate - (elapsed ?? 0), 0)
        }
        return elapsed / Double(tested) * Double(left)
    }

    /// The time left before any mutant has finished. Each worker tests its share of the `remaining` mutants, a `cycle`
    /// for each, while the others test theirs, so the largest share sets it. The cycle is the timed test run, which
    /// skips the build as a mutant's run does, or else the baseline, build included.
    static func initialEstimate(remaining: Int, cycle: TimeInterval, workers: Int) -> TimeInterval {
        let largestShare = ceil(Double(remaining) / Double(max(workers, 1)))
        return largestShare * cycle
    }

    /// Where the report went, with the score (`MuterTestReport.scoreLine(of:)`), or the report itself, then where each
    /// of the `otherReports` went, then the report's `suspectWarning` (`KillingTestSummary.warning(for:)`), if it has
    /// one: the run's last word on its score.
    func mutationTestingFinished(
        report: String,
        reportPath: String,
        isExportingReport: Bool,
        didSaveReport: Bool,
        scoreLine: String,
        suspectWarning: String? = nil,
        buildErrorWarning: String? = nil,
        unprovenKillWarning: String? = nil,
        otherReports: [(path: String, saved: Bool)] = []
    ) {
        print("🏁 SwiftMutator finished running!")

        if !isExportingReport {
            print(
                """
                📝 SwiftMutator's report

                \(report)
                """
            )
        } else if didSaveReport {
            print("📊 \(scoreLine)")
            print("📝 Report generated: \(reportPath.bold)")
        } else {
            print(report)
            print("\n")
            print("Could not save report!")
        }
        otherReports.map(Self.whereItWent).forEach { print($0) }

        if let suspectWarning {
            print("⚠️ \(suspectWarning)")
        }
        if let buildErrorWarning {
            print("⚠️ \(buildErrorWarning)")
        }
        if let unprovenKillWarning {
            print("⚠️ \(unprovenKillWarning)")
        }
    }

    /// How many lines of a run of one mutant's log are printed whole. A longer log is printed from its last
    /// `logLinesShownOfALongLog`.
    static let logLinesShownWhole = 400

    static let logLinesShownOfALongLog = 200

    /// What the one mutant `--mutant` tested found, in place of the report: the mutant and its switch ID, what it
    /// changes, its tests' log, its verdict, the mutated project the run leaves, and the command that runs its tests
    /// there with it on; then where each requested report went.
    func oneMutantTested(_ run: OneMutantRun, reports: [(path: String, saved: Bool)]) {
        print("🏁 SwiftMutator finished running!")
        let change = run.snapshot.description.isEmpty ? "" : " (\(run.snapshot.description))"
        var lines = ["🔬 \(run.key)\(change)", "Switch: \(run.switchID)", "Change:"]
        lines += run.change.map { "  " + $0 }
        lines.append(run.logPath.map { "Tests (log: \($0)):" } ?? "Tests:")
        lines += Self.shown(log: run.testLog, kept: run.logPath != nil).map { $0.isEmpty ? "" : "  " + $0 }
        lines.append("Verdict: " + Self.verdict(of: run))
        if run.leftOutOfTheBuild {
            lines.append("Mutated project kept, without the mutant: \(run.mutatedProject)")
        } else {
            lines.append("Mutated project kept, with the mutant switched off: \(run.mutatedProject)")
            lines += Self.switchingOn(run)
        }
        lines.forEach { print($0) }
        reports.map(Self.whereItWent).forEach { print($0) }
    }

    /// "📝 Report generated: <path>", or that it couldn't be saved there.
    static func whereItWent(_ report: (path: String, saved: Bool)) -> String {
        report.saved ? "📝 Report generated: \(report.path.bold)" : "⚠️ Could not save the report to \(report.path)"
    }

    /// `log`'s lines, or its last `logLinesShownOfALongLog` after a line saying how many come before them, when it has
    /// more than `logLinesShownWhole`; those are in the log folder's copy if it is `kept`.
    static func shown(log: String, kept: Bool) -> [String] {
        var lines = log.components(separatedBy: "\n")
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return ["(the tests printed nothing)"] }
        guard lines.count > logLinesShownWhole else { return lines }
        let earlier = lines.count - logLinesShownOfALongLog
        let left = kept ? "are in the log" : "are left out"
        return ["… \(earlier) earlier lines \(left)"] + lines.suffix(logLinesShownOfALongLog)
    }

    /// "killed by sum() and product() (2 failed tests), in 4.2 s", "survived, in 4.2 s", "timed out after 30 s".
    static func verdict(of run: OneMutantRun) -> String {
        let took = ", in " + seconds(run.seconds)
        switch run.outcome {
        case .failed, .runtimeError:
            guard let killing = run.killingTests, !killing.tests.isEmpty else {
                return (run.outcome == .runtimeError ? "killed: the tests crashed" : "killed: the tests failed") + took
            }
            let named = killing.tests.prefix(3).map(\.name)
            let more = killing.count - named.count
            let tests = more > 0 ? named.joined(separator: ", ") + " and \(more) more" : listed(named)
            let count = killing.count == 1 ? "1 failed test" : "\(killing.count) failed tests"
            return "killed by \(tests) (\(count))" + took

        case .passed:
            return "survived" + took

        case .timeout:
            return "timed out after " + seconds(run.timeoutSeconds ?? run.seconds)

        case .buildError:
            return run.leftOutOfTheBuild ? "didn't compile, so its tests didn't run" : "build error" + took

        case .noCoverage:
            return "not covered"
        }
    }

    /// How to run the mutant's tests in the mutated project with it on, as its run did: for `swift test`, by its file
    /// beside the project (`MutationTestingDelegate.activeMutantFile(forWorkerIn:)`), and for another test command, by
    /// its environment variable. For xcodebuild, whose run sets it in `muter.xctestrun`, only the variable is named.
    static func switchingOn(_ run: OneMutantRun) -> [String] {
        let project = shellQuoted(run.mutatedProject)
        let command = run.testCommand.map(shellWord).joined(separator: " ")
        let muterRunning = "\(isMuterRunningKey)=\(isMuterRunningValue)"
        switch run.buildSystem {
        case .swift:
            let file = shellQuoted(
                MutationTestingDelegate.activeMutantFile(forWorkerIn: URL(fileURLWithPath: run.mutatedProject)).path
            )
            return [
                "To run its tests with it on:",
                "  printf '%s\\n' \(shellQuoted(run.switchID)) > \(file) && cd \(project) && \(muterRunning) "
                    + "\(activeMutantFileKey)=\(file) \(command)",
            ]

        case .xcodebuild:
            return [
                "To run its tests with it on, set \(run.switchID)=YES and \(muterRunning) in their environment, and "
                    + "SIMCTL_CHILD_\(run.switchID)=YES for a simulator.",
            ]

        case .unknown:
            return [
                "To run its tests with it on:",
                "  cd \(project) && env \(muterRunning) \(shellQuoted(run.switchID + "=YES")) \(command)",
            ]
        }
    }

    /// `text` as one word for a POSIX shell, so that a printed command pastes whatever the path holds: log folders are
    /// named like `Oct 4, 2026 at 1:16 PM`.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The characters a POSIX shell gives no meaning to, in any place in a word that isn't a command's name.
    static let plainWordCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-".unicodeScalars
    )

    /// `text` as it is if a POSIX shell reads it as that one word, and quoted as `shellQuoted` quotes it otherwise:
    /// a printed command keeps the arguments it repeats as readable as they were typed.
    static func shellWord(_ text: String) -> String {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(plainWordCharacters.contains) else {
            return shellQuoted(text)
        }
        return text
    }
}
