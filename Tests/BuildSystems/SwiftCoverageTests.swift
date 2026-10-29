@testable import muterCore
import TestingExtensions
import XCTest

final class SwiftCoverageTests: MuterTestCase {
    /// macOS's build folder and tools, on any host.
    private let sut = SwiftCoverage(platform: .darwin)
    private let onLinux = SwiftCoverage(platform: .linux)
    /// Swift Build's build folder on Linux.
    private let linuxBuild = "/project/.build/out/Products/Debug-linux"

    private var coverageThreshold: Double = 0
    private lazy var muterConfiguration = MuterConfiguration(
        executable: "/path/to/swift",
        arguments: ["test", "--skip", "Slow"],
        coverageThreshold: coverageThreshold
    )

    // MARK: - Running the coverage

    // Swift Build makes a bundle for each test target, and each maps only the code its target links, so one export
    // takes them all: the first by name, then each other as an object.
    func test_coverage_isExportedFromEveryTestBundle_inOneCall() async {
        answerWithACoverageRun(
            bundles: ["CoreTests.xctest", "AppTests.xctest"],
            testTargets: ["CoreTests", "AppTests"]
        )

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun, [
            [
                "/path/to/swift", "test", "--skip", "Slow", "--enable-code-coverage",
                "-Xswiftc", "-Xllvm", "-Xswiftc", "-instrprof-atomic-counter-update-all",
            ],
            ["/path/to/swift", "test", "--skip", "Slow", "--show-codecov-path"],
            ["/path/to/swift", "package", "describe", "--type", "json"],
            [
                "/usr/bin/xcrun", "llvm-cov", "export",
                bundle("AppTests"), "-object", bundle("CoreTests"),
                "-instr-profile", "/project/.build/out/Products/Debug/codecov/default.profdata",
            ],
        ])
        XCTAssertEqual(fileManager.contentsOfDirectoryAtPath, ["/project/.build/out/Products/Debug"])
    }

    // A bundle left by a test target the package no longer has, if built at the copy's paths, would read its functions,
    // at lines that now hold other code, as never run.
    func test_theBundleOfATestTargetThePackageNoLongerHas_isLeftOut() async {
        answerWithACoverageRun(bundles: ["CoreTests.xctest", "OldTests.xctest"], testTargets: ["CoreTests"])

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export", bundle("CoreTests"),
            "-instr-profile", "/project/.build/out/Products/Debug/codecov/default.profdata",
        ])
    }

    // The native build system names its one bundle after the package. Without the package's description, every
    // bundle is used.
    func test_everyBundle_isKept_whenNoneIsNamedAfterATestTarget_orTheTargetsAreUnknown() async {
        answerWithACoverageRun(bundles: ["ProjectPackageTests.xctest"], testTargets: ["CoreTests"])
        _ = await sut.run(with: muterConfiguration)
        XCTAssertEqual(process.commandsRun.last?.dropFirst(3).first, bundle("ProjectPackageTests"))

        answerWithACoverageRun(bundles: ["CoreTests.xctest", "OldTests.xctest", "Package.swift"], testTargets: nil)
        _ = await sut.run(with: muterConfiguration)
        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export", bundle("CoreTests"), "-object", bundle("OldTests"),
            "-instr-profile", "/project/.build/out/Products/Debug/codecov/default.profdata",
        ])
    }

    // The native build system makes one bundle for the whole package.
    func test_aSingleTestBundle_isExportedAlone() async {
        answerWithACoverageRun(bundles: ["ProjectPackageTests.xctest"])

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last?.dropFirst(3).first, bundle("ProjectPackageTests"))
        XCTAssertFalse(process.commandsRun.last?.contains("-object") ?? true)
    }

    func test_theCoverage_comesFromTheExport() async throws {
        answerWithACoverageRun(bundles: ["CoreTests.xctest"])
        coverageThreshold = 70

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(coverage.percent, 50)
        // Shared.swift has 4 of its 6 lines run, under the configured threshold.
        XCTAssertEqual(coverage.filesWithoutCoverage, ["Sources/Core/Shared.swift", "Sources/Core/Untested.swift"])
        XCTAssertEqual(coverage.functionsCoverage.regionsForFile("/project/Sources/Core/Shared.swift"), [
            .make(lineStart: 3, columnStart: 20, lineEnd: 5, columnEnd: 2, executionCount: 0),
        ])
        XCTAssertNil(coverage.testsFailedWithCoverageOn)
    }

    // What the run printed is kept in the run's log folder, standard error from a line of its own.
    func test_theCoverageRunsOutput_isKept_standardOutputThenStandardError() async {
        XCTAssertNil(sut.coverageRunOutput)
        _ = await sut.run(with: muterConfiguration)
        XCTAssertNil(sut.coverageRunOutput, "a run that can't be started printed nothing")

        process.commandResult = { _ in self.result(status: 1, output: "Test run started", errors: "oops\n") }
        _ = await sut.run(with: muterConfiguration)
        XCTAssertEqual(sut.coverageRunOutput, "Test run started\noops\n")

        process.commandResult = { _ in self.result(status: 1, output: "passed\n", errors: "Build complete!\n") }
        _ = await sut.run(with: muterConfiguration)
        XCTAssertEqual(sut.coverageRunOutput, "passed\nBuild complete!\n")
    }

    // SwiftPM merges the test processes' profiles only when every test passes, but each process, the failed tests'
    // too, still left its own. Merged in name order, they give the coverage, which says which tests failed.
    func test_failedTests_withoutACrash_mergeTheProfilesEachTestProcessLeft() async throws {
        answerWithACoverageRun(
            bundles: [
                "CoreTests.xctest", "XCTest1234_0.501.profraw", "Swift Testing1234_0.502.profraw", "Project.json",
            ],
            testRun: result(status: 1, output: failedTestsOutput, errors: "Build complete! (1.60 sec)\n")
        )

        let coverage = try await sut.run(with: muterConfiguration).get()

        let codecov = "/project/.build/out/Products/Debug/codecov"
        XCTAssertEqual(process.commandsRun, [
            [
                "/path/to/swift", "test", "--skip", "Slow", "--enable-code-coverage",
                "-Xswiftc", "-Xllvm", "-Xswiftc", "-instrprof-atomic-counter-update-all",
            ],
            ["/path/to/swift", "test", "--skip", "Slow", "--show-codecov-path"],
            [
                "/usr/bin/xcrun", "llvm-profdata", "merge", "-sparse",
                codecov + "/Swift Testing1234_0.502.profraw", codecov + "/XCTest1234_0.501.profraw",
                "-o", codecov + "/default.profdata",
            ],
            ["/path/to/swift", "package", "describe", "--type", "json"],
            [
                "/usr/bin/xcrun", "llvm-cov", "export", bundle("CoreTests"),
                "-instr-profile", codecov + "/default.profdata",
            ],
        ])
        XCTAssertEqual(fileManager.contentsOfDirectoryAtPath, [codecov, "/project/.build/out/Products/Debug"])
        XCTAssertEqual(coverage.percent, 50)
        XCTAssertEqual(coverage.testsFailedWithCoverageOn, failedTests)
    }

    // A crashed test process left no profile, so merging would read the code it ran as never run.
    func test_aCrashedTestProcess_givesNoCoverage_andIsNamed() async {
        answerWithACoverageRun(
            bundles: ["CTests.xctest", "XCTest1234_0.501.profraw"],
            testRun: result(
                status: 1,
                output: failedTestsOutput,
                errors: """
                Build complete! (0.60 sec)
                error: Process '/Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
                /project/.build/out/Products/Debug/CTests.xctest' exited with unexpected signal code 5

                """
            )
        )

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(
            result,
            .failure(.testProcessCrashed("CTests.xctest, signal 5", failedTests: failedTests))
        )
        XCTAssertEqual(process.commandsRun.count, 1)
    }

    // Swift Testing's helper names the bundle's executable, and on Linux, Swift Build's test process is the target's
    // runner; an older SwiftPM names no process. Any line that mentions a signal code is a crash, however else it's
    // worded.
    func test_aCrash_isFound_howeverItsLineIsWorded() async {
        let lines = [
            "error: Process '/usr/libexec/swift/pm/swiftpm-testing-helper --test-bundle-path "
                + "/p/Debug/BTests.xctest/Contents/MacOS/BTests --enable-code-coverage /p/Debug/BTests.xctest/Contents/"
                + "MacOS/BTests --testing-library swift-testing' exited with unexpected signal code 5",
            "error: Process '/p/.build/debug/ProjectPackageTests.xctest' exited with unexpected signal code 4",
            "error: Process '/p/.build/out/Products/Debug-linux/CoreTests-test-runner --testing-library swift-testing' "
                + "exited with unexpected signal code 11",
            "error: Process '/p/.build/out/Products/Debug-linux/AppTests-test-runner' exited with unexpected signal code 4",
            "\u{1B}[1;31merror: \u{1B}[0mExited with signal code 11",
            "error: a test process ended with an unknown Signal Code",
        ]

        var crashes: [Result<Coverage, CoverageError>] = []
        for line in lines {
            process.commandResult = { _ in self.result(status: 1, errors: "Build complete!\n\(line)\n") }
            crashes.append(await sut.run(with: muterConfiguration))
        }

        let noTests = FailedTestLine.FailedTests(tests: [], count: 0, firstLine: nil)
        XCTAssertEqual(crashes, [
            .failure(.testProcessCrashed("BTests.xctest, signal 5", failedTests: noTests)),
            .failure(.testProcessCrashed("ProjectPackageTests.xctest, signal 4", failedTests: noTests)),
            .failure(.testProcessCrashed("CoreTests-test-runner, signal 11", failedTests: noTests)),
            .failure(.testProcessCrashed("AppTests-test-runner, signal 4", failedTests: noTests)),
            .failure(.testProcessCrashed("signal 11", failedTests: noTests)),
            .failure(.testProcessCrashed(
                "error: a test process ended with an unknown Signal Code",
                failedTests: noTests
            )),
        ])
    }

    // SwiftPM prints no line for a test process ended by SIGKILL, SIGTERM or SIGINT, as the system's memory killer
    // ends one, and it left no profile. In these real runs, CTests' XCTest process killed itself during its second test,
    // and STTests' Swift Testing process too, while one of ATests' tests failed. What they started never ended.
    func test_aTestProcessThatStoppedBeforeItsTestsFinished_givesNoCoverage_andIsNamed() async {
        let runs = [
            (log: "coverageRun_testProcessesKilled_swiftBuild.log", bundle: "CTests.xctest", seconds: "0.045"),
            (log: "coverageRun_testProcessesKilled_native.log", bundle: "KillProbePackageTests.xctest", seconds: "0.041"),
        ]

        for run in runs {
            answerWithACoverageRun(
                bundles: ["ATests.xctest", "CTests.xctest", "XCTest1234_0.501.profraw"],
                testRun: result(
                    status: 1,
                    output: loadFixture("TestLogsForParsing/\(run.log)"),
                    errors: "Building for debugging...\nBuild complete! (5.66 sec)\n"
                )
            )

            let result = await sut.run(with: muterConfiguration)
            XCTAssertEqual(
                result,
                .failure(.testProcessUnfinished(
                    "\(run.bundle), during -[CTests.CTests test_z_killed]",
                    failedTests: FailedTestLine.FailedTests(
                        tests: [.init(name: "-[ATests.ATests test_fails]", location: nil)],
                        count: 1,
                        firstLine: "Test Case '-[ATests.ATests test_fails]' failed (\(run.seconds) seconds)."
                    )
                )),
                run.log
            )
        }
        XCTAssertEqual(process.commandsRun.count, runs.count)
    }

    // XCTest runs one test at a time, so the test a process was running is known, and names the bundle in a suite of
    // its own. On Linux it names the bundle after the build folder, and with a filter not at all. Swift Testing's lines
    // name no bundle, and of the tests it runs at once, the first that never ended is named. A process that finished
    // nothing it started, with no failed test named, is still named.
    func test_anUnfinishedTestProcess_isNamed_asFarAsItsOutputSays() async {
        let failed = "Test Case '-[ATests.ATests test_fails]' failed (0.045 seconds).\n"
        let outputs = [
            """
            Test Suite 'All tests' started at 2026-10-23 07:46:16.235
            Test Suite 'debug.xctest' started at 2026-10-23 07:46:16.236
            Test Suite 'CTests' started at 2026-10-23 07:46:16.236
            Test Case 'CTests.test_c' started at 2026-10-23 07:46:16.236
            Test Case 'CTests.test_c' passed (0.0 seconds)
            Test Case 'CTests.test_z_killed' started at 2026-10-23 07:46:16.237
            \(failed)
            """,
            """
            Test Suite 'Selected tests' started at 2026-10-23 07:46:16.235.
            Test Case '-[CTests.CTests test_z_killed]' started.
            \(failed)
            """,
            """
            \(failed)\
            ◇ Test run started.
            ↳ Testing Library Version: 2084
            ◇ Test stKilled() started.
            ◇ Test stWorks() started.
            ✔ Test stWorks() passed after 0.001 seconds.
            ◇ Test run started.
            ✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.

            """,
            "Test Suite 'All tests' started at 2026-10-23 07:46:16.235.\n",
        ]

        var reasons: [String] = []
        for output in outputs {
            process.commandResult = { _ in self.result(status: 1, output: output, errors: "Build complete!\n") }
            guard case let .failure(.testProcessUnfinished(named, _)) = await sut.run(with: muterConfiguration) else {
                reasons.append("not unfinished")
                continue
            }
            reasons.append(named)
        }

        XCTAssertEqual(reasons, [
            "debug.xctest, during CTests.test_z_killed",
            "XCTest, during -[CTests.CTests test_z_killed]",
            "Swift Testing, during stKilled()",
            "XCTest",
        ])
        XCTAssertEqual(process.commandsRun.count, outputs.count)
    }

    // Every suite, test and Swift Testing run these real runs started ended, the failed tests' too, so the profiles
    // are merged: Swift Build's, with a test process for each target and each library, some running no test, and the
    // native build system's, with one for each library.
    func test_realRunsWhoseTestProcessesAllFinished_areMerged() async throws {
        let runs = [
            (log: "coverageRun_testFailed_swiftBuild.log", failed: ["failsOnlyUnderCoverage()"]),
            (
                log: "coverageRun_testFailed_native.log",
                failed: ["-[CTests.CTests test_failsOnlyUnderCoverage]", "failsOnlyUnderCoverage()"]
            ),
        ]

        for run in runs {
            answerWithACoverageRun(
                bundles: ["CoreTests.xctest", "XCTest1234_0.501.profraw"],
                testRun: result(
                    status: 1,
                    output: loadFixture("TestLogsForParsing/\(run.log)"),
                    errors: "Build complete! (1.60 sec)\n"
                )
            )

            let coverage = try await sut.run(with: muterConfiguration).get()

            XCTAssertEqual(coverage.testsFailedWithCoverageOn?.tests.map(\.name), run.failed, run.log)
            XCTAssertTrue(process.commandsRun.contains { $0.contains("llvm-profdata") }, run.log)
        }
    }

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

        _ = await sut.run(with: MuterConfiguration(executable: "/path/to/swift", arguments: ["test"], buildTimeout: 900))

        XCTAssertTrue(process.commandsRun.first?.contains("--enable-code-coverage") == true)
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
        let noTests = FailedTestLine.FailedTests(tests: [], count: 0, firstLine: nil)
        let sevenTests = FailedTestLine.FailedTests(
            tests: [.init(name: "-[CTests.CTests test_a]", location: nil)]
                + (2 ... 7).map { .init(name: "test\($0)()", location: "BTests.swift:\($0):5") },
            count: 7,
            firstLine: nil
        )
        let errors: [CoverageError] = [
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

    // MARK: - On Linux

    // Swift Build makes for each test target a runner that loads the target's tests, and with them its coverage
    // mapping, from a `.so` next to it. Neither the runners nor the libraries the tests link are read.
    func test_onLinux_eachTestTargetsLibrary_isExported_notItsRunner_orAnotherLibrary() async {
        answerWithACoverageRun(
            bundles: [
                "CoreTests.so", "CoreTests-test-runner", "AppTests.so", "AppTests-test-runner", "Core.so", "libCore.so",
            ],
            testTargets: ["CoreTests", "AppTests"],
            buildDirectory: linuxBuild
        )

        _ = await onLinux.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/env", "llvm-cov", "export",
            linuxBuild + "/AppTests.so", "-object", linuxBuild + "/CoreTests.so",
            "-instr-profile", linuxBuild + "/codecov/default.profdata",
        ])
        XCTAssertEqual(fileManager.contentsOfDirectoryAtPath, [linuxBuild])
    }

    // A `.so` with no runner next to it holds no tests, even when the package's test targets are unknown, and the pair
    // of a test target the package no longer has is left out, as on macOS.
    func test_onLinux_aLibraryWithoutARunner_andAStaleTestTargetsPair_areLeftOut() async {
        answerWithACoverageRun(
            bundles: ["CoreTests.so", "CoreTests-test-runner", "Core.so", "libCore.so"],
            testTargets: nil,
            buildDirectory: linuxBuild
        )
        _ = await onLinux.run(with: muterConfiguration)
        XCTAssertEqual(process.commandsRun.last?.dropFirst(2), [
            "export", linuxBuild + "/CoreTests.so", "-instr-profile", linuxBuild + "/codecov/default.profdata",
        ])

        answerWithACoverageRun(
            bundles: ["CoreTests.so", "CoreTests-test-runner", "OldTests.so", "OldTests-test-runner"],
            testTargets: ["CoreTests"],
            buildDirectory: linuxBuild
        )
        _ = await onLinux.run(with: muterConfiguration)
        XCTAssertEqual(process.commandsRun.last?.dropFirst(2), [
            "export", linuxBuild + "/CoreTests.so", "-instr-profile", linuxBuild + "/codecov/default.profdata",
        ])
    }

    // The native build system's one bundle, named after the package, is itself the executable on Linux.
    func test_onLinux_theNativeBuildSystemsBundle_isExportedAsItIs() async {
        let native = "/project/.build/x86_64-unknown-linux-gnu/debug"
        answerWithACoverageRun(bundles: ["ProjectPackageTests.xctest", "Core.build"], buildDirectory: native)

        _ = await onLinux.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/env", "llvm-cov", "export", native + "/ProjectPackageTests.xctest",
            "-instr-profile", native + "/codecov/default.profdata",
        ])
    }

    // SwiftPM takes the llvm-cov next to the toolchain's `swiftc`. One from elsewhere on PATH, such as a
    // distribution's, may not read the toolchain's profiles.
    func test_onLinux_llvmCov_isTheOneNextToTheTestCommand_whenThereIsOne() async throws {
        answerWithACoverageRun(bundles: ["CoreTests.so", "CoreTests-test-runner"], buildDirectory: linuxBuild)
        fileManager.fileExistsToReturn = [true, true]

        let coverage = try await onLinux.run(with: muterConfiguration).get()

        XCTAssertEqual(process.commandsRun.last, [
            "/path/to/llvm-cov", "export", linuxBuild + "/CoreTests.so",
            "-instr-profile", linuxBuild + "/codecov/default.profdata",
        ])
        XCTAssertEqual(fileManager.fileExistsAtPath, [linuxBuild + "/codecov/default.profdata", "/path/to/llvm-cov"])
        XCTAssertEqual(coverage.percent, 50)
    }

    func test_onLinux_llvmCov_isTheOneOnThePath_whenNoneIsNextToTheTestCommand() async {
        answerWithACoverageRun(bundles: ["CoreTests.so", "CoreTests-test-runner"], buildDirectory: linuxBuild)
        fileManager.fileExistsToReturn = [true, false]

        _ = await onLinux.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last?.prefix(3), ["/usr/bin/env", "llvm-cov", "export"])
        XCTAssertEqual(fileManager.fileExistsAtPath.last, "/path/to/llvm-cov")
    }

    // `/usr/bin/swift` is often a link into the toolchain, whose folder holds the LLVM tools.
    func test_onLinux_theLLVMTools_areLookedFor_whereTheTestCommandsLinkLeads() async throws {
        let directory = try makeTemporaryDirectory().canonicalPath
        let toolchain = directory + "/toolchain/usr/bin"
        try FileManager.default.createDirectory(atPath: toolchain, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: toolchain + "/swift", contents: nil)
        try FileManager.default.createSymbolicLink(
            atPath: directory + "/swift",
            withDestinationPath: toolchain + "/swift"
        )
        answerWithACoverageRun(bundles: ["CoreTests.so", "CoreTests-test-runner"], buildDirectory: linuxBuild)
        fileManager.fileExistsToReturn = [true, true]

        _ = await onLinux.run(with: MuterConfiguration(executable: directory + "/swift", arguments: ["test"]))

        XCTAssertEqual(process.commandsRun.last?.first, toolchain + "/llvm-cov")
        XCTAssertEqual(fileManager.fileExistsAtPath.last, toolchain + "/llvm-cov")
    }

    // The merge after a failed test looks for llvm-profdata the same way.
    func test_onLinux_theMerge_usesTheLLVMProfdataNextToTheTestCommand_orElseTheOneOnThePath() async {
        let codecov = linuxBuild + "/codecov"
        let merge = ["merge", "-sparse", codecov + "/XCTest1234_0.501.profraw", "-o", codecov + "/default.profdata"]
        answerWithACoverageRun(
            bundles: ["CoreTests.so", "CoreTests-test-runner", "XCTest1234_0.501.profraw"],
            buildDirectory: linuxBuild,
            testRun: result(status: 1, output: failedTestsOutput)
        )

        fileManager.fileExistsToReturn = [true, true]
        _ = await onLinux.run(with: muterConfiguration)
        XCTAssertEqual(process.commandsRun.last(where: { $0.contains("merge") }), ["/path/to/llvm-profdata"] + merge)
        XCTAssertEqual(fileManager.fileExistsAtPath.first, "/path/to/llvm-profdata")

        fileManager.fileExistsToReturn = [false, true]
        _ = await onLinux.run(with: muterConfiguration)
        XCTAssertEqual(
            process.commandsRun.last(where: { $0.contains("merge") }),
            ["/usr/bin/env", "llvm-profdata"] + merge
        )
    }

    func test_theHostPlatform_isTheOneSwiftMutatorWasBuiltFor() {
        #if os(Linux)
        XCTAssertEqual(SwiftCoverage.Platform.host, .linux)
        #else
        XCTAssertEqual(SwiftCoverage.Platform.host, .darwin)
        #endif
    }

    // MARK: - Reading the export

    // Only the project's own source files count: not its tests, by name or by folder, a build folder, or anything
    // outside it, such as the test runner's entry point or a sibling folder whose name starts with the project's. Each
    // is named by its path in the project, which is how discovery finds it.
    func test_theExport_countsOnlyTheProjectsOwnSourceFiles() throws {
        let coverage = try SwiftCoverage.coverage(
            fromExport: export(files: [
                file("/project/Sources/Core/Shared.swift", count: 10, covered: 8),
                file("/project/Sources/Core/Untested.swift", count: 6, covered: 0),
                file("/project/Sources/Core/Declarations.swift", count: 0, covered: 0),
                file("/project/Tests/CoreTests/SharedTests.swift", count: 40, covered: 40),
                file("/project/Tests/CoreTests/Helpers.swift", count: 4, covered: 0),
                file("/project/Sources/Core/HelperTests.swift", count: 4, covered: 4),
                file("/project/.build/checkouts/swift-syntax/Sources/Syntax.swift", count: 99, covered: 0),
                file("/project/Package/.build/checkouts/Pathos/Sources/Pathos.swift", count: 7, covered: 0),
                file("/derived/test_entry_point.swift", count: 5, covered: 5),
                file("/project-utils/Sources/Utils.swift", count: 3, covered: 0),
            ]),
            projectRoot: "/project",
            coverageThreshold: 0
        ).get()

        // 8 of 16 lines; a file with no lines to run isn't one without coverage.
        XCTAssertEqual(coverage.percent, 50)
        XCTAssertEqual(coverage.filesWithoutCoverage, ["Sources/Core/Untested.swift"])
    }

    func test_filesAtOrBelowTheThreshold_haveNoCoverage() throws {
        let coverage = try SwiftCoverage.coverage(
            fromExport: export(files: [
                file("/project/A.swift", count: 4, covered: 1),
                file("/project/B.swift", count: 4, covered: 2),
                file("/project/C.swift", count: 4, covered: 3),
            ]),
            projectRoot: "/project/",
            coverageThreshold: 50
        ).get()

        XCTAssertEqual(coverage.filesWithoutCoverage, ["A.swift", "B.swift"])
        XCTAssertEqual(coverage.percent, 50)
    }

    // llvm-cov's share of 7 of 100 lines, 7 / 100 * 100, is just above 7.
    func test_aFileExactlyAtTheThreshold_hasNoCoverage_whateverItsShareRoundsTo() throws {
        let coverage = try SwiftCoverage.coverage(
            fromExport: export(files: [file("/project/A.swift", count: 100, covered: 7)]),
            projectRoot: "/project",
            coverageThreshold: 7
        ).get()

        XCTAssertEqual(coverage.filesWithoutCoverage, ["A.swift"])
    }

    // A share that doesn't divide evenly is rounded down, as llvm-cov's total was.
    func test_thePercent_isRoundedDown() throws {
        let coverage = try SwiftCoverage.coverage(
            fromExport: export(files: [file("/project/A.swift", count: 3, covered: 2)]),
            projectRoot: "/project",
            coverageThreshold: 0
        ).get()

        XCTAssertEqual(coverage.percent, 66)
    }

    func test_aProjectWithNoLinesToRun_hasNoCoverage_andNoFileWithout() throws {
        let coverage = try SwiftCoverage.coverage(
            fromExport: export(files: [file("/project/Declarations.swift", count: 0, covered: 0)]),
            projectRoot: "/project",
            coverageThreshold: 0
        ).get()

        XCTAssertEqual(coverage.percent, 0)
        XCTAssertEqual(coverage.filesWithoutCoverage, [])
    }

    // A project path holding "Tests" or "build" hid every file from the report it was read from, which then crashed.
    // Only a file's path in the project says whether it is a test or a build file.
    func test_aProjectInAFolderNamedTestsOrBuild_isCovered() throws {
        for root in ["/Users/me/Tests/build/Project", "/Users/me/.build/Project"] {
            let coverage = try SwiftCoverage.coverage(
                fromExport: export(files: [file(root + "/Sources/A.swift", count: 3, covered: 3)]),
                projectRoot: root,
                coverageThreshold: 0
            ).get()

            XCTAssertEqual(coverage.percent, 100)
        }
    }

    // llvm-cov names files by their real path, which may differ from the path the project was reached by.
    func test_aProjectReachedThroughASymbolicLink_isCovered() throws {
        let directory = try makeTemporaryDirectory()
        let link = directory + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory)
        defer { try? FileManager.default.removeItem(atPath: link) }

        let coverage = try SwiftCoverage.coverage(
            fromExport: export(files: [file(directory.canonicalPath + "/A.swift", count: 2, covered: 0)]),
            projectRoot: link,
            coverageThreshold: 0
        ).get()

        XCTAssertEqual(coverage.filesWithoutCoverage, ["A.swift"])
    }

    func test_anExportWithNoneOfTheProjectsFiles_givesNoCoverage() {
        XCTAssertEqual(
            SwiftCoverage.coverage(
                fromExport: export(files: [file("/elsewhere/A.swift", count: 2, covered: 2)]),
                projectRoot: "/project",
                coverageThreshold: 0
            ),
            .failure(.noProjectFiles)
        )
    }

    func test_anUnreadableExport_givesNoCoverage() {
        XCTAssertEqual(
            SwiftCoverage.coverage(fromExport: Data("not json".utf8), projectRoot: "/project", coverageThreshold: 0),
            .failure(.unreadableReport)
        )
    }

    // MARK: - Helpers

    /// Answers a coverage run that ends as `testRun` says, whose build is at `buildDirectory` and holds `bundles`, in a
    /// package whose test targets are `testTargets`, or that can't be described, with the export `exportJSON` gives.
    /// `bundles` also lists the build's `codecov` folder, so it holds any profiles there too. The LLVM tools, by
    /// whatever path, answer as llvm-cov and llvm-profdata.
    private func answerWithACoverageRun(
        bundles: [String],
        testTargets: [String]? = ["CoreTests"],
        profileExists: Bool = true,
        buildDirectory: String = "/project/.build/out/Products/Debug",
        testRun: CommandResult? = nil
    ) {
        fileManager.currentDirectoryPathToReturn = "/project"
        fileManager.contentsOfDirectoryToReturn = bundles
        fileManager.fileExistsToReturn = [profileExists]
        let export = exportJSON
        let description = testTargets.map { names in
            let targets = names.map { #"{"name": "\#($0)", "type": "test"}"# }
                + [#"{"name": "Core", "type": "library"}"#]
            return #"{"name": "Project", "targets": [\#(targets.joined(separator: ","))]}"#
        }
        process.commandResult = { command in
            if command.last == "--show-codecov-path" {
                return self.result(output: buildDirectory + "/codecov/Project.json\n")
            }
            if command.contains("describe") {
                return description.map { self.result(output: $0) } ?? self.result(status: 1)
            }
            if command.contains(where: { $0.hasSuffix("llvm-profdata") }) {
                return self.result()
            }
            return command.contains(where: { $0.hasSuffix("llvm-cov") })
                ? self.result(output: export)
                : testRun ?? self.result(output: "Test run passed\n")
        }
    }

    /// A coverage run's output in which an XCTest test and a Swift Testing test failed, as `failedTests` names them.
    private let failedTestsOutput = """
    Test Case '-[CTests.CTests test_c]' started.
    Test Case '-[CTests.CTests test_c]' passed (0.000 seconds).
    Test Case '-[CTests.CTests test_failsOnlyUnderCoverage]' started.
    Test Case '-[CTests.CTests test_failsOnlyUnderCoverage]' failed (0.039 seconds).
    ◇ Test failsOnlyUnderCoverage() started.
    ✘ Test failsOnlyUnderCoverage() recorded an issue at BTests.swift:11:9: Expectation failed: !underCoverage
    ✘ Test failsOnlyUnderCoverage() failed after 0.001 seconds with 1 issue.
    Note: Some test targets reported failures:
      - CTests (XCTest)
      - BTests (Swift Testing)

    """

    private let failedTests = FailedTestLine.FailedTests(
        tests: [
            .init(name: "-[CTests.CTests test_failsOnlyUnderCoverage]", location: nil),
            .init(name: "failsOnlyUnderCoverage()", location: "BTests.swift:11:9"),
        ],
        count: 2,
        firstLine: "Test Case '-[CTests.CTests test_failsOnlyUnderCoverage]' failed (0.039 seconds)."
    )

    private func bundle(_ name: String) -> String {
        "/project/.build/out/Products/Debug/\(name).xctest/Contents/MacOS/\(name)"
    }

    private var exportJSON: String {
        String(decoding: export(
            files: [
                file("/project/Sources/Core/Shared.swift", count: 6, covered: 4),
                file("/project/Sources/Core/Untested.swift", count: 2, covered: 0),
            ],
            functions: """
            {"filenames": ["/project/Sources/Core/Shared.swift"],
             "regions": [[1, 30, 6, 2, 3, 0, 0, 0], [3, 20, 5, 2, 0, 0, 0, 0]]}
            """
        ), as: UTF8.self)
    }

    private func export(files: [String], functions: String = "") -> Data {
        Data("""
        {"type": "llvm.coverage.json.export", "version": "3.0.1",
         "data": [{"files": [\(files.joined(separator: ","))], "functions": [\(functions)]}]}
        """.utf8)
    }

    /// A file of llvm-cov's export, with its percentage worked out as llvm-cov does.
    private func file(_ path: String, count: Int, covered: Int) -> String {
        let percent = count > 0 ? Double(covered) / Double(count) * 100 : 0
        return """
        {"filename": "\(path)", "summary": {"lines": {"count": \(count), "covered": \(covered), "percent": \(percent)}}}
        """
    }

    private func result(status: Int32 = 0, output: String = "", errors: String = "") -> CommandResult {
        CommandResult(status: status, endedBySignal: false, output: output, errors: errors)
    }
}
