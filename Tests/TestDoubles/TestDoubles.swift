import Foundation
@testable import muterCore

/// The spies and stubs a `MuterTestCase` puts in `current` for each test, and the world made of them.
final class TestDoubles {
    let runEvents = RunEvents()
    let fileManager = FileManagerSpy()
    let ioDelegateSpy = MutationTestingDelegateSpy()
    let prepareCode = SourceCodePreparationStub()
    let process = ProcessSpy()
    let flushStandardOut = FlushHandlerSpy()
    let server = ServerSpy()
    let writeFile = WriteFileSpy()
    let printer = PrinterSpy()
    let standardError = PrinterSpy()
    let testingTimeOutExecutor = TestingTimeOutExecutorSpy()
    let resultsFiles = ResultsFilesSpy()
    let mutatedProjectLocker = MutatedProjectLockerSpy()
    let workerSimulators = WorkerSimulatorsSpy()

    // Every field down to the minute is given, so there is always such a date.
    private let fixedNow = DateComponents(
        calendar: .init(identifier: .gregorian),
        year: 2_021,
        month: 1,
        day: 20,
        hour: 2,
        minute: 42
    ).date ?? .distantPast

    /// The world each test runs in: these doubles, and nothing of the Mac the tests run on.
    var world: World {
        World(
            events: runEvents,
            fileManager: fileManager,
            flushStandardOut: { [flushStandardOut] in flushStandardOut.flush() },
            printer: { [printer] in printer.print($0) },
            errorPrinter: { [standardError] in standardError.print($0) },
            // Never whatever the test runner's standard output is. The tests of the lines that replace the bar say so.
            standardOutIsATerminal: true,
            ioDelegate: ioDelegateSpy,
            process: { [process] in process },
            prepareCode: { [prepareCode] in prepareCode.prepare($0) },
            readPreparedCode: { [prepareCode] in prepareCode.prepare($0) },
            writeFile: { [writeFile] in try writeFile.writeFile($0, $1) },
            // Never in the real temporary directory, which would keep a folder for each test's folder.
            makeFolder: { _ in },
            // No report reads a real file: a test that shows a mutant's line gives it.
            readSourceFile: { _ in nil },
            // Never the checkout the tests run in: a test of the SARIF report's paths gives its own.
            projectInWorkTree: { _ in nil },
            server: server,
            now: { [fixedNow] in fixedNow },
            instant: { DispatchTime(uptimeNanoseconds: 1) },
            testingTimeOutExecutor: { [testingTimeOutExecutor] in testingTimeOutExecutor },
            provenance: { _ in .fixture },
            // Never the real build's: a test of direct runs gives its own.
            directTestRun: { _, _ in .failure(.init(reason: nil)) },
            resultsFiles: resultsFiles,
            mutatedProjectLocker: mutatedProjectLocker,
            // Never the Mac's own simulators.
            workerSimulators: workerSimulators,
            // Never git in the checkout the tests run in: a test of --since gives its own.
            selectChanges: { _, _, _ in .failure(.gitFailed(arguments: [], errors: "not stubbed")) },
            // Never the test runner's own.
            commandLineArguments: ["run"],
            // Never a real folder, and nothing to compare, so workers have clones unless a test says otherwise.
            projectFiles: { _ in nil },
            // Never the Mac's own, so a SwiftPM run tests one mutant at a time unless a test says otherwise.
            processorCount: 1
        )
    }
}
