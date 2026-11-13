@testable import muterCore
import XCTest

/// The real file manager, but for the current directory, which is `directory`.
private final class FileManagerIn: FileManager, @unchecked Sendable { // `directory` never changes
    private let directory: String

    init(directory: String) {
        self.directory = directory
        super.init()
    }

    override var currentDirectoryPath: String {
        directory
    }
}

final class MutationTestObserverTests: MuterTestCase {
    var options = Run.Options.make()

    lazy var sut = MutationTestObserver(runOptions: options)

    override func setUp() {
        super.setUp()

        fileManager.currentDirectoryPathToReturn = "/"
    }

    // Before it starts, the observer has no folder, so it lists and removes nothing.
    func test_removeLoggingDirectoryIfEmpty_beforeStart_removesNothing() {
        sut.removeLoggingDirectoryIfEmpty()

        XCTAssertTrue(fileManager.methodCalls.isEmpty, "\(fileManager.methodCalls)")
    }

    func test_flushesStdoutWhenUsingAnXcodeReporter() {
        options = .make(reportFormat: .xcode)

        sut.handle(.newMutationTestOutcomeAvailable(.passedMutant))

        XCTAssertTrue(flushStandardOut.flushHandlerWasCalled)
    }

    func test_doesntFlushStdoutWhenUsingAJsonReporter() {
        options = .make(reportFormat: .json)

        sut.handle(.newMutationTestOutcomeAvailable(.passedMutant))

        XCTAssertFalse(flushStandardOut.flushHandlerWasCalled)
    }

    func test_doesntFlushStdoutWhenUsingAPlainTextReporter() {
        options = .make(reportFormat: .plain)

        sut.handle(.newMutationTestOutcomeAvailable(.passedMutant))

        XCTAssertFalse(flushStandardOut.flushHandlerWasCalled)
    }

    // Without --verbose, the Logger says how many Swift files and mutants it found, and lists none.
    func test_discovery_withoutVerbose_listsNothing() throws {
        try sut.start()

        runEvents.send(.sourceFileDiscoveryFinished(["/p/a.swift"]))
        runEvents.send(.mutationsDiscoveryFinished([SchemataMutationMapping]()))

        XCTAssertEqual(printer.linesPassed, [
            "✅ In total, SwiftMutator discovered 1 Swift files",
            "✅ In total, SwiftMutator discovered 0 mutants in 0 files",
        ])
    }

    // --verbose reaches the Logger, which then lists each Swift file it found, and how many mutants each file has.
    func test_discovery_withVerbose_listsEachFile() throws {
        options = .make(verbose: true)
        try sut.start()

        runEvents.send(.sourceFileDiscoveryFinished(["/p/a.swift"]))
        runEvents.send(.mutationsDiscoveryFinished([SchemataMutationMapping]()))

        XCTAssertEqual(printer.linesPassed, [
            "✅ In total, SwiftMutator discovered 1 Swift files\n\n" + "a.swift".bold,
            "✅ In total, SwiftMutator discovered 0 mutants in 0 files\n",
        ])
    }

    func test_whyThePackagesSourceFilesCouldntBeListed_reachesTheLogger() throws {
        try sut.start()

        runEvents.send(.packageSourceFilesUnavailable(reason: "/usr/bin/swift couldn't be started"))

        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(
            printer.linesPassed.first?.hasPrefix(
                        "⚠️ SwiftMutator couldn't tell which files the package's targets compile: "
                            + "/usr/bin/swift couldn't be started.\n"
                    ),
            true,
            "\(printer.linesPassed)"
        )
    }

    func test_whyTheBuildConditionsCouldntBeHad_reachesTheLogger() throws {
        try sut.start()

        runEvents.send(.buildConditionsUnavailable(reason: "xcodebuild reported no build settings"))

        XCTAssertEqual(printer.linesPassed, [
            """
            ℹ️ SwiftMutator couldn't tell which `#if` branches the build compiles: xcodebuild reported no build settings.
            Every branch keeps its mutants, unless coverage shows that the build left it out.
            """,
        ])
    }

