import Foundation

/// Locks the mutated project before anything in it or beside it is read, removed, copied or tested, and keeps the lock
/// in the state until the run's work has ended. A run that another run of the project already holds it for is refused
/// here, with everything left as it was. See `MutatedProjectLock`. A test plan whose copy is in a folder that isn't
/// there, so that the lock file beside the copy can't be made, is refused as its copy is missing: no other run can be
/// making the copy there either.
struct LockMutatedProject: MutationStep {
    @Dependency(\.mutatedProjectLocker)
    private var locker: MutatedProjectLocking

    func run(with state: AnyMutationTestState) throws -> [MutationTestState.Change] {
        do {
            return [.mutatedProjectLocked(try locker.lock(state.mutatedProjectDirectoryURL))]
        } catch let error as MutatedProjectLockError {
            guard let plan = state.testPlan,
                  case let .cannotLock(_, code) = error,
                  code == ENOENT || code == ENOTDIR
            else { throw error }
            throw TestPlanRefused(path: plan.path, reason: .copyMissing(path: state.mutatedProjectDirectoryURL.path))
        }
    }
}
