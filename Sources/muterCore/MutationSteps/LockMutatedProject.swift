import Foundation

/// Locks the mutated project before anything in it or beside it is read, removed, copied or tested, and keeps the lock
/// in the state until the run's work has ended. A run that another run of the project already holds it for is refused
/// here, with everything left as it was. See `MutatedProjectLock`.
struct LockMutatedProject: MutationStep {
    @Dependency(\.mutatedProjectLocker)
    private var locker: MutatedProjectLocking

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        [.mutatedProjectLocked(try locker.lock(state.mutatedProjectDirectoryURL))]
    }
}
