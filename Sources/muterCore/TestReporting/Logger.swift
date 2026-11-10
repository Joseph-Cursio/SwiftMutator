import Foundation

/// Its state changes only as the run's events arrive, which `RunEvents` hands out one at a time from whichever thread
/// sends them, so it needs no lock of its own.
final class Logger: @unchecked Sendable { // events reach it one at a time (see `RunEvents`)
    @Dependency(\.printer)
    private var printer: Printer
    @Dependency(\.errorPrinter)
    private var errorPrinter: Printer
    @Dependency(\.instant)
    private var instant: Instant
    @Dependency(\.now)
    private var now: Now
    @Dependency(\.standardOutIsATerminal)
    private var standardOutIsATerminal: Bool
    @Dependency(\.flushStandardOut)
    private var flushStandardOut: Flush
    /// When the mutants started, which the estimate of the time left measures their rate from.
    private var mutantRunsStartedAt: DispatchTime?
    /// How many mutants the progress bar or the progress lines count: those discovered, or those a resumed run has
    /// left to test.
    var numberOfMutationPoints: Int = 0
    private var progressBar: ProgressBar?
    /// In place of the progress bar, when standard output isn't a terminal.
    private var progressLines: ProgressLines?
    /// How many lines the progress bar takes. Its printer redraws it by moving the cursor up over that many lines.
    private static let progressBarLines = 2

    func launched() {
        print(
            """
            \(muterLogoForTerminal)

            Automated mutation testing for Swift 🕳️

            You are running version \("\(version)".bold)

            Want help? Have suggestions? Want to get involved?
             ↳ https://github.com/Joseph-Cursio/SwiftMutator/issues
            +--------------------------------------------------------+

            """
        )
    }

    func updateCheckStarted() {
        print("🔎 Checking for new versions...")
    }

    func updateCheckFinished(newVersion: String?) {
        if let newVersion {
            print("🎉 New version \(newVersion) available!")
        } else {
            print("✅ You are already using the latest of SwiftMutator")
        }
    }

    func mutantRunsStarted() {
        mutantRunsStartedAt = instant()
    }

    func newMutationTestLogAvailable(mutationTestLog: MutationTestLog) {
        if mutationTestLog.mutationPoint == nil {
            print(
                """
                📊 Determined baseline for mutation testing.
                🧟 SwiftMutator is now going to apply each mutant one at a time and run your test suite for each mutant.
                📃 After this step, SwiftMutator will generate a report detailing the efficacy of your test suite.
                ☕️ This step may take a while.

                """
            )

            // The mutants this session tests, which the baseline's log carries: fewer than were discovered when
            // --mutant picks one of them.
            let total = mutationTestLog.remainingMutationPointsCount ?? numberOfMutationPoints
            let estimate = SimpleTimeEstimate(
                firstEstimate: Self.initialEstimate(
                    // The baseline's log carries both.
                    remaining: total,
                    cycle: mutationTestLog.testRunSeconds ?? mutationTestLog.timePerBuildTestCycle ?? 0,
                    workers: mutationTestLog.workers
                ),
                workers: mutationTestLog.workers
            ) { [weak self] in self?.secondsSinceMutantRunsStarted() }
            if standardOutIsATerminal {
                progressBar = ProgressBar(
                    count: total,
                    configuration: [
                        ProgressString(string: "Inserting mutant"),
                        ProgressOneIndexed(),
                        ProgressString(string: "\nPercentage complete: "),
                        ProgressPercent(),
                        // So that the line fits in an 80-column terminal. One that wraps takes another row, which a
                        // redraw doesn't move up over, so it's left behind on screen.
                        ColoredProgressBarLine(barLength: 30),
                        estimate,
                    ],
                    printer: ProgressBarMultilineTerminalPrinter(numberOfLines: Self.progressBarLines)
                )
            } else {
                let lines = ProgressLines(total: total, estimate: estimate)
                progressLines = lines
                print(lines.firstLine(at: now()))
            }
        }

        progressBar?.next()
    }

    /// A mutant's result, once it is saved: its line, when standard output isn't a terminal. A resumed run's kept
    /// results are sent before the baseline's log, which starts the lines, so only the mutants this session tests are
    /// counted, as the bar counts them.
    func newMutationTestOutcomeAvailable(mutation: MutationTestOutcome.Mutation) {
        if let line = progressLines?.line(after: mutation, at: now()) {
            print(line)
        }
    }

    /// The mutants under way once none has finished for a while: a line, when standard output isn't a terminal, where
    /// nothing else would print until one does. A terminal's progress bar redraws itself, and a line would break that.
    func stillTesting(_ still: StillTesting) {
        if let line = progressLines?.stillTestingLine(still, at: now()) {
            print(line)
        }
    }

