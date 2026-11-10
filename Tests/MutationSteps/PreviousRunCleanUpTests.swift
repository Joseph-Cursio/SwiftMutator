@testable import muterCore
import XCTest

enum RemoveTempDirectorySpecError: String, Error {
    case stub
}

final class PreviousRunCleanUpTests: MuterTestCase {
    private var state = MutationTestState()
    private lazy var sut = PreviousRunCleanUp()

    func test_removeTempDirectorySucceeds() throws {
        fileManager.fileExistsToReturn = [true]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/projectName_mutated")

        let result = try sut.run(with: state)

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
            sut.run(with: state)
        ) { error in
            guard case let .removeProjectFromPreviousRunFailed(reason) = error else {
                XCTFail("Expected removeProjectFromPreviousRunFailed, got \(error)")
                return
            }

            XCTAssertFalse(reason.isEmpty)
        }
    }

    func test_skipStep() throws {
        fileManager.errorToThrow = RemoveTempDirectorySpecError.stub
        fileManager.fileExistsToReturn = [false]

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/projectName_mutated")

        let result = try sut.run(with: state)

        XCTAssertEqual(result, [])
    }

    func test_removesWorkerClonesAnEarlierRunLeft_andNothingElse() throws {
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

        let result = try sut.run(with: state)

        XCTAssertEqual(result, [])
        XCTAssertEqual(fileManager.contentsOfDirectoryAtPath, ["/some"])
        XCTAssertEqual(
            fileManager.paths,
            ["/some/x_mutated", "/some/x_mutated_worker1", "/some/x_mutated_worker7"]
        )
    }

    func test_removesLeftoverWorkerClones_whenTheMutatedProjectIsGone() throws {
        fileManager.fileExistsToReturn = [false]
        fileManager.contentsOfDirectoryToReturn = ["x_mutated_worker1", "x_mutated_worker2"]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/x_mutated")

        let result = try sut.run(with: state)

        XCTAssertEqual(result, [])
        XCTAssertEqual(fileManager.paths, ["/some/x_mutated_worker1", "/some/x_mutated_worker2"])
    }

    // A run stopped at once leaves the files beside the mutated project and its clones that named their active mutants.
    func test_removesTheActiveMutantFilesAnEarlierRunLeft_andNoOthers() throws {
        fileManager.fileExistsToReturn = [false]
        fileManager.contentsOfDirectoryToReturn = [
            "x.active-mutant",
            "x_mutated.active-mutant",
            "x_mutated.active-mutant.txt",
            "x_mutated_worker2.active-mutant",
            "x_mutated_worker.active-mutant",
            "x_mutated_workerfoo.active-mutant",
            "y_mutated.active-mutant",
            "y_mutated_worker1.active-mutant",
        ]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/x_mutated")

        let result = try sut.run(with: state)

        XCTAssertEqual(result, [])
        XCTAssertEqual(
            fileManager.paths,
            ["/some/x_mutated.active-mutant", "/some/x_mutated_worker2.active-mutant"]
        )
    }

    // The links direct runs start the helper through, so that each folder's tests have their own `UserDefaults`.
    func test_removesTheHelperLinksAnEarlierRunLeft_andNoOthers() throws {
        fileManager.fileExistsToReturn = [false]
        fileManager.contentsOfDirectoryToReturn = [
            "x_mutated.swiftpm-testing-helper",
            "x_mutated_worker3.swiftpm-testing-helper",
            "x_mutated_workerfoo.swiftpm-testing-helper",
            "y_mutated.swiftpm-testing-helper",
            "swiftpm-testing-helper",
        ]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/x_mutated")

        _ = try sut.run(with: state)

        XCTAssertEqual(
            fileManager.paths,
            ["/some/x_mutated.swiftpm-testing-helper", "/some/x_mutated_worker3.swiftpm-testing-helper"]
        )
    }

    // An xcodebuild run keeps each worker's derived data beside the mutated project, named as its clone would be.
    func test_removesTheDerivedDataAnEarlierRunLeft_andNoOther() throws {
        fileManager.fileExistsToReturn = [false]
        fileManager.contentsOfDirectoryToReturn = [
            "x_mutated.DerivedData",
            "x_mutated_worker3.DerivedData",
            "x_mutated_workerX.DerivedData",
            "x_mutated_worker.DerivedData",
            "Other.DerivedData",
            "y_mutated.DerivedData",
            "DerivedData",
        ]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/x_mutated")

        _ = try sut.run(with: state)

        XCTAssertEqual(
            fileManager.paths,
            ["/some/x_mutated.DerivedData", "/some/x_mutated_worker3.DerivedData"]
        )
    }

    // Another run of the project may hold it, and a run that removed it could lock a new file while that one held the
    // old.
    func test_keepsTheMutatedProjectsLockFile() throws {
        fileManager.fileExistsToReturn = [false]
        fileManager.contentsOfDirectoryToReturn = ["x_mutated.lock"]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/x_mutated")

        let result = try sut.run(with: state)

        XCTAssertEqual(result, [])
        XCTAssertEqual(fileManager.paths, [])
    }

    // The first run after an upgrade removes what an older SwiftMutator left under the names it gave them, its copy
    // too, as well as what a run of this one leaves. It holds the lock the older one took, `x_mutated.lock`.
    func test_aCopyEndingInNoindex_removesWhatEitherNamingLeft_andNothingElse() throws {
        fileManager.fileExistsToReturn = [true]
        fileManager.contentsOfDirectoryToReturn = [
            "x",
            "x_mutated",
            "x_mutated.noindex",
            "x_mutated_worker1",
            "x_mutated_worker2.noindex",
            "x_mutated.DerivedData",
            "x_mutated.DerivedData.noindex",
            "x_mutated_worker3.DerivedData",
            "x_mutated_worker3.DerivedData.noindex",
            "x_mutated.active-mutant",
            "x_mutated_worker2.active-mutant",
            "x_mutated_worker1.swiftpm-testing-helper",
            "x_mutated.lock",
            "x_muter_logs",
            "x_mutated_worker.noindex",
            "x_mutated_workerfoo.noindex",
            "x_mutated_worker2.noindex.txt",
            "y_mutated_worker1.noindex",
            "y_mutated.DerivedData.noindex",
            "x_mutated.active-mutant.noindex",
            "x_mutated.noindex.DerivedData",
            "x_mutant",
            "x_mutant.noindex",
        ]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/x_mutated.noindex")

        let result = try sut.run(with: state)

        XCTAssertEqual(result, [])
        XCTAssertEqual(fileManager.paths, [
            "/some/x_mutated.noindex", // once
            "/some/x_mutated",
            "/some/x_mutated.DerivedData",
            "/some/x_mutated.DerivedData.noindex",
            "/some/x_mutated.active-mutant",
            "/some/x_mutated_worker1",
            "/some/x_mutated_worker1.swiftpm-testing-helper",
            "/some/x_mutated_worker2.active-mutant",
            "/some/x_mutated_worker2.noindex",
            "/some/x_mutated_worker3.DerivedData",
            "/some/x_mutated_worker3.DerivedData.noindex",
        ])
    }

    // A run of one mutant removes only what such runs left, never a test plan's copy, which may have been fixed by
    // hand.
    func test_aOneMutantCopy_removesOnlyWhatRunsOfOneMutantLeft() throws {
        fileManager.fileExistsToReturn = [false]
        fileManager.contentsOfDirectoryToReturn = [
            "x_mutant",
            "x_mutant_worker1.noindex",
            "x_mutant.active-mutant",
            "x_mutant.lock",
            "x_mutated",
            "x_mutated.noindex",
            "x_mutated_worker1.noindex",
            "x_mutated.DerivedData.noindex",
            "x_mutated.active-mutant",
        ]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/x_mutant.noindex")

        _ = try sut.run(with: state)

        XCTAssertEqual(
            fileManager.paths,
            ["/some/x_mutant", "/some/x_mutant.active-mutant", "/some/x_mutant_worker1.noindex"]
        )
    }

    func test_aLeftoverCloneThatCannotBeRemoved_failsTheStep() async throws {
        fileManager.errorToThrow = RemoveTempDirectorySpecError.stub
        fileManager.fileExistsToReturn = [false]
        fileManager.contentsOfDirectoryToReturn = ["x_mutated_worker1"]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/some/x_mutated")

        try await assertThrowsMuterError(
            sut.run(with: state)
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
