import Foundation

/// Removes earlier runs' log folders beyond the newest `keepLogFolders:` runs, this one included, and says what it
/// removed and left (see `LogFolderPruning`). Without the key, or without a log folder, it removes nothing. A run of
/// one mutant (`--mutant`) doesn't have the step: it is a short probe, the run most likely to go alongside another.
///
/// After every step that can refuse the run or find nothing to test: its configuration, `--since`, a resume or reuse
/// check, another run of the project, a test plan's checks of its code and copy, and the discovery of files and
/// mutants. A run that ends in one of those ways removes nothing, and never counts as one of the runs kept. Before the
/// build and every mutant's run, which write most of a run's logs.
struct PruneLogFolders: MutationStep {
    /// Prunes `root`, keeping the newest `keeping` runs, this one included: `current` names this run's folders, and
    /// `protected` those of the run a `--reuse` reads. A test passes one that touches no disk.
    typealias Pruning = @Sendable (
        _ root: String,
        _ current: [String],
        _ protected: [String],
        _ keeping: Int
    ) -> LogFolderPruning

    @Dependency(\.events)
    private var events: RunEvents
    private let prune: Pruning

    init(prune: @escaping Pruning = { LogFolderPruning.prune(root: $0, current: $1, protected: $2, keeping: $3) }) {
        self.prune = prune
    }

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        guard let keeping = state.muterConfiguration.keepLogFolders, !state.loggingDirectory.isEmpty else {
            return []
        }
        let root = (state.loggingDirectory as NSString).deletingLastPathComponent
        // A resumed run's earlier sessions are this run, and the run a reuse reads is copied from much later, with no
        // lock held on it.
        let earlier = state.resumeState.map { resume in
            [(resume.path as NSString).deletingLastPathComponent] + resume.recorded.headers.map(\.logDirectory)
        } ?? []
        let isReuse = state.resumeState?.isReuse ?? false
        let pruning = prune(
            root,
            [state.loggingDirectory] + (isReuse ? [] : earlier),
            isReuse ? earlier : [],
            keeping
        )
        if !pruning.isEmpty {
            events.send(.logFoldersPruned(pruning))
        }
        return []
    }
}
