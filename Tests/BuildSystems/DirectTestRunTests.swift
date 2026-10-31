@testable import muterCore
import XCTest

final class DirectTestRunTests: MuterTestCase {
    private let sut = MutationTestingDelegate()
    private var directory: URL!
    /// A worker's folder whose path a shell would split, or end a quoted word at.
    private var worker: URL!
    private var helper: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = try URL(fileURLWithPath: makeTemporaryDirectory())
        fileManager.currentDirectoryPathToReturn = directory.path
        worker = directory.appendingPathComponent("it's a project")
        try FileManager.default.createDirectory(at: worker, withIntermediateDirectories: true)
        // Stands for swiftpm-testing-helper: says what it was given, then runs its bundle's "tests". The bundle's
        // executable is its second argument.
        helper = directory.appendingPathComponent("swiftpm-testing-helper")
        try """
        #!/bin/sh
        printf 'ran:'; printf ' %s' "$@"; printf '\\n'
        printf 'colour=%s\\n' "$NO_COLOR"
        case "$2" in
          *Crashes) kill -USR1 $$ ;;
          *Interrupted) kill -INT $$ ;;
          *Fails) echo "✘ Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue."; exit 1 ;;
        esac
        echo "✔ Test run with 2 tests in 1 suite passed after 0.1 seconds."
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    }

    // MARK: - Runs

    func test_aMutantsRun_startsEachBundleWithTheHelper_inItsWorkersBuild() async throws {
        let run = try await runAMutant(bundles: ["AppTests", "CoreTests"])

        let products = worker.appendingPathComponent(".build/out/Products/Debug").path
        let ran = run.testLog.split(separator: "\n").map(String.init).filter { $0.hasPrefix("ran:") }
        XCTAssertEqual(ran, ["AppTests", "CoreTests"].map { bundle in
            let executable = "\(products)/\(bundle).xctest/Contents/MacOS/\(bundle)"
            return "ran: --test-bundle-path \(executable) --skip-build --filter Core \(executable) "
                + "--testing-library swift-testing"
        })
        XCTAssertTrue(run.testLog.contains("colour=1\n"), run.testLog)
        XCTAssertEqual(run.outcome, .passed)
    }

    // Under `swift test` the other bundles still run, and its line for the crash is what scoring reads.
    func test_aHelperKilledBySignal_isReportedAsSwiftTestReportsIt_andTheOtherBundlesRun() async throws {
        let run = try await runAMutant(bundles: ["Crashes", "CoreTests"])

        XCTAssertTrue(
            run.testLog.contains("Crashes.xctest' exited with unexpected signal code \(SIGUSR1)\n"),
            run.testLog
        )
        XCTAssertTrue(run.testLog.contains("CoreTests --testing-library"), run.testLog)
        XCTAssertEqual(run.outcome, .runtimeError)
    }

    // A Ctrl-C or a CI cancellation reaches the helper first, and SwiftMutator just after: its run isn't a crash.
    func test_aHelperEndedByAStoppingSignal_endsTheRunWithItsStatus() async throws {
        let run = try await runAMutant(bundles: ["Interrupted", "CoreTests"])

        XCTAssertEqual(run.exitStatus, 128 + SIGINT)
        XCTAssertFalse(run.testLog.contains("CoreTests --testing-library"), run.testLog)
        XCTAssertFalse(run.testLog.contains("signal code"), run.testLog)
    }

    func test_aBundleWithAFailedTest_killsTheMutant_whicheverBundleComesLast() async throws {
        let run = try await runAMutant(bundles: ["Fails", "CoreTests"])

        XCTAssertEqual(run.exitStatus, 1)
        XCTAssertEqual(run.outcome, .failed)
    }

    // The baseline builds, so it is always `swift test` itself.
    func test_aBaseline_runsTheTestCommand() async throws {
        current.process = { MuterProcessFactory.makeProcess() }
        let configuration = MuterConfiguration(
            executable: "/bin/sh", arguments: ["-c", "echo the test command"], buildSystem: .swift
        ).withDirectTestRun(makeDirectTestRun(bundles: ["CoreTests"]))

        let baseline = await sut.benchmarkTests(
            using: configuration,
            savingResultsIntoFileNamed: "baseline.log",
            workingDirectory: worker
        )

        XCTAssertEqual(baseline.testLog, "the test command\n")
    }

    // A `#!/bin/sh` helper, like the stand-in, would lose them as it starts; the real one keeps them.
    func test_theScript_setsTheVariablesSwiftTestSets_inTheWorkersBuild() {
        let script = makeDirectTestRun(bundles: ["CoreTests"]).script(in: worker)

        let products = Logger.shellQuoted(worker.appendingPathComponent(".build/out/Products/Debug").path)
        XCTAssertEqual(script.split(separator: "\n").prefix(3).map(String.init), [
            "export DYLD_FRAMEWORK_PATH='/Developer/Library/Frameworks:/Developer/Library/PrivateFrameworks'",
            "export DYLD_LIBRARY_PATH=\(products.dropLast()):/Developer/usr/lib'",
            "export NO_COLOR='1'",
        ])
    }

    // MARK: - Checks

    func test_whyNot_acceptsARunOfTheBaselinesTestsInEachBundle_inAnyOrder() {
        let baseline = """
            Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
            ✔ Test run with 4294 tests in 500 suites passed after 11.641 seconds.
            ✔ Test run with 1 test in 1 suite passed after 0.040 seconds.
            """
        let direct = """
            ✔ Test run with 1 test in 1 suite passed after 0.040 seconds.
            ✔ Test run with 4294 tests in 500 suites passed after 11.889 seconds.
            """

        XCTAssertNil(DirectTestRun.whyNot(baselineLog: baseline, outcome: .passed, log: direct))
        XCTAssertNotNil(DirectTestRun.whyNot(baselineLog: baseline, outcome: .failed, log: direct))
        XCTAssertEqual(
            DirectTestRun.whyNot(baselineLog: baseline, outcome: .passed, log: "✔ Test run with 4295 tests "),
            "running the test bundles directly ran 4295 Swift Testing tests, where `swift test` ran 1, 4294"
        )
        XCTAssertEqual(
            DirectTestRun.whyNot(baselineLog: "Executed 0 tests, with 0 failures", outcome: .passed, log: ""),
            "the baseline ran no Swift Testing test"
        )
    }

    func test_ranXCTestTests_countsOnlyARunOfSome() {
        XCTAssertFalse(DirectTestRun.ranXCTestTests(in: "Executed 0 tests, with 0 failures (0 unexpected)"))
        XCTAssertTrue(DirectTestRun.ranXCTestTests(in: "Executed 1 test, with 1 failure (0 unexpected)"))
        XCTAssertFalse(DirectTestRun.ranXCTestTests(in: "✔ Test run with 12 tests in 3 suites passed"))
    }

    // MARK: - Helpers

    private func makeDirectTestRun(bundles: [String]) -> DirectTestRun {
        DirectTestRun(
            helper: helper.path,
            productsFolder: ".build/out/Products/Debug",
            bundles: bundles,
            platformDeveloperFolder: "/Developer",
            arguments: ["--skip-build", "--filter", "Core"]
        )
    }

    /// Runs a mutant's tests in the worker's folder, as a worker runs them, with the bundles run directly. Cancels the
    /// run after 30 seconds, which kills its processes, so a run that never ends fails the test instead of hanging it.
    private func runAMutant(bundles: [String]) async throws -> TestRun {
        current.process = { MuterProcessFactory.makeProcess() }
        current.writeFile = World().writeFile
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        // Not stopped at the first failed test, so every bundle runs.
        let configuration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test", "--filter", "Core"],
            testSuiteTimeOut: 60,
            stopAtFirstFailure: false
        ).withDirectTestRun(makeDirectTestRun(bundles: bundles))
        let mutant = try MutationSchema.make(filePath: "/path/Sample.swift", position: .init(line: 1))
        let run = Task { [sut, worker] in
            await sut.runTestSuite(
                withSchemata: mutant,
                using: configuration,
                savingResultsIntoFileNamed: "\(UUID().uuidString).log",
                workingDirectory: worker!
            )
        }
        let deadline = Task {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            run.cancel()
        }
        defer { deadline.cancel() }
        return await run.value
    }
}
