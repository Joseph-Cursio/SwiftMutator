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
}
