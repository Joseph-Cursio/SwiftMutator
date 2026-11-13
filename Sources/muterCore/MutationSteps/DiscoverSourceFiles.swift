import Foundation

/// A `--files-to-mutate` entry that leaves no file to mutate, and why.
struct UnmatchedFilesToMutate: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// No Swift file is there.
        case noSwiftFile
        /// Each Swift file it names is outside the project.
        case outsideTheProject
        /// The excludes leave out each Swift file it names, and an entry that starts with `!` could keep one.
        case excluded
        /// Each Swift file it names is a manifest, or in a build folder, which no entry can keep.
        case neverMutated
        /// The coverage filter leaves out each one the excludes leave in.
        case withoutCoverage
    }

    let entry: String
    let reason: Reason
}

struct DiscoverSourceFiles: MutationStep {
    /// The Swift files `--files-to-mutate` names that discovery keeps, those of them coverage leaves out, and the
    /// entries that leave none.
    struct NamedFiles {
        let files: [FilePath]
        let uncovered: [FilePath]
        let unmatched: [UnmatchedFilesToMutate]
    }

    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.fileManager)
    var fileManager: FileSystemManager
    @Dependency(\.process)
    var process: ProcessFactory
    @Dependency(\.listProjectFiles)
    var listProjectFiles: ProjectFileListing

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        events.send(.sourceFileDiscoveryStarted)

        var listed = state.candidatePaths
        if listed == nil, state.filesToMutate.isEmpty {
            listed = try await candidatePaths(in: state)
        }
        let sourceFileCandidates: [FilePath]
        let uncovered: [FilePath]
        if state.filesToMutate.isEmpty {
            (sourceFileCandidates, uncovered) = discoverSourceFiles(
                among: (listed ?? []).filter(isChosen(by: state)),
                in: state
            )
        } else {
            let named = filesToMutate(in: state)
            if !named.unmatched.isEmpty {
                events.send(.filesToMutateUnmatched(named.unmatched))
            }
            sourceFileCandidates = named.files
            uncovered = named.uncovered
        }

        let failure: MuterError = state.filesToMutate.isEmpty
            ? .noSourceFilesDiscovered
            : .noSourceFilesOnExclusiveList

        events.send(.sourceFileDiscoveryFinished(sourceFileCandidates))

        // With `--baseline`, the mutants of a file coverage leaves out are compared, so a run with no file to mutate
        // but such a file goes on to find them: a change that adds only a file no test reaches has new survivors.
        // Discovery ends it then, as it does when no mutant is left (`DiscoverMutationPoints`).
        let comparesUncovered = !uncovered.isEmpty && Self.comparesUncoveredMutants(state)
        if let selection = state.changeSelection {
            try check(
                sourceFileCandidates,
                andUncovered: uncovered,
                against: selection,
                comparesUncovered: comparesUncovered,
                in: state
            )
        }
        if !sourceFileCandidates.isEmpty || comparesUncovered {
            return [.sourceFileCandidatesDiscovered(sourceFileCandidates)]
                + (uncovered.isEmpty ? [] : [.uncoveredSourceFilesDiscovered(uncovered)])
        }
        throw failure
    }

    /// Whether a run compares the mutants of code no test ran: with `--baseline`, but for a run of one mutant, which
    /// compares no survivors.
    static func comparesUncoveredMutants(_ state: AnyMutationTestState) -> Bool {
        state.runOptions.baseline != nil && state.runOptions.mutant == nil
    }

    /// Why `--since` leaves nothing to mutate when it leaves no file to: discovery leaves out each changed file that
    /// the excludes don't.
    static func noFileDiscovered(_ selection: ChangeSelection, in state: AnyMutationTestState) -> NothingToMutate {
        let isExcluded = SourceFileExcludes.matcher(state.muterConfiguration.excludeFileList)
        let count = selection.files.filter { !isExcluded($0.path) }.count
        return NothingToMutate(reason: .noFileDiscovered(count: count), selection: selection)
    }

    /// With `--since`, whether a path in the project is one of the files it chose; without, every path is.
    private func isChosen(by state: AnyMutationTestState) -> (FilePath) -> Bool {
        guard let selection = state.changeSelection else { return { _ in true } }
        let chosen = Set(selection.files.map(\.path))
        return { chosen.contains($0.precomposedStringWithCanonicalMapping) }
    }

    /// That `--since` left a file to mutate, or one coverage leaves out whose mutants the run compares
    /// (`comparesUncovered`), and that each is as git compared it, and each file coverage leaves out, whose mutants
    /// are counted as not covered: the copy is made after, and the lines of a file changed in between would be wrong.
    private func check(
        _ candidates: [FilePath],
        andUncovered uncovered: [FilePath],
        against selection: ChangeSelection,
        comparesUncovered: Bool,
        in state: AnyMutationTestState
    ) throws {
        guard !candidates.isEmpty || comparesUncovered else {
            throw Self.noFileDiscovered(selection, in: state)
        }
        for candidate in candidates + uncovered {
            let path = RepoRelativePath.of(candidate, under: state.mutatedProjectDirectoryURL)
                .precomposedStringWithCanonicalMapping
            guard let file = selection.file(at: path) else { continue }
            if let copied = state.projectTree?.files[path], copied != file.sha256 {
                throw ChangeSelectionError.changedDuringTheRun(path: path)
            }
        }
    }

    /// The paths in the mutated project, relative to it, that discovery picks from. For a SwiftPM project, the Swift
    /// files its targets compile, and those of the local packages in it that it depends on, as `swift package describe`
    /// gives them. Otherwise, or if that fails, every path in the project that isn't hidden or ignored.
    func candidatePaths(in state: AnyMutationTestState) async throws -> [FilePath] {
        let rootPath = state.mutatedProjectDirectoryURL.path
        if state.muterConfiguration.buildSystem == .swift {
            switch await packageSourceFiles(inProjectAt: rootPath, testedBy: state.muterConfiguration) {
            case let .success(files):
                return files

            case let .failure(failure):
                // A describe that stopping the run killed reads as failed, and no warning is due.
                try Task.checkCancellation()
                events.send(.packageSourceFilesUnavailable(reason: failure.reason))
            }
        }

        return await pathsNotHiddenOrIgnored(in: rootPath, listedIn: state.projectDirectoryURL)
    }
}
