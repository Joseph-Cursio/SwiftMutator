import Foundation
@testable import muterCore

// A test sets it up before the run. What parallel workers call is behind `lock`.
final class MutationTestingDelegateSpy: MutationTestingIODelegate, @unchecked Sendable {
    private(set) var methodCalls: [String] = []

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

    var testSuiteOutcomes: [TestSuiteOutcome] = []
    /// How the run of the mutant with this id ends, before `testSuiteOutcomes`: for a verdict that mustn't depend on
    /// which worker tests the mutant, or when.
    var outcomesByMutant: [String: TestSuiteOutcome] = [:]
    /// The log of the baseline run in the mutated project.
    var baselineTestLog = "testLog"
    /// The logs of the baselines to come, in order, before `baselineTestLog`, which the rest print.
    var baselineTestLogs: [String] = []
    /// How each baseline in the mutated project ends, in order; `.exited` once empty.
    var baselineEndings: [TestRun.Ending] = []
    /// How each worker clone's baseline ends, in the order they're run; `.exited` once empty.
    var workerBaselineEndings: [TestRun.Ending] = []
    /// The log each worker clone's baseline prints, in the order they're run; "testLog" once empty.
    var workerBaselineTestLogs: [String] = []
    /// Each mutant run's log, in the order they're run; "testLog" once empty.
    var mutantTestLogs: [String] = []
    /// How each mutant's run ends, in the order they're run; `.exited` once empty.
    var mutantRunEndings: [TestRun.Ending] = []
    /// What each mutant's run shows of its block, in the order they're run (`TestRun.activated`); that it ran once
    /// empty.
    var mutantActivations: [MutantActivation] = []
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
    /// How the run of the test command without its build that writes to the file of this name ends, and what it
    /// prints, before `testRunsWithoutBuilding`: for runs at once, such as xcodebuild workers' runs with no mutant on.
    var testRunsWithoutBuildingWritingTo: [String: (outcome: TestSuiteOutcome, log: String)] = [:]
    /// How the first run of the test command without its build that writes to the file of this name ends, and what it
    /// prints, before `testRunsWithoutBuildingWritingTo`: for a run that is run again, such as one the simulator failed
    /// to launch.
    var firstTestRunsWithoutBuildingWritingTo: [String: (outcome: TestSuiteOutcome, log: String)] = [:]
    /// The configuration each run of the test command without its build was given.
    private(set) var configurationsWithoutBuilding: [MuterConfiguration] = []
    /// The time limit each run of the test command without its build was given, nil for none.
    private(set) var timeLimitsWithoutBuilding: [TimeInterval?] = []
    /// How the runs of the test command without its build that write to the file of this name end; `.exited` unless
    /// set.
    var endingsWithoutBuildingWritingTo: [String: TestRun.Ending] = [:]
    /// Called just before the timed run of the test command without its build returns, so a test can move its clock.
    var whileRunningTestsWithoutBuilding: (() -> Void)?
    /// How each control run ends, and what it prints, in the order they're run; once empty, passed with
    /// "control run log". Not taken from `testSuiteOutcomes`, which scripts the baselines and the mutants.
    var controlRuns: [(outcome: TestSuiteOutcome, log: String)] = []
    /// The configuration and the working directory of each control run, in order.
    private(set) var controlRunConfigurations: [MuterConfiguration] = []
    private(set) var controlRunDirectories: [URL?] = []
    /// What each control run's xcodebuild worker's `.xctestrun` switched on as it started, "" for none.
    private(set) var switchedOnForControlRuns: [String] = []
    /// What `switchOn` throws, once a test has set it, for the schemata `switchOnFails` picks: as if its `.xctestrun`
    /// couldn't be written.
    var switchOnError: Error?
    var switchOnFails: (MutationSchema) -> Bool = { _ in true }
    /// Each run's output `keepOutput` was asked to move, and where to, nil to remove it, in order.
    private(set) var keptOutputs: [(output: String, path: String?)] = []
    private var mutantRunCount = 0

