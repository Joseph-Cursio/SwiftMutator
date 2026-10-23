@testable import muterCore
import TestingExtensions
import XCTest

final class XcodeBuildCoverageTests: MuterTestCase {
    private let sut = XcodeBuildCoverage()

    private var coverageThreshold: Double = 0
    private lazy var muterConfiguration = MuterConfiguration(
        executable: "/path/to/xcodebuild",
        arguments: [],
        coverageThreshold: coverageThreshold
    )

    func test_whenUsesSupportedBuildSystem_shouldRunWithCoverage() {
        _ = sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun, [
            [
                "/path/to/xcodebuild",
                "OTHER_SWIFT_FLAGS=$(inherited) -Xllvm -instrprof-atomic-counter-update-all", "-enableCodeCoverage", "YES",
            ],
        ])
        XCTAssertEqual(process.timeLimits, [nil])
    }

    func test_whenRunWithCoverageSucceeds_thenRunXcovCommand() {
        answerTheCoverageRun(printing: "something\nsomething\npath/to/testResult.xcresult")
        process.stdoutToBeReturned = "/path/to/xcrun"

        _ = sut.run(with: muterConfiguration)

        XCTAssertEqual(process.executableURL?.path, "/path/to/xcrun")
        XCTAssertEqual(
            process.arguments,
            ["xccov", "view", "--report", "--json", "path/to/testResult.xcresult"]
        )
    }

    func test_whenXcovSucceeds_thenReturnFilsWithoutCoverage() throws {
        answerTheCoverageRun(printing: "something\nsomething\npath/to/testResult.xcresult")
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = coverageData

        let coverage = try XCTUnwrap(sut.run(with: muterConfiguration).get())

        XCTAssertEqual(
            coverage,
            .make(
                percent: 81,
                filesWithoutCoverage: ["/path/to/file1.swift"]
            )
        )
    }

    func test_ignoreFilesLessThanCoverageThreshold() throws {
        answerTheCoverageRun(printing: "something\nsomething\npath/to/testResult.xcresult")
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = coverageData

        coverageThreshold = 10

        let coverage = try XCTUnwrap(sut.run(with: muterConfiguration).get())

        XCTAssertEqual(
            coverage,
            .make(
                percent: 81,
                filesWithoutCoverage: [
                    "/path/to/file1.swift",
                    "/path/to/file2.swift",
                    "/path/to/file3.swift",
                ]
            )
        )
    }

    func test_whenXcodeSelectFails_shouldNotRunXccov() {
        answerTheCoverageRun(printing: "something\nsomething\npath/to/testResult.xcresult")
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = ""

        _ = sut.run(with: muterConfiguration)

        XCTAssertFalse(
            process.executableURL?.path.contains("xccov")
        )
    }

    func test_whenBuildFailes_shouldNotExecuteXcodeSelect() {
        answerTheCoverageRun(printing: "", status: 65)

        XCTAssertEqual(sut.run(with: muterConfiguration), .failure(.build))
        XCTAssertNotEqual(process.executableURL?.path, "/usr/bin/xcode-select")
    }

    // xcodebuild prints the result bundle's path when a test fails too, and that bundle holds the coverage.
    func test_theResultBundle_isRead_whateverTheCoverageRunsExitStatus() {
        answerTheCoverageRun(printing: "Testing failed:\npath/to/testResult.xcresult\n", status: 65)
        process.stdoutToBeReturned = "/path/to/xcrun"

        _ = sut.run(with: muterConfiguration)

        XCTAssertEqual(process.arguments, ["xccov", "view", "--report", "--json", "path/to/testResult.xcresult"])
    }

    // Killed at `buildTimeout`, the run gives no coverage, even if it had printed where its result bundle is.
    func test_aCoverageRunPastItsTimeLimit_givesNoCoverage() {
        answerTheCoverageRun(printing: "path/to/testResult.xcresult\n", status: 9, timedOut: true)
        let limited = MuterConfiguration(executable: "/path/to/xcodebuild", arguments: [], buildTimeout: 900)

        XCTAssertEqual(sut.run(with: limited), .failure(.timedOut(after: 900)))
        XCTAssertEqual(process.timeLimits, [900])
        XCTAssertNil(process.executableURL, "xccov ran")
    }

    // xcodebuild -showBuildSettings indents each setting and repeats them for every target. The folder above
    // `Build/Products` holds both the test bundles and `ProfileData`.
    func test_buildDirectory_isTheFolderAboveTheBuildDirSetting() {
        process.stdoutToBeReturned = """
        Build settings for action test and target AppTests:
            ALWAYS_SEARCH_USER_PATHS = NO
            BUILD_DIR = /Users/me/My Projects/DerivedData/Build/Products
            CONFIGURATION_BUILD_DIR = /Users/me/My Projects/DerivedData/Build/Products/Debug

        Build settings for action test and target App:
            BUILD_DIR = /Users/me/My Projects/DerivedData/Build/Products
        """

        XCTAssertEqual(sut.buildDirectory(muterConfiguration), "/Users/me/My Projects/DerivedData/Build")
        XCTAssertEqual(process.arguments, ["-showBuildSettings"])
    }

    func test_buildDirectory_skipsSettingsWhoseNameEndsInBuildDir() {
        process.stdoutToBeReturned = """
            CONFIGURATION_BUILD_DIR = /DerivedData/Build/Products/Debug
            BUILD_DIR = /DerivedData/Build/Products
        """

        XCTAssertEqual(sut.buildDirectory(muterConfiguration), "/DerivedData/Build")
    }

    // With `BUILD_DIR=…` among the arguments, xcodebuild first echoes it as given, before any target's block.
    func test_buildDirectory_skipsTheEchoOfTheCommandLineSettings() {
        process.stdoutToBeReturned = """
        Build settings from command line:
            BUILD_DIR = $(SRCROOT)/out

        Build settings for action test and target App:
            BUILD_DIR = /proj/out/Products
        """

        XCTAssertEqual(sut.buildDirectory(muterConfiguration), "/proj/out")
    }

    // Xcode keeps a profile per run destination and leaves the others' in place. `find` lists them in no set order,
    // and a stale one reads every function added since as never run, so their mutants would be skipped.
    func test_testProfileData_isTheNewestProfile() {
        process.stdoutToBeReturned = "/Build/ProfileData/OLD/Coverage.profdata\n/Build/ProfileData/NEW/Coverage.profdata\n"
        process.stdoutToBeReturned = "/Build/ProfileData/NEW/Coverage.profdata\n/Build/ProfileData/OLD/Coverage.profdata\n"

        XCTAssertEqual(sut.testProfileData(at: "/Build"), "/Build/ProfileData/NEW/Coverage.profdata")
        XCTAssertEqual(process.executableURL?.path, "/bin/ls")
        XCTAssertEqual(
            process.arguments,
            ["-t", "/Build/ProfileData/OLD/Coverage.profdata", "/Build/ProfileData/NEW/Coverage.profdata"]
        )
    }

    func test_testProfileData_withOneProfile_isThatProfile() {
        process.stdoutToBeReturned = "/Build/ProfileData/MAC/Coverage.profdata\n"

        XCTAssertEqual(sut.testProfileData(at: "/Build"), "/Build/ProfileData/MAC/Coverage.profdata")
        XCTAssertEqual(process.executableURL?.path, "/usr/bin/find")
    }

    func test_buildDirectory_isNilWithoutTheSetting() {
        process.stdoutToBeReturned = "    SYMROOT = /DerivedData/Build/Products"

        XCTAssertNil(sut.buildDirectory(muterConfiguration))
    }

    func test_functionCoverage() throws {
        process.stdoutToBeReturned = "BUILD_DIR = /build/directory"
        process.stdoutToBeReturned = "/path/to/testExecutable.xctest"
        process.stdoutToBeReturned = "/path/to/testBinary"
        process.stdoutToBeReturned = "/path/to/coverage.profdata"
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = loadFixture("llvmCovExport.json")

        let functionsCoverage = sut.functionsCoverage(muterConfiguration)

        XCTAssertEqual(
            functionsCoverage.regionsForFile("/path/to/file.swift"), [
                .make(
                    lineStart: 14,
                    columnStart: 80,
                    lineEnd: 24,
                    columnEnd: 4,
                    executionCount: 0
                ),
            ]
        )
    }

    // MARK: - Helpers

    /// Answers the coverage run, which ends with `status`, or at its time limit, having printed `output`.
    private func answerTheCoverageRun(printing output: String, status: Int32 = 0, timedOut: Bool = false) {
        process.commandResult = { _ in
            CommandResult(status: status, endedBySignal: timedOut, output: output, errors: "", timedOut: timedOut)
        }
    }
}

let coverageData =
    """
    {
      "targets": [
        {
          "lineCoverage": 0.81051478641840091,
          "files": [
            {
              "lineCoverage": 0,
              "path": "/path/to/file1.swift"
            },
            {
              "lineCoverage": 0.10,
              "path": "/path/to/file2.swift"
            },
            {
              "lineCoverage": 0.20,
              "path": "/path/to/file3.swift"
            }
          ],
         "name": "Project.framework"
        },
        {
          "lineCoverage": 0.86051478641840091,
          "files": [
            {
              "lineCoverage": 0,
              "path": "/path/to/file4.swift"
            },
            {
              "lineCoverage": 0.10,
              "path": "/path/to/file5.swift"
            },
            {
              "lineCoverage": 0.20,
              "path": "/path/to/file6.swift"
            }
          ],
         "name": "Project-OSXTests.xctest"
        }
      ]
    }
    """
