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
        // executable is its second argument. A bundle that waits gives a stopped run time to stop before it ends. One
        // named for `UserDefaults` says what its domain, its process's name, holds, then writes to it.
        helper = directory.appendingPathComponent("swiftpm-testing-helper")
        try """
        #!/bin/sh
        printf 'ran:'; printf ' %s' "$@"; printf '\\n'
        printf 'colour=%s\\n' "$NO_COLOR"
        printf 'as=%s\\n' "$(basename "$0")"
        case "$2" in
          *UserDefaults)
            printf 'held=%s\\n' "$(defaults read "$(basename "$0")" sharedKey 2>/dev/null)"
            defaults write "$(basename "$0")" sharedKey "written by $(basename "$0")" ;;
          *Crashes) kill -USR1 $$ ;;
          *Interrupted) kill -INT $$ ;;
          *Fails) echo "✘ Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue."; exit 1 ;;
          *FailsThenWaits) echo "✘ Test sample() recorded an issue at SampleTests.swift:3:5: x"; sleep 10; exit 1 ;;
          *Waits) sleep 10 ;;
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

    // A process with no bundle identifier keeps its `UserDefaults` in a domain named after its executable's file, so
    // the link gives each worker's tests their own (#92).
    func test_aMutantsRun_startsTheHelperThroughTheWorkersOwnLink() async throws {
        let run = try await runAMutant(bundles: ["CoreTests"])

        XCTAssertTrue(run.testLog.contains("as=it's a project.swiftpm-testing-helper\n"), run.testLog)
        let link = DirectTestRun.helperLink(forWorkerIn: worker)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), helper.path)
    }

    // A mutant whose tests write a fixed key could otherwise fail the runs after it in that folder, and another
    // worker's.
    func test_eachRunStartsWithEmptyDefaults_thatNoOtherWorkerShares() async throws {
        let otherWorker = directory.appendingPathComponent("it's a project_worker1")
        try FileManager.default.createDirectory(at: otherWorker, withIntermediateDirectories: true)
        let worker = try XCTUnwrap(worker)
        addTeardownBlock {
            DirectTestRun.removeOwnDefaults(forWorkerIn: worker)
            DirectTestRun.removeOwnDefaults(forWorkerIn: otherWorker)
        }

        let first = try await runAMutant(bundles: ["UserDefaults"])
        let second = try await runAMutant(bundles: ["UserDefaults"])
        let other = try await runAMutant(bundles: ["UserDefaults"], in: otherWorker)

        XCTAssertTrue(first.testLog.contains("held=\n"), first.testLog)
        XCTAssertTrue(second.testLog.contains("held=\n"), second.testLog)
        XCTAssertTrue(other.testLog.contains("held=\n"), other.testLog)
        // What the last run wrote stays until the next run in that folder, or the end of mutation testing.
        let domain = DirectTestRun.defaultsDomain(forWorkerIn: otherWorker)
        XCTAssertEqual(try defaults("read", domain, "sharedKey"), "written by \(domain)\n")
    }

    // Nothing of the folder's is left in the user's preferences, and the helper the link led to stays.
    func test_removeOwnDefaults_removesTheLinkAndTheDomain_butNotTheHelper() async throws {
        _ = try await runAMutant(bundles: ["UserDefaults"])
        let domain = DirectTestRun.defaultsDomain(forWorkerIn: worker)
        XCTAssertEqual(try defaults("read", domain, "sharedKey"), "written by \(domain)\n")

        DirectTestRun.removeOwnDefaults(forWorkerIn: worker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: DirectTestRun.helperLink(forWorkerIn: worker).path))
        XCTAssertEqual(try defaults("read", domain), "")
        let preferences = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: preferences.appendingPathComponent(domain + ".plist").path)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
    }

    // A folder whose helper couldn't be linked ran the helper itself, whose domain other `swift test` runs share.
    func test_removeOwnDefaults_touchesNoDomainWithoutALink() {
        let domain = DirectTestRun.defaultsDomain(forWorkerIn: worker)
        XCTAssertNoThrow(try defaults("write", domain, "sharedKey", "kept"))
        addTeardownBlock { DirectTestRun.removeDefaultsDomain(domain) }

        DirectTestRun.removeOwnDefaults(forWorkerIn: worker)

        XCTAssertEqual(try defaults("read", domain, "sharedKey"), "kept\n")
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

    // Stopped as at a failed test, so the bundles after the crash don't run, and scored as the crash it is.
    func test_aRunStoppingAtItsFirstFailure_stopsAtACrash_asARuntimeError() async throws {
        let started = Date()
        let run = try await runAMutant(bundles: ["Crashes", "Waits"], stoppingAtFirstFailure: true)

        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the bundle after the crash ran to its end")
        XCTAssertEqual(run.ending, .stoppedAtCrash)
        XCTAssertEqual(run.outcome, .runtimeError)
        XCTAssertFalse(run.testLog.contains("passed after"), run.testLog)
        XCTAssertTrue(run.testLog.contains("[SwiftMutator] Stopped this test run at a crash"), run.testLog)
    }

    // The bundle with the mutated file's tests runs first, so it stops the run before the others start.
    func test_aMutantsRun_startsWithTheBundleThatHasItsFilesTests() async throws {
        let run = try await runAMutant(
            bundles: ["AppTests", "FailsThenWaits"],
            testFiles: ["AppTests": ["AppTests"], "FailsThenWaits": ["Helpers", "SampleTests"]],
            stoppingAtFirstFailure: true
        )

        let ran = run.testLog.split(separator: "\n").filter { $0.hasPrefix("ran:") }
        XCTAssertEqual(ran.count, 1, run.testLog)
        XCTAssertTrue(ran.first?.hasSuffix("/FailsThenWaits --testing-library swift-testing") ?? false, run.testLog)
        XCTAssertEqual(run.ending, .stoppedAtFailedTest)
        XCTAssertEqual(run.outcome, .failed)
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

    // MARK: - Bundle order

    func test_bundles_putFirstThoseWithATestFileNamedAfterTheMutatedFile_eachInNameOrder() {
        let direct = makeDirectTestRun(bundles: ["AppTests", "CLITests", "CoreTests", "UITests"], testFiles: [
            "AppTests": ["ContentViewTests"],
            "CLITests": ["CSVFormatterTests", "JSONFormatterTests"],
            "CoreTests": ["CSVFormatterEscapingTests"],
        ])

        XCTAssertEqual(
            direct.bundles(forMutantIn: "/project/Sources/Core/Export/CSVFormatter.swift"),
            ["CLITests", "CoreTests", "AppTests", "UITests"]
        )
        XCTAssertEqual(
            direct.bundles(forMutantIn: "/project/Sources/App/ContentView.swift"),
            ["AppTests", "CLITests", "CoreTests", "UITests"]
        )
        XCTAssertEqual(
            direct.bundles(forMutantIn: "/project/Sources/Core/Unmatched.swift"),
            ["AppTests", "CLITests", "CoreTests", "UITests"]
        )
        XCTAssertEqual(direct.bundles(forMutantIn: nil), ["AppTests", "CLITests", "CoreTests", "UITests"])
    }

    // A run with no mutant on keeps name order, as the check's run did.
    func test_theScript_runsTheBundlesInTheMutantsOrder() {
        let direct = makeDirectTestRun(bundles: ["AppTests", "CoreTests"], testFiles: ["CoreTests": ["SampleTests"]])
        let bundlesRun = { (script: String) in
            script.split(separator: "\n").compactMap { line in
                line.range(of: #"MacOS/[A-Za-z]+'"#, options: .regularExpression).map { line[$0] }
            }
        }

        XCTAssertEqual(
            bundlesRun(direct.script(in: worker, forMutantIn: "/p/Sample.swift")),
            ["MacOS/CoreTests'", "MacOS/AppTests'"]
        )
        XCTAssertEqual(bundlesRun(direct.script(in: worker)), ["MacOS/AppTests'", "MacOS/CoreTests'"])
    }

    func test_isTestFile_takesTheNameThenMoreWordsOrNone_endingTests() {
        XCTAssertTrue(DirectTestRun.isTestFile("CSVFormatterTests", of: "CSVFormatter"))
        XCTAssertTrue(DirectTestRun.isTestFile("CSVFormatterEscapingTests", of: "CSVFormatter"))
        XCTAssertTrue(DirectTestRun.isTestFile("CSVFormatterTest", of: "CSVFormatter"))
        XCTAssertFalse(DirectTestRun.isTestFile("CSVFormatterTests", of: "CSVFormat"))
        XCTAssertFalse(DirectTestRun.isTestFile("CSVFormatter", of: "CSVFormatter"))
        XCTAssertFalse(DirectTestRun.isTestFile("CSVFormatterHelpers", of: "CSVFormatter"))
        XCTAssertFalse(DirectTestRun.isTestFile("JSONFormatterTests", of: "CSVFormatter"))
        XCTAssertFalse(DirectTestRun.isTestFile("Tests", of: ""))
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

    /// What `defaults` printed with `arguments`, run as the tests' helpers would, outside this process: reading the
    /// domains here would leave a copy of them that is written back to disk when the tests end.
    @discardableResult
    private func defaults(_ arguments: String...) throws -> String {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func makeDirectTestRun(bundles: [String], testFiles: [String: [String]] = [:]) -> DirectTestRun {
        DirectTestRun(
            helper: helper.path,
            productsFolder: ".build/out/Products/Debug",
            bundles: bundles,
            testFiles: testFiles,
            platformDeveloperFolder: "/Developer",
            arguments: ["--skip-build", "--filter", "Core"]
        )
    }

    /// Runs the tests of a mutant in `Sample.swift` in the worker's folder, as a worker runs them, with the bundles run
    /// directly. Cancels the run after 30 seconds, which kills its processes, so a run that never ends fails the test
    /// instead of hanging it.
    private func runAMutant(
        bundles: [String],
        testFiles: [String: [String]] = [:],
        stoppingAtFirstFailure: Bool = false,
        in folder: URL? = nil
    ) async throws -> TestRun {
        current.process = { MuterProcessFactory.makeProcess() }
        current.writeFile = World().writeFile
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        // Unless stopped at the first failed test or crash, every bundle runs.
        let configuration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test", "--filter", "Core"],
            testSuiteTimeOut: 60,
            stopAtFirstFailure: stoppingAtFirstFailure
        ).withDirectTestRun(makeDirectTestRun(bundles: bundles, testFiles: testFiles))
        let mutant = try MutationSchema.make(filePath: "/path/Sample.swift", position: .init(line: 1))
        let workingDirectory = try folder ?? XCTUnwrap(worker)
        let run = Task { [sut] in
            await sut.runTestSuite(
                withSchemata: mutant,
                using: configuration,
                savingResultsIntoFileNamed: "\(UUID().uuidString).log",
                workingDirectory: workingDirectory
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