    func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) -> TestRun {
        methodCalls.append(#function)
        testLogs.append(fileName)
        configurations.append(configuration)
        let (run, number) = nextMutantRun(of: schemata)
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
            return nextMutantRun(of: schemata)
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

    /// The next run, of `schemata`'s mutant, and its zero-based number.
    private func nextMutantRun(of schemata: MutationSchema) -> (run: TestRun, number: Int) {
        defer { mutantRunCount += 1 }
        let testLog = mutantTestLogs.isEmpty ? "testLog" : mutantTestLogs.removeFirst()
        let ending = mutantRunEndings.isEmpty ? .exited : mutantRunEndings.removeFirst()
        let outcome = outcomesByMutant[schemata.id] ?? testSuiteOutcomes.remove(at: 0)
        let activated = mutantActivations.isEmpty ? .ran : mutantActivations.removeFirst()
        return (TestRun(outcome: outcome, testLog: testLog, ending: ending, activated: activated), mutantRunCount)
    }

    func benchmarkTests(
        using _: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) -> TestRun {
        methodCalls.append(#function)
        testLogs.append(fileName)
        whileRunningBaseline?(0)
        let testLog = baselineTestLogs.isEmpty ? baselineTestLog : baselineTestLogs.removeFirst()
        let ending = baselineEndings.isEmpty ? .exited : baselineEndings.removeFirst()
        return TestRun(outcome: testSuiteOutcomes.remove(at: 0), testLog: testLog, ending: ending)
    }

    /// Called concurrently for each worker clone, so it takes the lock.
    func benchmarkTests(
        using _: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> TestRun {
        await Task.yield()
        let (run, worker) = lock.withLock {
            methodCalls.append(#function)
            testLogs.append(fileName)
            builtWorkerDirectories.append(workingDirectory)
            let run = TestRun(
                outcome: testSuiteOutcomes.remove(at: 0),
                testLog: workerBaselineTestLogs.isEmpty ? "testLog" : workerBaselineTestLogs.removeFirst(),
                ending: workerBaselineEndings.isEmpty ? .exited : workerBaselineEndings.removeFirst()
            )
            return (run, builtWorkerDirectories.count)
        }
        whileRunningBaseline?(worker)
        return run
    }

    /// Called concurrently by xcodebuild workers' runs with no mutant on, so it takes the lock.
    /// Called concurrently by parallel workers, so it takes the lock.
    func runControlTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL?
    ) async -> TestRun {
        await Task.yield()
        let run = lock.withLock {
            methodCalls.append(#function)
            testLogs.append(fileName)
            controlRunConfigurations.append(configuration)
            controlRunDirectories.append(workingDirectory)
            if let worker = configuration.xcodeWorker, let directory = workingDirectory {
                let path = directory.appendingPathComponent(worker.testRunFile).path
                switchedOnForControlRuns.append(switchedOnTestRuns[path] ?? "")
            }
            return controlRuns.isEmpty
                ? (outcome: TestSuiteOutcome.passed, log: "control run log") : controlRuns.removeFirst()
        }
        return TestRun(
            outcome: run.outcome,
            testLog: run.log,
            ending: .exited,
            exitStatus: run.outcome == .passed ? 0 : 1
        )
    }

    func runTestsWithoutBuilding(
        using configuration: MuterConfiguration,
        timeLimit: TimeInterval?,
        savingResultsIntoFileNamed fileName: String
    ) -> TestRun {
        lock.withLock {
            methodCalls.append(#function)
            testLogs.append(fileName)
            configurationsWithoutBuilding.append(configuration)
            timeLimitsWithoutBuilding.append(timeLimit)
        }
        whileRunningTestsWithoutBuilding?()
        let (run, ending) = lock.withLock {
            let name = fileName.lastPathComponent
            let run = firstTestRunsWithoutBuildingWritingTo.removeValue(forKey: name)
                ?? testRunsWithoutBuildingWritingTo[name]
                ?? (testRunsWithoutBuilding.isEmpty
                    ? (timedTestRunOutcome, "timed test run log")
                    : testRunsWithoutBuilding.removeFirst())
            return (run, endingsWithoutBuildingWritingTo[name] ?? .exited)
        }
        return TestRun(outcome: run.outcome, testLog: run.log, ending: ending)
    }

    /// Called concurrently by parallel xcodebuild workers, so it takes the lock.
    func switchOn(schemata: MutationSchema, for testRun: XCTestRun, at path: URL, named fileName: String) throws {
        try lock.withLock {
            methodCalls.append(#function)
            schematas.append(schemata)
            testRuns.append(testRun)
            testRunPaths.append(path)
            testRunFileNames.append(fileName)
            if let switchOnError, switchOnFails(schemata) { throw switchOnError }
            switchedOnTestRuns[path.appendingPathComponent(fileName).path] = schemata.id
        }
    }

    /// Moves nothing, as if the run had left no file, so a kept log is written from its text, as `createFile` shows.
    /// Called concurrently by parallel workers' recording, so it takes the lock.
    func keepOutput(at output: String, as path: String?) -> Bool {
        lock.withLock { keptOutputs.append((output, path)) }
        return false
    }
}
