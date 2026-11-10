@testable import muterCore
import TestingExtensions
import XCTest

extension XcodeBuildCoverageTests {
    // Every test process leaves what it counted in the result bundle, a failed test's too, so the coverage is kept, and
    // says which tests failed. In this real run, a Swift Testing test and an XCTest test failed.
    func test_failedTests_withoutACrash_keepTheCoverage_andAreNamed() async throws {
        answerTheCoverageRun(
            printing: loadFixture("TestLogsForParsing/coverageRun_xcodebuild_testFailed.log"),
            status: 65
        )
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = coverageData
        fileManager.currentDirectoryPathToReturn = "/project"

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(process.arguments, [
            "xccov", "view", "--report", "--json",
            "/DerivedData/Logs/Test/Test-XProbe-2026.10.23_08-23-07--0500.xcresult",
        ])
        XCTAssertEqual(coverage.percent, 10)
        XCTAssertEqual(coverage.testsFailedWithCoverageOn?.tests, [
            .init(name: "sFails()", location: "STests.swift:10:5"),
            .init(name: "-[ATests.ATests test_fails]", location: nil),
        ])
    }

    // Xcode keeps what a crashed test process counted, but relaunches it without finishing the tests it was running,
    // so the code they would have run would read as never run. In these real runs, an XCTest test crashed, and Xcode
    // said it restarted, while two other tests failed; and a Swift Testing test crashed, which Xcode says nothing of,
    // but its run and the test, started twice, never ended.
    func test_aCrashedTestProcess_givesNoCoverage_andIsNamed() async {
        let runs = [
            (
                log: "coverageRun_xcodebuild_testCrashed.log",
                process: "CTests.xctest, during -[CTests.CTests test_z_crash]",
                failed: ["sFails()", "-[ATests.ATests test_fails]"]
            ),
            (
                log: "coverageRun_xcodebuild_swiftTestingCrashed.log",
                process: "Swift Testing, during stCrashes()",
                failed: []
            ),
        ]

        for run in runs {
            answerTheCoverageRun(printing: loadFixture("TestLogsForParsing/\(run.log)"), status: 65)

            let result = await sut.run(with: muterConfiguration)
            guard case let .failure(.testProcessRelaunched(named, failedTests)) = result else {
                XCTFail("not a relaunched test process: \(run.log)")
                continue
            }
            XCTAssertEqual(named, run.process, run.log)
            XCTAssertEqual(failedTests.tests.map(\.name), run.failed, run.log)
        }
        XCTAssertNil(process.executableURL, "xccov ran")
    }

    // With parallel testing, xcodebuild prints `Test case '…' failed on '…'` for a crashed test as for a failed one, as
    // in this real run, where an XCTest test crashed. With no failed test named, a crash can't be ruled out. Its
    // standard error, on a Mac whose simulators are out of date, logs a method named `…:error:`, which is no error. A
    // build that fails names no failed test either, and its first error says why.
    func test_aFailedRun_thatNamesNoFailedTest_givesNoCoverage() async {
        answerTheCoverageRun(
            printing: loadFixture("TestLogsForParsing/coverageRun_xcodebuild_parallel_testCrashed.log"),
            errors: simulatorsOutOfDate + "Failing tests:\n\tCTests.test_z_crash()\n\n** TEST FAILED **\n",
            status: 65
        )
        let crashed = await sut.run(with: muterConfiguration)
        XCTAssertEqual(crashed, .failure(.runFailed(status: 65, error: nil)))

        answerTheCoverageRun(
            printing: "/project/App/Model.swift:3:9: error: cannot find 'x' in scope\n\n** TEST FAILED **\n",
            errors: simulatorsOutOfDate,
            status: 65
        )
        let compileError = await sut.run(with: muterConfiguration)
        XCTAssertEqual(
            compileError,
            .failure(.runFailed(status: 65, error: "/project/App/Model.swift:3:9: error: cannot find 'x' in scope"))
        )

        answerTheCoverageRun(
            printing: "",
            errors: simulatorsOutOfDate + "xcodebuild: error: Unknown build action 'tset'.\n",
            status: 64
        )
        let unknownAction = await sut.run(with: muterConfiguration)
        XCTAssertEqual(
            unknownAction,
            .failure(.runFailed(status: 64, error: "xcodebuild: error: Unknown build action 'tset'."))
        )

        answerTheCoverageRun(
            printing: "/project/App/Bridge.m:1:9: fatal error: 'Missing.h' file not found\n",
            errors: simulatorsOutOfDate,
            status: 65
        )
        let missingHeader = await sut.run(with: muterConfiguration)
        XCTAssertEqual(
            missingHeader,
            .failure(.runFailed(
                status: 65,
                error: "/project/App/Bridge.m:1:9: fatal error: 'Missing.h' file not found"
            ))
        )
        XCTAssertNil(process.executableURL, "xccov ran")
    }

