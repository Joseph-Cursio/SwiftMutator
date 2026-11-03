import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

final class LockMutatedProjectTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = LockMutatedProject()

    override func setUpWithError() throws {
        try super.setUpWithError()
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/code/x_mutated")
    }

    func test_locksTheMutatedProject_andKeepsTheLockInTheState() async throws {
        let changes = try await sut.run(with: state)

        XCTAssertEqual(mutatedProjectLocker.mutatedProjects, [URL(fileURLWithPath: "/code/x_mutated")])
        XCTAssertEqual(changes, [.mutatedProjectLocked(try XCTUnwrap(mutatedProjectLocker.locks.first))])
    }

    func test_aRunThatAnotherHoldsTheLockFor_isRefused() async {
        let inUse = MutatedProjectLockError.inUse(mutatedProject: "/code/x_mutated", process: 81234)
        mutatedProjectLocker.errorToThrow = inUse

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(error as? MutatedProjectLockError, inUse)
        }
    }

    // The lock file beside a copy whose folder isn't there can't be made, as for a test plan moved from another
    // machine, or whose copy is on a volume that isn't mounted. No run can be making the copy there.
    func test_aTestPlanWhoseCopysFolderIsntThere_isRefusedAsItsCopyIsMissing() async {
        for code in [ENOENT, ENOTDIR] {
            mutatedProjectLocker.errorToThrow = MutatedProjectLockError.cannotLock(
                path: "/code/x_mutated.lock",
                errno: code
            )
            state.testPlan = Self.loadedPlan

            await AssertThrowsError(try await sut.run(with: state)) { error in
                XCTAssertEqual(
                    error as? TestPlanRefused,
                    TestPlanRefused(path: "/code/x/muter-mappings.json", reason: .copyMissing(path: "/code/x_mutated"))
                )
                XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .testPlanRefused)
            }
        }
    }

    // A run that makes its own copy, and a lock file that can't be made for another reason, still stop on the error.
    func test_aLockThatCantBeMade_otherwise_isAnError() async {
        let cases: [(MutatedProjectLockError, LoadedTestPlan?)] = [
            (.cannotLock(path: "/code/x_mutated.lock", errno: ENOENT), nil),
            (.cannotLock(path: "/code/x_mutated.lock", errno: EACCES), Self.loadedPlan),
        ]
        for (lockError, plan) in cases {
            mutatedProjectLocker.errorToThrow = lockError
            state.testPlan = plan

            await AssertThrowsError(try await sut.run(with: state)) { error in
                XCTAssertEqual(error as? MutatedProjectLockError, lockError)
            }
        }
    }

    private static let loadedPlan = LoadedTestPlan(
        path: "/code/x/muter-mappings.json",
        sha256: "",
        formatVersion: 0,
        swiftMutatorVersion: nil,
        scope: nil,
        sources: nil,
        mutatedFiles: nil,
        linkedFiles: nil,
        mutatedPaths: []
    )
}
