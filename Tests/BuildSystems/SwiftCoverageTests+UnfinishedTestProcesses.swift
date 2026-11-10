@testable import muterCore
import TestingExtensions
import XCTest

extension SwiftCoverageTests {
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
            "error: Process '/p/.build/out/Products/Debug-linux/AppTests-test-runner' "
                + "exited with unexpected signal code 4",
            "\u{1B}[1;31merror: \u{1B}[0mExited with signal code 11",
            "error: a test process ended with an unknown Signal Code",
        ]

        var crashes: [Result<Coverage, CoverageError>] = []
        for line in lines {
            process.commandResult = { _ in self.result(status: 1, errors: "Build complete!\n\(line)\n") }
            crashes.append(await sut.run(with: muterConfiguration))
        }

        let noTests = FailedTestLine.FailedTests(tests: [], total: 0, firstLine: nil)
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
    // ends one, and it left no profile. In these real runs, CTests' XCTest process killed itself during its second
    // test, and STTests' Swift Testing process too, while one of ATests' tests failed. What they started never ended.
    func test_aTestProcessThatStoppedBeforeItsTestsFinished_givesNoCoverage_andIsNamed() async {
        let runs = [
            (log: "coverageRun_testProcessesKilled_swiftBuild.log", bundle: "CTests.xctest", seconds: "0.045"),
            (
                log: "coverageRun_testProcessesKilled_native.log",
                bundle: "KillProbePackageTests.xctest",
                seconds: "0.041"
            ),
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
                        total: 1,
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
}