    // xcodebuild itself was stopped, which says nothing of the tests.
    func test_aCoverageRunEndedByASignal_givesNoCoverage() async {
        process.commandResult = { _ in
            CommandResult(status: 15, endedBySignal: true, output: "path/to/testResult.xcresult\n", errors: "")
        }

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(result, .failure(.endedBySignal(15)))
        XCTAssertNil(process.executableURL, "xccov ran")
    }

    // Follows "Gathering coverage failed: ".
    func test_aRelaunchedTestProcess_saysWhy() {
        let noTests = FailedTestLine.FailedTests(tests: [], total: 0, firstLine: nil)
        let twoTests = FailedTestLine.FailedTests(
            tests: [
                .init(name: "sFails()", location: "STests.swift:10:5"),
                .init(name: "-[ATests.ATests test_fails]", location: nil),
            ],
            total: 2,
            firstLine: nil
        )
        let relaunched = "and Xcode relaunched it without finishing the tests it was running, "
            + "so the code they would have run would read as never run"

        XCTAssertEqual(
            CoverageError.testProcessRelaunched("Swift Testing", failedTests: noTests).reason,
            "a test process crashed or was stopped with coverage on (Swift Testing), \(relaunched)"
        )
        XCTAssertEqual(
            CoverageError.testProcessRelaunched(
                "CTests.xctest, during -[CTests.CTests test_z_crash]",
                failedTests: twoTests
            ).reason,
            "a test process crashed or was stopped with coverage on "
                + "(CTests.xctest, during -[CTests.CTests test_z_crash]), \(relaunched); "
                + "tests that failed: sFails() at STests.swift:10:5, -[ATests.ATests test_fails]"
        )
    }

    // xcodebuild -showBuildSettings indents each setting and repeats them for every target. The folder above
    // `Build/Products` holds both the test bundles and `ProfileData`.
    func test_buildDirectory_isTheFolderAboveTheBuildDirSetting() async {
        process.stdoutToBeReturned = """
        Build settings for action test and target AppTests:
            ALWAYS_SEARCH_USER_PATHS = NO
            BUILD_DIR = /Users/me/My Projects/DerivedData/Build/Products
            CONFIGURATION_BUILD_DIR = /Users/me/My Projects/DerivedData/Build/Products/Debug

        Build settings for action test and target App:
            BUILD_DIR = /Users/me/My Projects/DerivedData/Build/Products
        """

        let result = await sut.buildDirectory(muterConfiguration)
        XCTAssertEqual(result, "/Users/me/My Projects/DerivedData/Build")
        XCTAssertEqual(process.arguments, ["-showBuildSettings"])
    }

    func test_buildDirectory_skipsSettingsWhoseNameEndsInBuildDir() async {
        process.stdoutToBeReturned = """
            CONFIGURATION_BUILD_DIR = /DerivedData/Build/Products/Debug
            BUILD_DIR = /DerivedData/Build/Products
        """

        let result = await sut.buildDirectory(muterConfiguration)
        XCTAssertEqual(result, "/DerivedData/Build")
    }

    // With `BUILD_DIR=…` among the arguments, xcodebuild first echoes it as given, before any target's block.
    func test_buildDirectory_skipsTheEchoOfTheCommandLineSettings() async {
        process.stdoutToBeReturned = """
        Build settings from command line:
            BUILD_DIR = $(SRCROOT)/out

        Build settings for action test and target App:
            BUILD_DIR = /proj/out/Products
        """

        let result = await sut.buildDirectory(muterConfiguration)
        XCTAssertEqual(result, "/proj/out")
    }

    // Xcode keeps a profile per run destination and leaves the others' in place. `find` lists them in no set order,
    // and a stale one reads every function added since as never run, so their mutants would be skipped.
    func test_testProfileData_isTheNewestProfile() async {
        process.stdoutToBeReturned = "/Build/ProfileData/OLD/Coverage.profdata\n"
            + "/Build/ProfileData/NEW/Coverage.profdata\n"
        process.stdoutToBeReturned = "/Build/ProfileData/NEW/Coverage.profdata\n"
            + "/Build/ProfileData/OLD/Coverage.profdata\n"

        let result = await sut.testProfileData(at: ["/Build"])
        XCTAssertEqual(result, "/Build/ProfileData/NEW/Coverage.profdata")
        XCTAssertEqual(process.executableURL?.path, "/bin/ls")
        XCTAssertEqual(
            process.arguments,
            ["-t", "/Build/ProfileData/OLD/Coverage.profdata", "/Build/ProfileData/NEW/Coverage.profdata"]
        )
    }

    func test_testProfileData_withOneProfile_isThatProfile() async {
        process.stdoutToBeReturned = "/Build/ProfileData/MAC/Coverage.profdata\n"

        let result = await sut.testProfileData(at: ["/Build"])
        XCTAssertEqual(result, "/Build/ProfileData/MAC/Coverage.profdata")
        XCTAssertEqual(process.executableURL?.path, "/usr/bin/find")
    }

    func test_buildDirectory_isNilWithoutTheSetting() async {
        process.stdoutToBeReturned = "    SYMROOT = /DerivedData/Build/Products"

        let result = await sut.buildDirectory(muterConfiguration)
        XCTAssertNil(result)
    }
}
