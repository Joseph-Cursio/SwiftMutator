import Foundation

/// What the Logger says while the run finds its work: the configuration's unknown keys, the changes and log folders
/// it picked, the coverage gathered, the source files found, and the mutants discovered or dropped.
extension Logger {
    /// Each key of the configuration file, `file`, that SwiftMutator doesn't know, one line each, with the known key it
    /// is closest to, if any.
    func configurationKeysUnknown(_ keys: [UnknownConfigurationKey], file: String) {
        for unknown in keys {
            let meant = unknown.closest.map { " Did you mean \($0.bold)?" } ?? ""
            print("⚠️ \(file): \(unknown.key.bold) isn't a configuration key, so it is ignored.\(meant)")
        }
    }

    /// That no configuration file was at `missing`, so the run tests with the command `init` would write there, which
    /// it names; then, as `init` says them, the scheme it guessed and the trust checks it skips.
    func configurationWorkedOut(_ generated: GeneratedConfiguration, missing: String) {
        let configuration = generated.configuration
        let command = ([configuration.testCommandExecutable] + configuration.testCommandArguments)
            .map(Self.shellWord)
            .joined(separator: " ")
        print(
            "⚙️ There is no \(missing), so this run tests with what `swift-mutator init` would write there: "
                + "\(command.bold). `swift-mutator init` writes it to a file you can edit."
        )
        schemeGuessed(generated.scheme)
        trustChecksSkipped(XcodebuildTrustCheck.skipped(by: configuration.testCommandArguments))
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
        guard bytes >= 1_000 else { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        var value = Double(bytes) / 1_000
        var unit = 0
        while value >= 999.95, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        return String(format: "%.1f ", value) + units[unit]
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
        let tests = failed.tests.total == 1 ? "1 test" : "\(failed.tests.total) tests"
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

    /// Why SwiftMutator can't tell which `#if` branches the build compiles, and what discovery does instead.
    func buildConditionsUnavailable(reason: String) {
        print(
            """
            ℹ️ SwiftMutator couldn't tell which `#if` branches the build compiles: \(reason).
            Every branch keeps its mutants, unless coverage shows that the build left it out.
            """
        )
    }

    /// The `--files-to-mutate` entries that leave no file to mutate, and why, one line each.
    func filesToMutateUnmatched(_ entries: [UnmatchedFilesToMutate]) {
        for unmatched in entries {
            let why = switch unmatched.reason {
            case .noSwiftFile:
                "names no Swift file"

            case .outsideTheProject:
                "names only Swift files outside the project"

            case .excluded:
                "names only files the excludes leave out; an \("exclude".bold) entry that starts with ! keeps them"

            case .neverMutated:
                "names only package manifests or files in build folders, which are never mutated"

            case .withoutCoverage:
                "names only files the excludes or the coverage filter leave out: those at or below "
                    + "\("coverageThreshold".bold), which by default are those whose code no test ran"
            }
            print("⚠️ --files-to-mutate \(unmatched.entry) \(why).")
        }
    }

    /// Why the Swift files a SwiftPM package's targets compile couldn't be listed, and what discovery does instead.
    func packageSourceFilesUnavailable(reason: String) {
        // SwiftPM's errors often end in one.
        let sentence = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        print(
            """
            ⚠️ SwiftMutator couldn't tell which files the package's targets compile: \(sentence).
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
            .map(\.lastPathComponent)
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

        let discovered = Self.discovered(
            mutants: numberOfMutationPoints, files: numberOfFiles, sample: sample?.selection, shard: shard
        )
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

    /// "✅ In total, SwiftMutator discovered …": how many `mutants` there are to test and in how many `files`, and
    /// with a `sample` or a `shard`, how many were discovered in all.
    private static func discovered(
        mutants: Int, files: Int, sample: SampleSelection?, shard: ShardSelection?
    ) -> String {
        switch (sample, shard) {
        case (nil, nil):
            "✅ In total, SwiftMutator discovered \(mutants) mutants in \(files) files"

        case let (nil, shard?):
            "✅ In total, SwiftMutator discovered \(shard.mutantsInAllShards) mutants, and shard \(shard.index) of "
                + "\(shard.count) holds \(mutants) of them, in \(files) files"

        case let (sample?, nil) where sample.isPartial:
            "✅ In total, SwiftMutator discovered \(sample.mutantsSampledFrom) mutants, and the sample of "
                + "\(sample.size) holds \(mutants) of them, in \(files) files"

        case let (sample?, nil) where sample.mutantsSampledFrom <= sample.size:
            "✅ In total, SwiftMutator discovered \(mutants) mutants in \(files) files, "
                + "no more than the sample of \(sample.size), which holds them all"

        // The last place it took had repeats enough to hold the rest.
        case let (sample?, nil):
            "✅ In total, SwiftMutator discovered \(mutants) mutants in \(files) files, and "
                + "the sample of \(sample.size) holds them all"

        case let (sample?, shard?):
            "✅ In total, SwiftMutator discovered \(sample.mutantsSampledFrom) mutants, the sample of \(sample.size) "
                + "holds \(sample.mutantsSampled) of them, and shard \(shard.index) of \(shard.count) holds "
                + "\(mutants) of those, in \(files) files"
        }
    }

    /// How many mutants discovery found and can't test, and with `verbose`, each one.
    func mutantsDropped(_ dropped: [DroppedMutant], verbose: Bool = false) {
        let inactive = dropped.filter { $0.reason == .inInactiveIfConfig }
        let noPlace = dropped.filter { $0.reason != .inInactiveIfConfig }
        mutantsDropped(noPlace, why: "with nowhere to put a switch", verbose: verbose)
        mutantsDropped(inactive, why: "in `#if` branches this build doesn't compile", verbose: verbose)
    }

    func mutantsDropped(_ dropped: [DroppedMutant], why: String, verbose: Bool) {
        guard !dropped.isEmpty else { return }
        let count = dropped.count == 1 ? "1 mutant" : "\(dropped.count) mutants"
        print(
            "ℹ️ SwiftMutator left out \(count) \(why), so no report covers "
                + (dropped.count == 1 ? "it" : "them")
                + (verbose ? ":" : ". --verbose lists them.")
        )
        if verbose {
            print(dropped.map(\.line).joined(separator: "\n"))
        }
    }
}
