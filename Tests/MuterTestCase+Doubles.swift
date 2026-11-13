@testable import muterCore

/// The test's doubles, by the names the suites use.
extension MuterTestCase {
    var runEvents: RunEvents { doubles.runEvents }
    var fileManager: FileManagerSpy { doubles.fileManager }
    var ioDelegate: MutationTestingDelegateSpy { doubles.ioDelegateSpy }
    var prepareCode: SourceCodePreparationStub { doubles.prepareCode }
    var process: ProcessSpy { doubles.process }
    var flushStandardOut: FlushHandlerSpy { doubles.flushStandardOut }
    var server: ServerSpy { doubles.server }
    var writeFile: WriteFileSpy { doubles.writeFile }
    var printer: PrinterSpy { doubles.printer }
    var standardError: PrinterSpy { doubles.standardError }
    var testingTimeOutExecutor: TestingTimeOutExecutorSpy { doubles.testingTimeOutExecutor }
    var resultsFiles: ResultsFilesSpy { doubles.resultsFiles }
    var mutatedProjectLocker: MutatedProjectLockerSpy { doubles.mutatedProjectLocker }
    var workerSimulators: WorkerSimulatorsSpy { doubles.workerSimulators }
}
