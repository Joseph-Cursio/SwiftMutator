@testable import muterCore
import XCTest

final class MutationTestObserverTests: MuterTestCase {
    private var options = Run.Options.make()

    private lazy var sut = MutationTestObserver(runOptions: options)

    override func setUp() {
        super.setUp()

        fileManager.currentDirectoryPathToReturn = "/"
    }

    func test_flushesStdoutWhenUsingAnXcodeReporter() {
        options = .make(reportFormat: .xcode)

        sut.handleNewMutationTestOutcomeAvailable(notification: .make())

        XCTAssertTrue(flushStandardOut.flushHandlerWasCalled)
    }

    func test_doesntFlushStdoutWhenUsingAJsonReporter() {
        options = .make(reportFormat: .json)

        sut.handleNewMutationTestOutcomeAvailable(notification: .make())

        XCTAssertFalse(flushStandardOut.flushHandlerWasCalled)
    }

    func test_doesntFlushStdoutWhenUsingAPlainTextReporter() {
        options = .make(reportFormat: .plain)

        sut.handleNewMutationTestOutcomeAvailable(notification: .make())

        XCTAssertFalse(flushStandardOut.flushHandlerWasCalled)
    }

    func test_logFileNameUsingAPlainTextReporter() {
        options = .make(reportFormat: .plain)

        XCTAssertEqual(sut.logFileName(from: nil), "baseline run.log")
    }

    func test_logFileNameUsingAXcodeReporter() {
        options = .make(reportFormat: .xcode)

        let mutationPoint1 = MutationPoint(
            mutationOperatorId: .ror,
            filePath: "~/user/file.swift",
            position: .firstPosition
        )

        let mutationPoint2 = MutationPoint(
            mutationOperatorId: .removeSideEffects,
            filePath: "~/user/file2.swift",
            position: MutationPosition(utf8Offset: 2, line: 5, column: 6)
        )

        XCTAssertEqual(
            sut.logFileName(from: mutationPoint1),
            "RelationalOperatorReplacement @ file.swift-0-0.log"
        )

        XCTAssertEqual(
            sut.logFileName(from: mutationPoint2),
            "RemoveSideEffects @ file2.swift-5-6.log"
        )
    }

    // A failing baseline's log is the only record of why the run stopped: the abort message points the
    // user at the logs folder.
    func test_whenTheBaselineFails_itsLogIsWrittenToTheLoggingDirectory() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        sut.start()
        let loggingDirectory = try XCTUnwrap(fileManager.paths.first)

        notificationCenter.post(
            name: .baselineTestFailed,
            object: MutationTestLog.make(testLog: "error: no such module 'Calc'")
        )

        XCTAssertTrue(loggingDirectory.hasPrefix("/project_muter_logs/"), loggingDirectory)
        XCTAssertEqual(fileManager.paths.last, "\(loggingDirectory)/baseline run.log")
        XCTAssertEqual(fileManager.contents, Data("error: no such module 'Calc'".utf8))
    }

    func test_eachTestLogIsWrittenToTheLoggingDirectory_namedAfterItsMutant() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        sut.start()
        let loggingDirectory = try XCTUnwrap(fileManager.paths.first)
        let mutationPoint = MutationPoint(
            mutationOperatorId: .removeSideEffects,
            filePath: "/project/Sources/file2.swift",
            position: MutationPosition(utf8Offset: 2, line: 5, column: 6)
        )

        notificationCenter.post(
            name: .newTestLogAvailable,
            object: MutationTestLog.make(
                testLog: "Executed 3 tests, with 0 failures",
                timePerBuildTestCycle: 1,
                remainingMutationPointsCount: 1
            )
        )
        notificationCenter.post(
            name: .newTestLogAvailable,
            object: MutationTestLog.make(mutationPoint: mutationPoint, testLog: "Executed 3 tests, with 1 failure")
        )

        XCTAssertEqual(fileManager.paths.suffix(2), [
            "\(loggingDirectory)/baseline run.log",
            "\(loggingDirectory)/RemoveSideEffects @ file2.swift-5-6.log",
        ])
        XCTAssertEqual(fileManager.contents, Data("Executed 3 tests, with 1 failure".utf8))
    }

    func test_stopAtFirstFailureTurnedOff_isPrinted() {
        sut.start()

        notificationCenter.post(name: .stopAtFirstFailureTurnedOff, object: "the reason")

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ stopAtFirstFailure is off for this run, so every mutant's tests run to the end: the reason"
        )
    }
}

private extension Notification {
    static func make() -> Notification {
        Notification(
            name: .newMutationTestOutcomeAvailable,
            object: MutationTestOutcome.Mutation.make(
                testSuiteOutcome: .passed,
                point: .make(
                    mutationOperatorId: .ror,
                    filePath: "some/path",
                    position: .firstPosition
                ),
                snapshot: .null
            ),
            userInfo: nil
        )
    }
}
