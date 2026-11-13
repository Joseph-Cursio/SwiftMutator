@testable import muterCore
import TestingExtensions
import XCTest

extension SwiftCoverageTests {
    // A build that fails leaves the profiles of an earlier run in place, so with no failed test named, none are merged.
    // Its first error says what went wrong, not a failing test.
    func test_aFailedBuild_givesNoCoverage_andItsFirstError() async {
        answerWithACoverageRun(
            bundles: ["CoreTests.xctest", "XCTest1234_0.501.profraw"],
            testRun: result(
                status: 1,
                errors: """
                Building for debugging...
                [2 / 6] CoreTests-product
                error: SwiftCompile normal arm64 failed with a nonzero exit code. Command line:     cd /project
                /project/Tests/CoreTests/CoreTests.swift:9:19: \u{1B}[1;31merror: \u{1B}[1;39mcannot convert\u{1B}[0;0m
                error: Build failed

                """
            )
        )

        let compileFailure = await sut.run(with: muterConfiguration)
        XCTAssertEqual(
            compileFailure,
            .failure(.runFailed(
                status: 1,
                error: "error: SwiftCompile normal arm64 failed with a nonzero exit code. Command line:     cd /project"
            ))
        )
        XCTAssertEqual(process.commandsRun.count, 1)
        XCTAssertEqual(fileManager.contentsOfDirectoryAtPath, [])

        process.commandResult = { _ in
            self.result(status: 1, errors: "/p/A.swift:1:1: \u{1B}[1;31merror: \u{1B}[0mcannot find 'x' in scope\n")
        }
        let colouredFailure = await sut.run(with: muterConfiguration)
        XCTAssertEqual(
            colouredFailure,
            .failure(.runFailed(status: 1, error: "/p/A.swift:1:1: error: cannot find 'x' in scope"))
        )

        // SwiftPM prints its build errors to standard error, but one in standard output counts too, and comes first.
        let notLoaded = "error: CoreTests.xctest couldn't be loaded"
        for errors in ["Building for debugging...\n", "error: Build failed\n"] {
            process.commandResult = { _ in self.result(status: 1, output: notLoaded + "\n", errors: errors) }
            let notLoadedFailure = await sut.run(with: muterConfiguration)
            XCTAssertEqual(notLoadedFailure, .failure(.runFailed(status: 1, error: notLoaded)), errors)
        }
    }

    // With no failed test named, the tests may not have started, so nothing more is run.
    func test_aFailedRun_thatNamesNoFailedTest_givesNoCoverage() async {
        process.commandResult = { _ in self.result(status: 1) }

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(result, .failure(.runFailed(status: 1, error: nil)))
        XCTAssertEqual(process.commandsRun.count, 1)
    }

    // Only the coverage run builds and runs tests, so only it gets `buildTimeout`. The commands that read what it
    // left, llvm-profdata's merge among them, get no limit.
    func test_onlyTheCoverageRun_hasATimeLimit_theBuildTimeout() async {
        answerWithACoverageRun(
            bundles: ["CoreTests.xctest", "XCTest1234_0.501.profraw"],
            testRun: result(status: 1, output: failedTestsOutput)
        )

        _ = await sut.run(
            with: MuterConfiguration(executable: "/path/to/swift", arguments: ["test"], buildTimeout: 900)
        )

        XCTAssertEqual(process.commandsRun.first?.contains("--enable-code-coverage"), true)
        XCTAssertTrue(process.commandsRun.contains { $0.contains("llvm-profdata") })
        XCTAssertEqual(process.timeLimits, [900, nil, nil, nil, nil])
    }

