import Foundation
@testable import muterCore
import SwiftSyntax

class MutationTestingDelegateSpy: Spy, MutationTestingIODelegate {
    private(set) var methodCalls: [String] = []
    private(set) var backedUpFilePaths: [String] = []
    private(set) var mutatedFileContents: [String] = []
    private(set) var mutatedFilePaths: [String] = []
    private(set) var restoredFilePaths: [String] = []

    private(set) var schematas: MutationSchemata = []
    private(set) var testRuns: [XCTestRun] = []
    private(set) var testRunPaths: [URL] = []
    private(set) var testLogs: [String] = []
    private(set) var workingDirectories: [URL] = []
    private(set) var builtWorkerDirectories: [URL] = []
    private(set) var configurations: [MuterConfiguration] = []
    private let lock = NSLock()

    var testSuiteOutcomes: [TestSuiteOutcome]!
    /// The log of the baseline run in the mutated project.
    var baselineTestLog = "testLog"
    /// Each mutant run's log, in the order they're run; "testLog" once empty.
    var mutantTestLogs: [String] = []
    /// How each mutant's run ends, in the order they're run; `.exited` once empty.
    var mutantRunEndings: [TestRun.Ending] = []
    /// Called with each mutant run's zero-based number just before it returns, so a test can cancel
    /// mutation testing while a run is under way.
    var whileRunningMutant: ((Int) -> Void)?
    /// Called with a worker's number just before its baseline run returns: 0 in the mutated project, and n for the
    /// n-th worker clone's build to start. A test can cancel mutation testing while one is under way.
    var whileRunningBaseline: ((Int) -> Void)?
    private var mutantRunCount = 0

    func backupFile(at path: String, using swapFilePaths: [FilePath: FilePath]) {
        methodCalls.append(#function)
        backedUpFilePaths.append(path)
    }

    func writeFile(to path: String, contents: String) throws {
        methodCalls.append(#function)
        mutatedFilePaths.append(path)
        mutatedFileContents.append(contents)
    }

    func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) -> TestRun {
        methodCalls.append(#function)
        testLogs.append(fileName)
        configurations.append(configuration)
        let (run, number) = nextMutantRun()
        whileRunningMutant?(number)
        return run
    }

    /// Called concurrently by parallel workers, so it takes the lock.
    func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> TestRun {
        await Task.yield()
        let (run, number) = lock.withLock {
            methodCalls.append(#function)
            testLogs.append(fileName)
            workingDirectories.append(workingDirectory)
            configurations.append(configuration)
            return nextMutantRun()
        }
        whileRunningMutant?(number)
        return run
    }

    /// The next mutant run, and its zero-based number.
    private func nextMutantRun() -> (run: TestRun, number: Int) {
        defer { mutantRunCount += 1 }
        let testLog = mutantTestLogs.isEmpty ? "testLog" : mutantTestLogs.removeFirst()
        let ending = mutantRunEndings.isEmpty ? .exited : mutantRunEndings.removeFirst()
        return (TestRun(outcome: testSuiteOutcomes.remove(at: 0), testLog: testLog, ending: ending), mutantRunCount)
    }

    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) -> (
        outcome: TestSuiteOutcome,
        testLog: String
    ) {
        methodCalls.append(#function)
        testLogs.append(fileName)
        whileRunningBaseline?(0)
        return (testSuiteOutcomes.remove(at: 0), baselineTestLog)
    }

    /// Called concurrently for each worker clone, so it takes the lock.
    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    ) {
        await Task.yield()
        let (outcome, worker) = lock.withLock {
            methodCalls.append(#function)
            testLogs.append(fileName)
            builtWorkerDirectories.append(workingDirectory)
            return (testSuiteOutcomes.remove(at: 0), builtWorkerDirectories.count)
        }
        whileRunningBaseline?(worker)
        return (outcome, "testLog")
    }

    func switchOn(schemata: MutationSchema, for testRun: XCTestRun, at path: URL) throws {
        methodCalls.append(#function)
        schematas.append(schemata)
        testRuns.append(testRun)
        testRunPaths.append(path)
    }

    func restoreFile(at path: String, using swapFilePaths: [FilePath: FilePath]) {
        methodCalls.append(#function)
        restoredFilePaths.append(path)
    }
}