    /// The seconds since the mutants started, or nil before they have.
    private func secondsSinceMutantRunsStarted() -> TimeInterval? {
        guard let start = mutantRunsStartedAt else { return nil }
        let instantNow = instant()
        guard instantNow >= start else { return 0 }
        return Double(instantNow.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// What mutation testing tested before it stopped early, and the warning of suspect tests its report gives, if it
    /// gives one, then where its partial reports are, if it has any, why it saved no baseline file, if one was asked
    /// for, where each result is, the command that makes a
    /// report of them all, and the command that continues the run. A resumed session counts the mutants it tested apart
    /// from the results it kept. On standard error: it reaches the terminal even when a `| tee` that the same Ctrl-C
    /// ended has closed standard output. An abort's error follows on standard output.
    func mutationTestingEndedEarly(
        _ earlyEnd: EarlyEnd,
        partialReports: [(path: String, saved: Bool)],
        baselineFile: BaselineFileSaving? = nil,
        resultsFile: String?,
        continueCommand: String?
    ) {
        let results = earlyEnd.outcome.mutations.count
        var lines = [Self.stopped(earlyEnd)]
        if let suspectWarning = KillingTestSummary.warning(for: earlyEnd.outcome) {
            lines.append("⚠️ \(suspectWarning)")
        }
        lines += partialReports.map { partialReport in
            partialReport.saved
                ? "📝 Partial report: \(partialReport.path.bold)"
                : "⚠️ Could not save the partial report to \(partialReport.path)"
        }
        if let baselineFile {
            lines.append(baselineFile.line)
        }
        if let resultsFile {
            lines.append("💾 Each tested mutant's result is in \(resultsFile.bold)")
            // Without a result, the report would be empty, and a resume would keep nothing a new run doesn't.
            if results > 0 {
                lines.append("📝 Full report: swift-mutator report \(Self.shellQuoted(resultsFile))")
                if let continueCommand {
                    lines.append("▶️ Continue: \(continueCommand)")
                }
            }
        }
        lines.forEach(errorPrinter)
    }

    /// "⏹ Stopped by SIGINT after testing 3 of 9 mutants. Mutation score so far: 50%." A resumed session says how many
    /// of the mutants left it tested, and how many of every mutant have a result, kept or tested; the score is theirs.
    private static func stopped(_ earlyEnd: EarlyEnd) -> String {
        let stoppedBy = earlyEnd.reason == .interrupted ? "by \(earlyEnd.detail ?? "a signal")" : "by the error below"
        let results = earlyEnd.outcome.mutations.count
        guard results > 0 else {
            return "⏹ Stopped \(stoppedBy) before any of \(earlyEnd.discovered) mutants finished."
        }
        let score = "Mutation score so far: "
            + "\(mutationScore(from: earlyEnd.outcome.mutations.map(\.testSuiteOutcome)))%."
        let tested = results - earlyEnd.reused - earlyEnd.leftOut
        let didNotCompile = earlyEnd.leftOut == 0
            ? ""
            : "\(earlyEnd.leftOut) more \(earlyEnd.leftOut == 1 ? "was" : "were") taken out of the build. "
        guard earlyEnd.reused > 0 else {
            return "⏹ Stopped \(stoppedBy) after testing \(tested) of \(earlyEnd.discovered) mutants. "
                + didNotCompile + score
        }
        let left = earlyEnd.discovered - earlyEnd.reused
        let progress = tested == 0
            ? "before any of the \(left) mutants left finished"
            : "after testing \(tested) of the \(left) mutants left"
        return "⏹ Stopped \(stoppedBy) \(progress): \(results) of \(earlyEnd.discovered) have results. "
            + didNotCompile + score
    }

    /// Every line Muter logs goes through here, and so through the injected `printer`.
    ///
    /// The printer used to be a property also named `print`. Calls to `print("…")` inside this
    /// type were then ambiguous between that property and this method, and newer compilers
    /// pick this method, which wrote straight to standard output and bypassed the printer.
    ///
    /// Off a terminal, standard output is block-buffered: a log file or a `| tee` would get each line up to 16 KB late,
    /// lose the last ones to a crash or a SIGKILL, and get them after anything later on standard error. So each line
    /// is flushed there.
    func print(_ message: String) {
        printer(message)
        if !standardOutIsATerminal {
            flushStandardOut()
        }
    }

    func printMessage(_ message: String) {
        print("+-----------------+")
        print(message)
    }

    /// Follows a message printed while the progress bar is still to be redrawn with as many empty lines as the bar
    /// takes. The redraw moves the cursor up over those lines rather than over the end of the message. The bar's
    /// `next()` redraws it only while `element <= count`, so the bar's last redraw needs no room after it.
    func leaveRoomForTheProgressBar() {
        guard let progressBar, progressBar.element <= progressBar.total else {
            return
        }
        for _ in 0 ..< Self.progressBarLines {
            print("")
        }
    }
}
