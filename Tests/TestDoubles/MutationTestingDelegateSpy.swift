import Foundation
@testable import muterCore
import SwiftSyntax

// A test sets it up before the run. What parallel workers call is behind `lock`.
final class MutationTestingDelegateSpy: Spy, MutationTestingIODelegate, @unchecked Sendable {
    private(set) var methodCalls: [String] = []
    private(set) var backedUpFilePaths: [String] = []
    private(set) var mutatedFileContents: [String] = []
    private(set) var mutatedFilePaths: [String] = []
    private(set) var restoredFilePaths: [String] = []

    private(set) var schematas: MutationSchemata = []
    private(set) var testRuns: [XCTestRun] = []
    private(set) var testRunPaths: [URL] = []
    /// The name of each `.xctestrun` file `switchOn` wrote, in order.
    private(set) var testRunFileNames: [String] = []
    /// What each `.xctestrun` file `switchOn` wrote switches on, by its path: what an xcodebuild run would test.
    private var switchedOnTestRuns: [String: String] = [:]
    /// Each mutant whose parallel xcodebuild run, as it started or as it ended, would have tested its worker's
    /// `.xctestrun` with another mutant switched on, or none.
    private(set) var mutantsNotSwitchedOnForTheirRun: [String] = []
    private(set) var testLogs: [String] = []
    private(set) var workingDirectories: [URL] = []
    private(set) var builtWorkerDirectories: [URL] = []
    private(set) var configurations: [MuterConfiguration] = []
    /// Each working directory a parallel mutant run started in while another run was under way there, which a worker's
    /// active-mutant file can't allow.
    private(set) var directoriesSharedAtOnce: [URL] = []
    private var directoriesInUse: Set<URL> = []
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
    /// How the timed run of the test command without its build ends. Not taken from `testSuiteOutcomes`, which
    /// scripts the baselines and the mutants.
    var timedTestRunOutcome: TestSuiteOutcome = .passed
    /// How each run of the test command without its build ends, and what it prints, in the order they're run; once
    /// empty, `timedTestRunOutcome` and "timed test run log".
    var testRunsWithoutBuilding: [(outcome: TestSuiteOutcome, log: String)] = []
    /// The configuration each run of the test command without its build was given.
    private(set) var configurationsWithoutBuilding: [MuterConfiguration] = []
    /// Called just before the timed run of the test command without its build returns, so a test can move its clock.
    var whileRunningTestsWithoutBuilding: (() -> Void)?
    /// What `switchOn` throws, once a test has set it: as if its `.xctestrun` couldn't be written.
    var switchOnError: Error?
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
        lock.withLock {
            if !directoriesInUse.insert(workingDirectory).inserted {
                directoriesSharedAtOnce.append(workingDirectory)
            }
            checkSwitchedOn(schemata, for: configuration, in: workingDirectory)
        }
        await Task.yield()
        let (run, number) = lock.withLock {
            methodCalls.append(#function)
            testLogs.append(fileName)
            workingDirectories.append(workingDirectory)
            configurations.append(configuration)
            return nextMutantRun()
        }
        whileRunningMutant?(number)
        lock.withLock {
            checkSwitchedOn(schemata, for: configuration, in: workingDirectory)
            _ = directoriesInUse.remove(workingDirectory)
        }
        return run
    }

    /// Notes `schemata`'s mutant if an xcodebuild run with `configuration` in `directory` would test another one.
    /// Called with the lock held.
    private func checkSwitchedOn(
        _ schemata: MutationSchema,
        for configuration: MuterConfiguration,
        in directory: URL
    ) {
        guard configuration.buildSystem == .xcodebuild else { return }
        let fileName = configuration.xcodeWorker?.testRunFile ?? MutationTestingDelegate.muterTestRunFileName
        if switchedOnTestRuns[directory.appendingPathComponent(fileName).path] != schemata.id {
            mutantsNotSwitchedOnForTheirRun.append(schemata.id)
        }
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

    func runTestsWithoutBuilding(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) -> (
        outcome: TestSuiteOutcome,
        testLog: String
    ) {
        methodCalls.append(#function)
        testLogs.append(fileName)
        configurationsWithoutBuilding.append(configuration)
        whileRunningTestsWithoutBuilding?()
        return testRunsWithoutBuilding.isEmpty
            ? (timedTestRunOutcome, "timed test run log")
            : testRunsWithoutBuilding.removeFirst()
    }

    /// Called concurrently by parallel xcodebuild workers, so it takes the lock.
    func switchOn(schemata: MutationSchema, for testRun: XCTestRun, at path: URL, named fileName: String) throws {
        try lock.withLock {
            methodCalls.append(#function)
            schematas.append(schemata)
            testRuns.append(testRun)
            testRunPaths.append(path)
            testRunFileNames.append(fileName)
            if let switchOnError { throw switchOnError }
            switchedOnTestRuns[path.appendingPathComponent(fileName).path] = schemata.id
        }
    }

    func restoreFile(at path: String, using swapFilePaths: [FilePath: FilePath]) {
        methodCalls.append(#function)
        restoredFilePaths.append(path)
    }
}