    func test_mutantsInInactiveIfs_areCountedApartFromThoseWithNoPlaceForASwitch() throws {
        try sut.start()

        runEvents.send(.mutantsDropped([
            droppedMutant(line: 1, reason: .noPlaceForASwitch),
            droppedMutant(line: 2, reason: .inInactiveIfConfig),
            droppedMutant(line: 3, reason: .inInactiveIfConfig),
        ]))

        XCTAssertEqual(printer.linesPassed, [
            "ℹ️ SwiftMutator left out 1 mutant with nowhere to put a switch, so no report covers it. "
                + "--verbose lists them.",
            "ℹ️ SwiftMutator left out 2 mutants in `#if` branches this build doesn't compile, so no report covers them. "
                + "--verbose lists them.",
        ])
    }

    func test_mutantsInInactiveIfs_withVerbose_areListed() throws {
        options = .make(verbose: true)
        try sut.start()

        runEvents.send(.mutantsDropped([droppedMutant(line: 2, reason: .inInactiveIfConfig)]))

        XCTAssertEqual(printer.linesPassed, [
            "ℹ️ SwiftMutator left out 1 mutant in `#if` branches this build doesn't compile, so no report covers it:",
            "Sources/App.swift:2:3 RelationalOperatorReplacement: in an `#if` branch this build doesn't compile",
        ])
    }

    private func droppedMutant(line: Int, reason: DroppedMutant.Reason) -> DroppedMutant {
        DroppedMutant(
            path: "Sources/App.swift",
            mutationOperatorId: .ror,
            position: MutationPosition(utf8Offset: 0, line: line, column: 3),
            snapshot: .null,
            lines: line...line,
            reason: reason
        )
    }

    // From the moment the run claims its folder, it holds the marker there, so no other run prunes the folder. A run
    // that kept nothing else there removes the folder, marker and all.
    func test_start_holdsTheRunsMarker_andAFolderHoldingOnlyItIsRemoved() throws {
        let project = try makeTemporaryDirectory() + "/project"
        current.fileManager = FileManagerIn(directory: project)
        try sut.start()
        let marker = sut.loggingDirectory + "/" + RunMarker.fileName

        XCTAssertTrue(sut.loggingDirectory.hasPrefix(project + "_muter_logs/"), sut.loggingDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sut.loggingDirectory), [RunMarker.fileName])
        XCTAssertEqual(ResultsFile.probeLock(marker), .inUse, "held by the run")

        sut.removeLoggingDirectoryIfEmpty()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sut.loggingDirectory))
    }

    // A kept log keeps the folder, and the marker in it, whose lock goes only with the run.
    func test_aLogFolderWithAKeptLog_keepsItsMarker() throws {
        let project = try makeTemporaryDirectory() + "/project"
        current.fileManager = FileManagerIn(directory: project)
        try sut.start()
        try Data("log".utf8).write(to: URL(fileURLWithPath: sut.loggingDirectory + "/baseline run.log"))

        sut.removeLoggingDirectoryIfEmpty()

        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: sut.loggingDirectory)),
            [RunMarker.fileName, "baseline run.log"]
        )
        XCTAssertEqual(ResultsFile.probeLock(sut.loggingDirectory + "/" + RunMarker.fileName), .inUse)
    }

    func test_prunedLogFolders_reachTheLogger() throws {
        try sut.start()

        runEvents.send(.logFoldersPruned(LogFolderPruning(
            root: "/p_muter_logs",
            keeping: 2,
            left: [.init(folders: ["Oct 1, 2026 at 8:12 AM"], reason: .inUse)]
        )))

        XCTAssertEqual(printer.linesPassed, [
            """
            🧹 Left the log folders of 1 earlier run in /p_muter_logs, beyond the newest 2 runs (keepLogFolders: 2):
            ⚠️ Left Oct 1, 2026 at 8:12 AM: another SwiftMutator run is using it.
            """,
        ])
    }
}

private extension MutationTestOutcome.Mutation {
    static var passedMutant: Self {
        .make(
            testSuiteOutcome: .passed,
            point: .make(
                mutationOperatorId: .ror,
                filePath: "some/path",
                position: .firstPosition
            ),
            snapshot: .null
        )
    }
}
