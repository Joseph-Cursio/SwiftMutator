@testable import muterCore
import XCTest

enum RemoveTempDirectorySpecError: String, Error {
    case stub
}

final class PreviousRunCleanUpTests: MuterTestCase {
    private var state = MutationTestState()
    private lazy var sut = PreviousRunCleanUp()

    func test_removeTempDirectorySucceeds() async throws {
        fileManager.fileExistsToReturn = [true]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/projectName_mutated")

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [])
        XCTAssertEqual(fileManager.paths, ["/some/projectName_mutated"])
        XCTAssertEqual(
            fileManager.methodCalls,
            ["fileExists(atPath:)", "removeItem(atPath:)", "contentsOfDirectory(atPath:)"]
        )
    }

    func test_failsToRemoveTempDirectory() async throws {
        fileManager.errorToThrow = RemoveTempDirectorySpecError.stub
        fileManager.fileExistsToReturn = [true]

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/projectName_mutated")

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .removeProjectFromPreviousRunFailed(reason) = error else {
                XCTFail("Expected removeProjectFromPreviousRunFailed, got \(error)")
                return
            }

            XCTAssertFalse(reason.isEmpty)
        }
    }

    func test_skipStep() async throws {
        fileManager.errorToThrow = RemoveTempDirectorySpecError.stub
        fileManager.fileExistsToReturn = [false]

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/projectName_mutated")

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [])
    }

    func test_removesWorkerClonesAnEarlierRunLeft_andNothingElse() async throws {
        fileManager.fileExistsToReturn = [true]
        fileManager.contentsOfDirectoryToReturn = [
            "x",
            "x_mutated",
            "x_mutated_worker7",
            "x_mutated_worker1",
            "x_mutated_workerfoo",
            "x_mutated_worker",
            "x_mutated_worker2.txt",
            "y_mutated_worker1",
        ]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/x_mutated")

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [])
        XCTAssertEqual(fileManager.contentsOfDirectoryAtPath, ["/some"])
        XCTAssertEqual(
            fileManager.paths,
            ["/some/x_mutated", "/some/x_mutated_worker1", "/some/x_mutated_worker7"]
        )
    }

    func test_removesLeftoverWorkerClones_whenTheMutatedProjectIsGone() async throws {
        fileManager.fileExistsToReturn = [false]
        fileManager.contentsOfDirectoryToReturn = ["x_mutated_worker1", "x_mutated_worker2"]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/x_mutated")

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [])
        XCTAssertEqual(fileManager.paths, ["/some/x_mutated_worker1", "/some/x_mutated_worker2"])
    }

    func test_aLeftoverCloneThatCannotBeRemoved_failsTheStep() async throws {
        fileManager.errorToThrow = RemoveTempDirectorySpecError.stub
        fileManager.fileExistsToReturn = [false]
        fileManager.contentsOfDirectoryToReturn = ["x_mutated_worker1"]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/x_mutated")

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .removeProjectFromPreviousRunFailed(reason) = error else {
                XCTFail("Expected removeProjectFromPreviousRunFailed, got \(error)")
                return
            }

            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertEqual(fileManager.paths, ["/some/x_mutated_worker1"])
    }
}