    func test_withoutABuildTimeout_theCoverageRunHasNoTimeLimit() async {
        answerWithACoverageRun(bundles: ["CoreTests.xctest"])

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.timeLimits, [nil, nil, nil, nil])
    }

    // Killed at its limit, `swift test` ends by a signal, or exits as it is killed, having named failed tests. Neither
    // is read as such, and no profile is merged: the run gives no coverage, and what it printed is kept.
    func test_aCoverageRunPastItsTimeLimit_givesNoCoverage_andKeepsWhatItPrinted() async {
        let limited = MuterConfiguration(executable: "/path/to/swift", arguments: ["test"], buildTimeout: 900)
        let timedOutRuns = [
            CommandResult(status: 9, endedBySignal: true, output: failedTestsOutput, errors: "", timedOut: true),
            CommandResult(status: 1, endedBySignal: false, output: failedTestsOutput, errors: "", timedOut: true),
            CommandResult(status: 0, endedBySignal: false, output: failedTestsOutput, errors: "", timedOut: true),
        ]

        for timedOutRun in timedOutRuns {
            answerWithACoverageRun(bundles: ["CoreTests.xctest", "XCTest1234_0.501.profraw"], testRun: timedOutRun)

            let result = await sut.run(with: limited)
            XCTAssertEqual(result, .failure(.timedOut(after: 900)), "\(timedOutRun)")
            XCTAssertEqual(sut.coverageRunOutput, failedTestsOutput)
        }
        XCTAssertEqual(process.commandsRun.count, timedOutRuns.count)
    }

    // `swift test` itself was stopped, which says nothing of the tests.
    func test_aCoverageRunEndedByASignal_givesNoCoverage() async {
        process.commandResult = { _ in CommandResult(status: 9, endedBySignal: true, output: "", errors: "") }

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(result, .failure(.endedBySignal(9)))
        XCTAssertEqual(process.commandsRun.count, 1)
    }

    func test_aFailedMerge_givesItsFirstLine() async {
        answerWithACoverageRun(
            bundles: ["CoreTests.xctest", "XCTest1234_0.501.profraw"],
            testRun: result(status: 1, output: failedTestsOutput)
        )
        let answer = process.commandResult
        process.commandResult = { command in
            command.contains("llvm-profdata")
                ? self.result(status: 1, errors: "error: XCTest1234_0.501.profraw: invalid profile data\nmore\n")
                : answer(command)
        }

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(
            result,
            .failure(.mergeFailed("error: XCTest1234_0.501.profraw: invalid profile data"))
        )
        XCTAssertFalse(process.commandsRun.contains { $0.contains("llvm-cov") })
    }

    func test_anLLVMProfdataThatCantBeStarted_givesNoCoverage() async {
        answerWithACoverageRun(
            bundles: ["CoreTests.xctest", "XCTest1234_0.501.profraw"],
            testRun: result(status: 1, output: failedTestsOutput)
        )
        let answer = process.commandResult
        process.commandResult = { command in command.contains("llvm-profdata") ? nil : answer(command) }

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(result, .failure(.couldNotRun("llvm-profdata")))
    }

    func test_noProfileLeftByTheTestProcesses_givesNoCoverage() async {
        answerWithACoverageRun(bundles: ["CoreTests.xctest"], testRun: result(status: 1, output: failedTestsOutput))

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(
            result,
            .failure(.noProfileData(atPath: "/project/.build/out/Products/Debug/codecov"))
        )
        XCTAssertFalse(process.commandsRun.contains { $0.contains("llvm-profdata") })
    }

    func test_aTestCommandThatCantBeStarted_givesNoCoverage() async {
        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(result, .failure(.couldNotRun("/path/to/swift")))
    }

    func test_noBuildDirectory_givesNoCoverage() async {
        process.commandResult = { command in
            command.last == "--show-codecov-path" ? self.result(status: 1) : self.result()
        }

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(result, .failure(.noBuildDirectory))
    }

    func test_noProfileData_givesNoCoverage() async {
        answerWithACoverageRun(bundles: ["CoreTests.xctest"], profileExists: false)

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(
            result,
            .failure(.noProfileData(atPath: "/project/.build/out/Products/Debug/codecov/default.profdata"))
        )
    }

    func test_noTestBundle_givesNoCoverage() async {
        answerWithACoverageRun(bundles: ["CLI"])

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(
            result,
            .failure(.noTestBundles(inDirectory: "/project/.build/out/Products/Debug"))
        )
    }

    func test_anLLVMCovFailure_givesItsFirstLine() async {
        answerWithACoverageRun(bundles: ["CoreTests.xctest"])
        let answer = process.commandResult
        process.commandResult = { command in
            command.contains("llvm-cov")
                ? self.result(status: 1, errors: "error: failed to load coverage: 'x': No such file\nmore\n")
                : answer(command)
        }

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(
            result,
            .failure(.llvmCovFailed("error: failed to load coverage: 'x': No such file"))
        )
    }

    func test_anLLVMCovThatCantBeStarted_givesNoCoverage() async {
        answerWithACoverageRun(bundles: ["CoreTests.xctest"])
        let answer = process.commandResult
        process.commandResult = { command in command.contains("llvm-cov") ? nil : answer(command) }

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(result, .failure(.couldNotRun("llvm-cov")))
    }

    // Each follows "Gathering coverage failed: ".
    func test_eachFailure_saysWhy() {
        let errors = everyCoverageError()
        let neverRun: String = "and without its profile the code it ran would read as never run"
        let sevenNamed: String = "-[CTests.CTests test_a], test2() at BTests.swift:2:5, test3() at BTests.swift:3:5, "
            + "test4() at BTests.swift:4:5, test5() at BTests.swift:5:5, and 2 more"
        let notMerged: String = "a test failed with coverage on, "
            + "and llvm-profdata couldn't merge the profiles the test processes left"

        XCTAssertEqual(errors.map(\.reason), [
            "the tests with coverage on didn't end within 900 s (buildTimeout), so SwiftMutator stopped them",
            "the tests with coverage on didn't end within 1.5 s (buildTimeout), so SwiftMutator stopped them",
            "the tests with coverage on were ended by signal 9",
            "a test process crashed with coverage on (CTests.xctest, signal 5), \(neverRun)",
            "a test process crashed with coverage on (BTests.xctest, signal 11), \(neverRun); "
                + "tests that failed: \(sevenNamed)",
            "a test process stopped before its tests finished with coverage on "
                + "(CTests.xctest, during -[CTests.CTests test_z_killed]), \(neverRun)",
            "a test process stopped before its tests finished with coverage on (Swift Testing), \(neverRun); "
                + "tests that failed: \(sevenNamed)",
            "the coverage run failed (exit status 1): error: Build failed",
            "the coverage run failed (exit status 1) without naming a failed test or an error",
            "llvm-cov couldn't be started",
            "`swift test --show-codecov-path` didn't say where the build is",
            "there is no profile data at /b/codecov/default.profdata",
            "there is no test bundle in /b",
            "\(notMerged): error: invalid profile data",
            notMerged,
            "llvm-cov failed: error: malformed coverage data",
            "llvm-cov failed",
            "llvm-cov's report couldn't be read",
            "llvm-cov's report covers none of the project's source files",
        ])
    }

    /// Every kind of coverage failure, some twice to show how their details are worded: a crash or an unfinished test
    /// process with no failed test and with seven.
    func everyCoverageError() -> [CoverageError] {
        let noTests = FailedTestLine.FailedTests(tests: [], total: 0, firstLine: nil)
        let sevenTests = FailedTestLine.FailedTests(
            tests: [.init(name: "-[CTests.CTests test_a]", location: nil)]
                + (2 ... 7).map { .init(name: "test\($0)()", location: "BTests.swift:\($0):5") },
            total: 7,
            firstLine: nil
        )
        return [
            .timedOut(after: 900),
            .timedOut(after: 1.5),
            .endedBySignal(9),
            .testProcessCrashed("CTests.xctest, signal 5", failedTests: noTests),
            .testProcessCrashed("BTests.xctest, signal 11", failedTests: sevenTests),
            .testProcessUnfinished("CTests.xctest, during -[CTests.CTests test_z_killed]", failedTests: noTests),
            .testProcessUnfinished("Swift Testing", failedTests: sevenTests),
            .runFailed(status: 1, error: "error: Build failed"),
            .runFailed(status: 1, error: nil),
            .couldNotRun("llvm-cov"),
            .noBuildDirectory,
            .noProfileData(atPath: "/b/codecov/default.profdata"),
            .noTestBundles(inDirectory: "/b"),
            .mergeFailed("error: invalid profile data"),
            .mergeFailed(""),
            .llvmCovFailed("error: malformed coverage data"),
            .llvmCovFailed(""),
            .unreadableReport,
            .noProjectFiles,
        ]
    }
}
