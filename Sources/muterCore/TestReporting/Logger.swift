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
    private(set) var numberOfMutationPoints: Int = 0
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

    /// How many Swift files changed since `--since`'s merge base, and with `verbose`, their paths.
    func changesSelected(_ selection: ChangeSelection, verbose: Bool = false) {
        let count = selection.files.count == 1 ? "1 Swift file" : "\(selection.files.count) Swift files"
        let lines = selection.changedLines ? ", of which only the changed lines are mutated" : ""
        let changed = "🌿 \(count) changed since the merge base of \(selection.shownRef) and HEAD "
            + "(\(selection.shortMergeBase))\(lines)."
        if verbose, !selection.files.isEmpty {
            print("\(changed)\n\n\(selection.files.map(\.path).joined(separator: "\n").bold)")
        } else {
            print(changed)
        }
        if let folders = selection.foldersNotCompared {
            let named = folders.prefix(5).joined(separator: ", ") + (folders.count > 5 ? ", …" : "")
            print(
                "⚠️ git doesn't compare what is in \(folders.count == 1 ? "a folder" : "folders") that "
                    + "\(folders.count == 1 ? "is a repository" : "are repositories") of its own, so none of "
                    + "\(folders.count == 1 ? "its" : "their") files is mutated: \(named)."
            )
        }
    }

    /// The earlier runs whose log folders `keepLogFolders` removed, up to 5 of them by name, then a line for each it
    /// left and why. With none removed, a line first says where those left are, and why they would have gone.
    func logFoldersPruned(_ pruning: LogFolderPruning) {
        var lines: [String] = []
        if pruning.removed.isEmpty, !pruning.left.isEmpty {
            let runs = pruning.left.count == 1 ? "1 earlier run" : "\(pruning.left.count) earlier runs"
            lines.append(
                "🧹 Left the log folders of \(runs) in \(pruning.root), beyond the newest \(pruning.keeping) runs "
                    + "(keepLogFolders: \(pruning.keeping)):"
            )
        } else if !pruning.removed.isEmpty {
            let runs = pruning.removed.count == 1 ? "1 earlier run" : "\(pruning.removed.count) earlier runs"
            lines.append(
                "🧹 Removed the log folders of \(runs), \(Self.size(pruning.freedBytes)), from \(pruning.root), "
                    + "keeping the newest \(pruning.keeping) runs (keepLogFolders: \(pruning.keeping)):"
            )
            lines += pruning.removed.prefix(5).map { removed in
                "  " + removed.folders.joined(separator: ", ")
                    + (removed.shard.map { " (shard \($0.index) of \($0.count))" } ?? "")
            }
            if pruning.removed.count > 5 {
                lines.append("  … and \(pruning.removed.count - 5) more")
            }
        }
        lines += pruning.left.map { left in
            let folders = left.folders.joined(separator: ", ")
            switch left.reason {
            case .inUse:
                return "⚠️ Left \(folders): another SwiftMutator run is using it."
            case let .couldNotCheck(reason):
                return "⚠️ Left \(folders): couldn't tell whether another SwiftMutator run is using it: \(reason)"
            case let .foreignFiles(files):
                let named = files.prefix(5).joined(separator: ", ")
                    + (files.count > 5 ? " and \(files.count - 5) more" : "")
                return "⚠️ Left \(folders): it holds files SwiftMutator didn't write: \(named)"
            case let .couldNotRemove(reason):
                return "⚠️ Couldn't remove \(folders): \(reason)"
            }
        }
        guard !lines.isEmpty else { return }
        print(lines.joined(separator: "\n"))
    }

    /// `bytes` in decimal units, to one decimal place: "1.9 GB", "512 bytes".
    static func size(_ bytes: Int64) -> String {
        let units = ["KB", "MB", "GB", "TB", "PB"]
        guard bytes >= 1000 else { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 999.95, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return String(format: "%.1f ", value) + units[unit]
    }

    func projectCopyStarted() {
        print("✂️ Copying your project to a temporary directory for testing...")
    }

    func projectCopySkippedVanishedFiles(_ paths: [String]) {
        let shown = paths.prefix(5).map { "  \($0)" }
        let more = paths.count > shown.count ? ["  … and \(paths.count - shown.count) more"] : []
        print(
            (["⚠️ Skipped \(paths.count) file(s) that disappeared while your project was being copied:"] + shown + more)
                .joined(separator: "\n")
        )
    }

    func projectCopyFinished(destinationPath: String) {
        print(
            """
            ✅ Finished copying your project to a temporary directory for mutation testing.
            You can find your copied project here:

            \(destinationPath.bold)
            """
        )
    }

    func projectCoverageDiscoveryStarted() {
        print("⚙️ Running tests with coverage enabled to determine which files to mutate")
    }

    /// Why coverage couldn't be gathered, if it couldn't, and where the coverage run's output is, if it's kept.
    func projectCoverageDiscoveryFinished(failureReason: String?, log: String? = nil) {
        guard let failureReason else {
            return
        }

        let output = log.map { "\nThe coverage run's output is in \($0.bold)" } ?? ""
        print(
            """
            ❌ Gathering coverage failed: \(failureReason).\(output)
            Proceeding with mutation testing anyway.
            Pass \("--skip-coverage argument".bold) to disable this step
            """
        )
    }

    /// The tests that failed in the coverage run, up to 5 of them, although coverage was gathered from every test
    /// process, and that the code a failed test skipped reads as never run, then where the run's output is, if it's
    /// kept.
    func projectCoverageTestsFailed(_ failed: TestsFailedWithCoverage) {
        let (names, more) = failed.tests.named(upTo: FailedTestLine.coverageMessageLimit)
        let tests = failed.tests.count == 1 ? "1 test" : "\(failed.tests.count) tests"
        let lines = ["⚠️ \(tests) failed with coverage on, but coverage was still gathered from every test process:"]
            + names.map { "  \($0)" }
            + (more > 0 ? ["  … and \(more) more"] : [])
            + ["Code a failed test would have run after it stopped reads as never run, so its mutants aren't tested."]
            + (failed.log.map { ["The coverage run's output is in \($0.bold)"] } ?? [])
        print(lines.joined(separator: "\n"))
    }

    func sourceFileDiscoveryStarted() {
        printMessage("🔎 Discovering Swift files which SwiftMutator will analyze...")
    }

    /// Why the Swift files a SwiftPM package's targets compile couldn't be listed, and what discovery does instead.
    func packageSourceFilesUnavailable(reason: String) {
        // SwiftPM's errors often end in one.
        let reason = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        print(
            """
            ⚠️ SwiftMutator couldn't tell which files the package's targets compile: \(reason).
            It looks at every Swift file in the project that isn't hidden or ignored instead, so a file no target \
            builds may get mutants no test can kill. \("exclude".bold) can leave such files out.
            """
        )
    }

    /// How many Swift files there are to analyze, and with `verbose`, each one's name: hundreds of lines on a large
    /// project.
    func sourceFileDiscoveryFinished(sourceFileCandidates: [String], verbose: Bool = false) {
        let discovered = "✅ In total, SwiftMutator discovered \(sourceFileCandidates.count) Swift files"
        guard verbose else {
            print(discovered)
            return
        }
        let fileNames = sourceFileCandidates
            .map(URL.init(fileURLWithPath:))
            .map { $0.lastPathComponent }
            .joined(separator: "\n")
            .bold

        print("\(discovered)\n\n\(fileNames)")
    }

    func mutationsDiscoveryStarted() {
        printMessage("🔎 Analyzing source files to find mutants which can be inserted into your project...")
    }

    /// How many mutants there are, in how many files, and with `verbose`, how many each file has. With `--sample` or
    /// `--shard`, `mutations` are the sample's or the shard's, and how many were discovered in all is said first; with
    /// both, they are the shard's part of the sample. A seed SwiftMutator chose is said on a line of its own.
    func mutationsDiscoveryFinished(
        mutations: [SchemataMutationMapping],
        verbose: Bool = false,
        sample: (selection: SampleSelection, seedIsChosen: Bool)? = nil,
        shard: ShardSelection? = nil
    ) {
        let numberOfFiles = mutations.count
        var filesSummary: [String: Int] = [:]

        for mutation in mutations {
            numberOfMutationPoints += mutation.mutationSchemata.count
            filesSummary[mutation.fileName, default: 0] += mutation.mutationSchemata.count
        }

        let discovered = switch (sample?.selection, shard) {
        case (nil, nil):
            "✅ In total, SwiftMutator discovered \(numberOfMutationPoints) mutants in \(numberOfFiles) files"
        case let (nil, shard?):
            "✅ In total, SwiftMutator discovered \(shard.mutantsInAllShards) mutants, and shard \(shard.index) of "
                + "\(shard.count) holds \(numberOfMutationPoints) of them, in \(numberOfFiles) files"
        case let (sample?, nil) where sample.isPartial:
            "✅ In total, SwiftMutator discovered \(sample.mutantsSampledFrom) mutants, and the sample of "
                + "\(sample.size) holds \(numberOfMutationPoints) of them, in \(numberOfFiles) files"
        case let (sample?, nil) where sample.mutantsSampledFrom <= sample.size:
            "✅ In total, SwiftMutator discovered \(numberOfMutationPoints) mutants in \(numberOfFiles) files, "
                + "no more than the sample of \(sample.size), which holds them all"
        // The last place it took had repeats enough to hold the rest.
        case let (sample?, nil):
            "✅ In total, SwiftMutator discovered \(numberOfMutationPoints) mutants in \(numberOfFiles) files, and "
                + "the sample of \(sample.size) holds them all"
        case let (sample?, shard?):
            "✅ In total, SwiftMutator discovered \(sample.mutantsSampledFrom) mutants, the sample of \(sample.size) "
                + "holds \(sample.mutantsSampled) of them, and shard \(shard.index) of \(shard.count) holds "
                + "\(numberOfMutationPoints) of those, in \(numberOfFiles) files"
        }
        var lines = [discovered]
        if let sample, sample.seedIsChosen {
            let seed = sample.selection.seed
            lines.append("🎲 SwiftMutator chose the sample's seed, \(seed): --seed \(seed) takes the same sample again.")
        }
        // With `verbose`, a blank line before the files.
        if verbose {
            lines[lines.count - 1] += "\n"
        }
        lines.forEach { print($0) }
        guard verbose else { return }
        for (fileName, mutantCount) in filesSummary {
            print("\(fileName) (\(mutantCount) mutants)".bold)
        }
    }

    /// How many of a resumed run's results still hold, and how many mutants are left to test and why; then how its
    /// discovery differs from the last session's, each change no result depends on, and what `--force-resume` and
    /// `--resume-ignoring` let through. A run that reuses an earlier run's results says the same, with `--reuse`'s
    /// flags, and names the changed files other than tests that make it test every mutant again. The progress bar or
    /// the progress lines then count only the mutants left.
    func resumePlanned(_ summary: ResumeSummary) {
        numberOfMutationPoints = summary.toTest
        let resuming = summary.isReuse
            ? "♻️ Reusing the results in \(summary.path.bold): "
            : "♻️ Resuming the run in \(summary.path.bold): "
        let reused = summary.reused == 1 ? "1 result still holds" : "\(summary.reused) results still hold"
        if summary.toTest == 0 {
            var held = summary.reused == 1 ? "its only result still holds" : "all \(summary.reused) results still hold"
            if summary.noLongerDiscovered > 0 || summary.outsideTheSample > 0 {
                // Not all the file's results: some no longer count.
                held = reused
            }
            print(resuming + "\(held), so nothing is left to test.")
        } else {
            let reasons = ResumePlan.Reason.allCases.compactMap { reason in
                summary.retestedBecause[reason].flatMap { $0 > 0 ? Self.retested($0, because: reason) : nil }
            }
            let left = summary.toTest == 1 ? "1 mutant is" : "\(summary.toTest) mutants are"
            let why = reasons.isEmpty ? "" : " (\(reasons.joined(separator: ", ")))"
            print(resuming + "\(reused), so \(left) left to test\(why).")
        }
        if let selectionChange = summary.selectionChange {
            print("ℹ️ \(selectionChange)")
        } else if let discoveryChange = Self.discoveryChange(summary) {
            print("⚠️ \(discoveryChange)")
        } else if let coverageChange = summary.coverageChange {
            // Gathered in both sessions, and the mutants are as many as before, so only said.
            let change = "\(coverageChange)"
            print(
                "ℹ️ \(change.prefix(1).uppercased() + change.dropFirst()), "
                    + "but every earlier result's mutant is still discovered."
            )
        }
        // Still discovered, but not sampled: a reuse of another sample, or of none, says why in `selectionChange`.
        if !summary.sampleChanged, summary.outsideTheSample > 0 {
            print(
                summary.outsideTheSample == 1
                    ? "ℹ️ 1 earlier result no longer counts, as the sample no longer takes its mutant."
                    : "ℹ️ \(summary.outsideTheSample) earlier results no longer count, as the sample no longer takes "
                    + "their mutants."
            )
        }
        for notice in summary.notices {
            print("ℹ️ \(notice)")
        }
        if let otherFiles = Self.otherFilesChanged(summary) {
            print("⚠️ \(otherFiles)")
        } else if summary.testFilesChanged > 0 {
            let files = summary.testFilesChanged == 1 ? "1 test file" : "\(summary.testFilesChanged) test files"
            print(
                "ℹ️ \(files) changed, so every survivor is tested again, and every kill that no unchanged test "
                    + "still holds."
            )
        }
        let force = summary.isReuse ? "--force-reuse" : "--force-resume"
        let ignoring = summary.isReuse ? "--reuse-ignoring" : "--resume-ignoring"
        if !summary.forced.isEmpty {
            let subjects = summary.forced.map { name in
                let subject = ResumeCheck.subject(of: name)
                return subject.hasPrefix("The ") ? "the " + subject.dropFirst(4) : subject
            }
            print("⚠️ Results are reused although \(Self.listed(subjects)) changed (\(force)).")
        }
        if !summary.waived.isEmpty {
            let named = summary.waived.prefix(ResumeRefusal.changedFilesNamed)
            let others = summary.waived.count - named.count
            let one = summary.waived.count == 1
            // As `ResumeRefusal.copyChanged` names them.
            let files = summary.testPlanCopy.map { copy in
                "\(summary.waived.count) file\(one ? "" : "s") of the test plan's copy, \(copy),"
            } ?? (one ? "1 project file" : "\(summary.waived.count) project files")
            print(
                "⚠️ Results are reused although \(files) changed (\(ignoring)): "
                    + named.joined(separator: ", ") + (others > 0 ? ", and \(others) more" : "")
            )
        }
    }

    /// "2 project files other than tests changed since that run's results were tested, so they are tested again:
    /// Package.resolved (changed), README.md (changed). If they can't change any test's result: --reuse-ignoring
    /// 'Package.resolved' …": what made a reuse test results again whatever they were; nil if nothing did. A file that
    /// changed after one session of the earlier run, and before the next, makes it test only the first one's.
    private static func otherFilesChanged(_ summary: ResumeSummary) -> String? {
        let changes = summary.otherFilesChanged
        guard !changes.isEmpty else { return nil }
        let named = changes.prefix(ResumeRefusal.changedFilesNamed)
        let others = changes.count - named.count
        let one = changes.count == 1
        let files = named.map { "\($0.path) (\($0.kind.rawValue))" }.joined(separator: ", ")
            + (others > 0 ? ", and \(others) more" : "")
        let flags = named.map { "--reuse-ignoring " + shellQuoted(ResumeRefusal.glob(matching: $0.path)) }
            .joined(separator: " ")
            + (others > 0 ? ", plus globs for the other \(others)" : "")
        return "\(changes.count) project file\(one ? "" : "s") other than tests changed since that run's results were "
            + "tested, so they are tested again: \(files). If \(one ? "it" : "they") can't change any test's result: "
            + flags
    }

    /// "412 earlier results no longer count, as this session doesn't discover their mutants: coverage couldn't be
    /// gathered then, and is now.": how a resumed run's discovery differs from the last session's, and the coverage
    /// change that may explain it; nil if nothing shows it does. Based on the counts, as discovery can change while
    /// coverage looks the same: xcodebuild can lose regions without a word, `--force-resume` lets a SwiftMutator that
    /// discovers differently through, and the files discovery picks from come from `swift package describe` or git,
    /// which may work in one session only.
    private static func discoveryChange(_ summary: ResumeSummary) -> String? {
        let lost = summary.noLongerDiscovered
        if lost > 0 {
            let because = reason(summary.coverageChange, if: \.canLeaveOutMutants)
            return lost == 1
                ? "1 earlier result no longer counts, as this session doesn't discover its mutant\(because)."
                : "\(lost) earlier results no longer count, as this session doesn't discover their mutants\(because)."
        }
        // A partial sample's count is the sample's, which moves as new mutants rank into it, not discovery's.
        if summary.discovered != summary.discoveredBefore, !summary.sampleIsPartial {
            let more = summary.discovered > summary.discoveredBefore
            let because = reason(summary.coverageChange, if: more ? \.canBringInMutants : \.canLeaveOutMutants)
            let mutants = summary.discovered == 1 ? "1 mutant" : "\(summary.discovered) mutants"
            return "This session discovers \(mutants), and the last one discovered \(summary.discoveredBefore)"
                + "\(because)."
        }
        if let change = summary.coverageChange, change.isGatheredInOneSessionOnly {
            return "This session discovers as many mutants as the last one, although \(change)."
        }
        return nil
    }

    /// ": coverage couldn't be gathered then, and is now": `change`, if it `fits` the way discovery changed; empty if
    /// there is none, or it would push the count the other way, as losing coverage can't leave out a mutant.
    private static func reason(
        _ change: ResumeCheck.CoverageChange?,
        if fits: KeyPath<ResumeCheck.CoverageChange, Bool>
    ) -> String {
        guard let change, change[keyPath: fits] else { return "" }
        return ": \(change)"
    }

    /// "5 build errors": how many mutants are tested again for `reason`.
    private static func retested(_ count: Int, because reason: ResumePlan.Reason) -> String {
        let one = count == 1
        switch reason {
        case .notRecorded:
            return "\(count) never tested"
        case .buildError:
            return "\(count) build error\(one ? "" : "s")"
        case .fileChanged:
            return "\(count) in \(one ? "a changed file" : "changed files")"
        case .mutationChanged:
            return "\(count) changed mutation\(one ? "" : "s")"
        case .repeated:
            return "\(count) repeated in \(one ? "its" : "their") file"
        case .timeoutNotRerun:
            return "\(count) timeout\(one ? "" : "s") not run again at lower load"
        case .timeoutUnderShorterLimit:
            return "\(count) timeout\(one ? "" : "s") under a shorter limit"
        case .timedOut:
            return "\(count) timeout\(one ? "" : "s")"
        case .otherFileChanged:
            return "\(count) as other project files changed"
        case .testsChanged:
            return "\(count) as test files changed"
        }
    }

    /// "a, b and c".
    static func listed(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    func mutantRunsStarted() {
        mutantRunsStartedAt = instant()
    }

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

    func buildingAgainWithoutMutants(count: Int) {
        let mutants = count == 1 ? "1 mutant is, so SwiftMutator is building again without it"
            : "\(count) mutants are, so SwiftMutator is building again without them"
        print("🔁 The build failed where \(mutants).")
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
                workers: mutationTestLog.workers,
                elapsed: { [weak self] in self?.secondsSinceMutantRunsStarted() }
            )
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
            (tally.buildErrors, tally.buildErrors == 1 ? "build error" : "build errors"),
            (tally.timedOutAgain, "timed out again"),
        ]
        let came = counts.compactMap { count, words in count > 0 ? "\(count) \(words)" : nil }
        print("🔁 Ran \(timeouts) again, and \(changed) changed: \(came.joined(separator: ", ")).")
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

    /// "72 s", "41.2 s": `seconds` to a tenth.
    /// "4.2 s": `seconds` to a tenth.
    static func seconds(_ seconds: TimeInterval) -> String {
        String(format: "%g", (seconds * 10).rounded() / 10) + " s"
    }

    /// The seconds since the mutants started, or nil before they have.
    private func secondsSinceMutantRunsStarted() -> TimeInterval? {
        guard let start = mutantRunsStartedAt else { return nil }
        let now = instant()
        guard now >= start else { return 0 }
        return Double(now.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
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

    /// Where the report went, with the score (`MuterTestReport.scoreLine(of:)`), or the report itself, then the
    /// report's `suspectWarning` (`KillingTestSummary.warning(for:)`), if it has one: the run's last word on its score.
    func mutationTestingFinished(
        report: String,
        reportPath: String,
        isExportingReport: Bool,
        didSaveReport: Bool,
        scoreLine: String,
        suspectWarning: String?,
        buildErrorWarning: String? = nil
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

        if let suspectWarning {
            print("⚠️ \(suspectWarning)")
        }
        if let buildErrorWarning {
            print("⚠️ \(buildErrorWarning)")
        }
    }

    /// How many lines of a run of one mutant's log are printed whole. A longer log is printed from its last
    /// `logLinesShownOfALongLog`.
    static let logLinesShownWhole = 400
    static let logLinesShownOfALongLog = 200

    /// What the one mutant `--mutant` tested found, in place of the report: the mutant and its switch ID, what it
    /// changes, its tests' log, its verdict, the mutated project the run leaves, and the command that runs its tests
    /// there with it on; then where a requested report went.
    func oneMutantTested(_ run: OneMutantRun, reportPath: (path: String, saved: Bool)?) {
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
        if let reportPath {
            print(
                reportPath.saved
                    ? "📝 Report generated: \(reportPath.path.bold)"
                    : "⚠️ Could not save the report to \(reportPath.path)"
            )
        }
    }

    /// `log`'s lines, or its last `logLinesShownOfALongLog` after a line saying how many come before them, when it has
    /// more than `logLinesShownWhole`; those are in the log folder's copy if it is `kept`.
    private static func shown(log: String, kept: Bool) -> [String] {
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
    private static func switchingOn(_ run: OneMutantRun) -> [String] {
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

    /// What mutation testing tested before it stopped early, and the warning of suspect tests its report gives, if it
    /// gives one, then where its partial report is, if it has one, where each result is, the command that makes a
    /// report of them all, and the command that continues the run. A resumed session counts the mutants it tested apart
    /// from the results it kept. On standard error: it reaches the terminal even when a `| tee` that the same Ctrl-C
    /// ended has closed standard output. An abort's error follows on standard output.
    func mutationTestingEndedEarly(
        _ earlyEnd: EarlyEnd,
        partialReport: (path: String, saved: Bool)?,
        resultsFile: String?,
        continueCommand: String?
    ) {
        let results = earlyEnd.outcome.mutations.count
        var lines = [Self.stopped(earlyEnd)]
        if let suspectWarning = KillingTestSummary.warning(for: earlyEnd.outcome) {
            lines.append("⚠️ \(suspectWarning)")
        }
        if let partialReport {
            lines.append(
                partialReport.saved
                    ? "📝 Partial report: \(partialReport.path.bold)"
                    : "⚠️ Could not save the partial report to \(partialReport.path)"
            )
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

    /// `text` as one word for a POSIX shell, so that a printed command pastes whatever the path holds: log folders are
    /// named like `Oct 4, 2026 at 1:16 PM`.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The characters a POSIX shell gives no meaning to, in any place in a word that isn't a command's name.
    private static let plainWordCharacters = Set(
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

    /// What the plan holds, that its copy can be fixed by hand, how to test it, and that a later run removes the copy.
    func testPlanFileCreated(_ created: TestPlanCreated) {
        let mutants = created.mutants == 1 ? "1 mutant" : "\(created.mutants) mutants"
        let files = created.files == 1 ? "1 file" : "\(created.files) files"
        let operators = created.operators.map {
            ($0.count == 1 ? "operator " : "operators ") + Self.listed($0)
        } ?? "every operator"
        print("💾 Mutation test plan created: \(created.path) (\(mutants) in \(files), \(operators))")
        print("✏️ You can fix its copy, \(created.mutatedProject), by hand before testing it.")
        print("▶️ Test it: swift-mutator run-without-mutating \(Self.shellWord(created.path))")
        print(
            "⚠️ A later `swift-mutator run` or `mutate-without-running` of this project removes that copy, and any fix "
                + "in it."
        )
    }

    func configurationFileCreated(atPath path: String?) {
        if let path {
            print("💾 Configuration file created at: \(path)")
        }
    }

    func muterMutationTestPlanLoaded() {
        print("⬆️ SwiftMutator mutation test plan loaded")
    }

    func testPlanSourcesUnchecked() {
        print(
            "⚠️ The test plan was made by a SwiftMutator from before plans recorded the project's files, so it isn't "
                + "checked against them. Make it again with `swift-mutator mutate-without-running` to have it checked."
        )
    }

    /// "2 project files the plan doesn't mutate changed since …: Package.resolved (changed), …", up to
    /// `ResumeRefusal.changedFilesNamed` of them by name.
    func testPlanSourcesDiffer(_ changes: [ProjectTree.FileChange]) {
        let one = changes.count == 1
        let them = one ? "it" : "them"
        let was = one ? "it was" : "they were"
        print(
            "⚠️ \(changes.count) project file\(one ? "" : "s") the plan doesn't mutate changed since "
                + "`swift-mutator mutate-without-running` made it: \(Self.named(changes)). The plan's copy holds "
                + "\(them) as \(was), so its mutants are tested with \(them) as \(was). Make the plan again to test "
                + "with \(them) as \(one ? "it is" : "they are") now."
        )
    }

    /// "1 file with the plan's other mutants, which this run doesn't test, changed since …: Sources/Max.swift
    /// (changed). …", up to `ResumeRefusal.changedFilesNamed` of them by name.
    func testPlanUntestedFilesChanged(_ changes: [ProjectTree.FileChange]) {
        let one = changes.count == 1
        print(
            "⚠️ \(changes.count) file\(one ? "" : "s") with the plan's other mutants, which this run doesn't test, "
                + "changed since `swift-mutator mutate-without-running` made it: \(Self.named(changes)). A run that "
                + "tests those mutants refuses the plan, unless --plan-ignoring lets the "
                + "change\(one ? "" : "s") through."
        )
    }

    /// Each change's path and kind, up to `ResumeRefusal.changedFilesNamed` of them, and how many more there are.
    private static func named(_ changes: [ProjectTree.FileChange]) -> String {
        let named = changes.prefix(ResumeRefusal.changedFilesNamed)
        let others = changes.count - named.count
        return named.map { "\($0.path) (\($0.kind.rawValue))" }.joined(separator: ", ")
            + (others > 0 ? ", and \(others) more" : "")
    }

    /// "The plan is tested although 1 file it mutates changed since it was made (--plan-ignoring): …", up to
    /// `ResumeRefusal.changedFilesNamed` of them by name.
    func testPlanChangesWaived(_ paths: [String]) {
        let named = paths.prefix(ResumeRefusal.changedFilesNamed)
        let others = paths.count - named.count
        let files = paths.count == 1 ? "1 file it mutates" : "\(paths.count) files it mutates"
        print(
            "ℹ️ The plan is tested although \(files) changed since it was made (--plan-ignoring): "
                + named.joined(separator: ", ") + (others > 0 ? ", and \(others) more" : "")
                + ". \(paths.count == 1 ? "Its" : "Their") mutants are tested in the copy as it is."
        )
    }

    /// "1 file of the plan's copy differs from what … wrote, and is tested as it is now: …", up to
    /// `ResumeRefusal.changedFilesNamed` of them by name.
    func testPlanCopyEdited(_ paths: [String]) {
        let named = paths.prefix(ResumeRefusal.changedFilesNamed)
        let others = paths.count - named.count
        let one = paths.count == 1
        print(
            "✏️ \(paths.count) file\(one ? "" : "s") of the plan's copy "
                + "\(one ? "differs" : "differ") from what `swift-mutator mutate-without-running` wrote, and "
                + "\(one ? "is" : "are") tested as \(one ? "it is" : "they are") now: "
                + named.joined(separator: ", ") + (others > 0 ? ", and \(others) more" : "")
        )
    }

    /// "1 dependency resolution file of the plan's copy changed since the run's last session: Package.resolved
    /// (added). …", up to `ResumeRefusal.changedFilesNamed` of them by name.
    func testPlanCopyResolutionChanged(_ changes: [ProjectTree.FileChange]) {
        let one = changes.count == 1
        print(
            "⚠️ \(changes.count) dependency resolution file\(one ? "" : "s") of the plan's copy changed since the "
                + "run's last session: \(Self.named(changes)). The project the plan was made from had "
                + "\(one ? "no such file" : "none of them"), so the copy's own build wrote \(one ? "it" : "them"), "
                + "and the results are reused. To test every mutant with the dependencies as they are resolved now, "
                + "start the run again without --resume."
        )
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

    private func printMessage(_ message: String) {
        print("+-----------------+")
        print(message)
    }

    /// Follows a message printed while the progress bar is still to be redrawn with as many empty lines as the bar
    /// takes. The redraw moves the cursor up over those lines rather than over the end of the message. The bar's
    /// `next()` redraws it only while `element <= count`, so the bar's last redraw needs no room after it.
    private func leaveRoomForTheProgressBar() {
        guard let progressBar, progressBar.element <= progressBar.count else {
            return
        }
        for _ in 0 ..< Self.progressBarLines {
            print("")
        }
    }
}
