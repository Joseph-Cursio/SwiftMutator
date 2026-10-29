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

    func test_whenUsesSupportedBuildSystem_shouldRunWithCoverage() async {
        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun, [
            [
                "/path/to/xcodebuild",
                "OTHER_SWIFT_FLAGS=$(inherited) -Xllvm -instrprof-atomic-counter-update-all", "-enableCodeCoverage", "YES",
            ],
        ])
        XCTAssertEqual(process.timeLimits, [nil])
    }

    func test_whenRunWithCoverageSucceeds_thenRunXcovCommand() async {
        answerTheCoverageRun(printing: "something\nsomething\npath/to/testResult.xcresult")
        process.stdoutToBeReturned = "/path/to/xcrun"

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.executableURL?.path, "/path/to/xcrun")
        XCTAssertEqual(
            process.arguments,
            ["xccov", "view", "--report", "--json", "path/to/testResult.xcresult"]
        )
    }

    // Files are named by their path in the project, the working directory, as SwiftPM's coverage names them.
    func test_whenXcovSucceeds_thenReturnFilsWithoutCoverage() async throws {
        answerTheCoverageRun(printing: "something\nsomething\npath/to/testResult.xcresult")
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = coverageData
        fileManager.currentDirectoryPathToReturn = "/project"

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(
            coverage,
            .make(
                percent: 10,
                filesWithoutCoverage: ["Sources/file1.swift"]
            )
        )
    }

    // A percentage, as SwiftPM's is: xccov's share of a file's lines, from 0 to 1, was compared with it, so any
    // threshold of 1 or more left out every file.
    func test_theCoverageThreshold_isAPercentage() async throws {
        answerTheCoverageRun(printing: "something\nsomething\npath/to/testResult.xcresult")
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = coverageData
        fileManager.currentDirectoryPathToReturn = "/project"

        coverageThreshold = 10

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(
            coverage,
            .make(
                percent: 10,
                filesWithoutCoverage: [
                    "Sources/file1.swift",
                    "Sources/file2.swift",
                ]
            )
        )
    }

    func test_anUnreadableReport_givesNoCoverage() async {
        answerTheCoverageRun(printing: "path/to/testResult.xcresult\n")
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = "not json"

        let result = await sut.run(with: muterConfiguration)
        XCTAssertEqual(result, .failure(.build))
    }

    func test_whenXcodeSelectFails_shouldNotRunXccov() async {
        answerTheCoverageRun(printing: "something\nsomething\npath/to/testResult.xcresult")
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = ""

        _ = await sut.run(with: muterConfiguration)

        XCTAssertFalse(
            process.executableURL?.path.contains("xccov")
        )
    }

    // Killed at `buildTimeout`, the run gives no coverage, even if it had printed where its result bundle is. What it
    // printed is kept.
    func test_aCoverageRunPastItsTimeLimit_givesNoCoverage() async {
        answerTheCoverageRun(printing: "path/to/testResult.xcresult\n", status: 9, timedOut: true)
        let limited = MuterConfiguration(executable: "/path/to/xcodebuild", arguments: [], buildTimeout: 900)

        let result = await sut.run(with: limited)
        XCTAssertEqual(result, .failure(.timedOut(after: 900)))
        XCTAssertEqual(process.timeLimits, [900])
        XCTAssertNil(process.executableURL, "xccov ran")
        XCTAssertEqual(sut.coverageRunOutput, "path/to/testResult.xcresult\n")
    }

    // What the run printed is kept in the run's log folder, as SwiftPM's is, standard error from a line of its own.
    func test_theCoverageRunsOutput_isKept_standardOutputThenStandardError() async {
        XCTAssertNil(sut.coverageRunOutput)
        process.commandResult = { _ in
            CommandResult(
                status: 65,
                endedBySignal: false,
                output: "Testing started",
                errors: "Failing tests:\n\tsFails()\n"
            )
        }

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(sut.coverageRunOutput, "Testing started\nFailing tests:\n\tsFails()\n")
    }

    // MARK: - Failed and crashed tests

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
        let noTests = FailedTestLine.FailedTests(tests: [], count: 0, firstLine: nil)
        let twoTests = FailedTestLine.FailedTests(
            tests: [
                .init(name: "sFails()", location: "STests.swift:10:5"),
                .init(name: "-[ATests.ATests test_fails]", location: nil),
            ],
            count: 2,
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
        process.stdoutToBeReturned = "/Build/ProfileData/OLD/Coverage.profdata\n/Build/ProfileData/NEW/Coverage.profdata\n"
        process.stdoutToBeReturned = "/Build/ProfileData/NEW/Coverage.profdata\n/Build/ProfileData/OLD/Coverage.profdata\n"

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

    // MARK: - Regions

    // xccov's report has no regions, so which code no test ran comes from llvm-cov's export.
    func test_functionCoverage() async throws {
        answerWithACoverageRun(report: Data(coverageData.utf8), existing: [true, false, false])

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(
            coverage.functionsCoverage.regionsForFile("/path/to/file.swift"), [
                .make(
                    lineStart: 14,
                    columnStart: 80,
                    lineEnd: 24,
                    columnEnd: 4,
                    executionCount: 0
                ),
            ]
        )
        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export",
            "/DerivedData/Build/Products/Debug/Project.framework/Versions/A/Project",
            "-instr-profile", profile,
        ])
    }

    // Hosted tests and UI tests run the app's code, which only the app's binary maps, and each test bundle maps only
    // the code linked into it. So one export reads every product the run built: the first by name, then each other as
    // an object.
    func test_everyProductTheRunBuilt_isExported_inOneCall() async {
        answerWithACoverageRun(report: appReport, existing: [true, false, true, false, true, false])

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.count, 2)
        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export",
            app, "-object", appTests, "-object", appUITests,
            "-instr-profile", profile,
        ])
    }

    // In a Debug build, an app's executable only loads `<App>.debug.dylib`, which holds the app's code.
    func test_anAppsDebugDylib_isExported_afterTheApp() async {
        answerWithACoverageRun(report: appReport, existing: [true, true, true, false, true, false])

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last?.dropFirst(3).prefix(5), [
            app, "-object", app + ".debug.dylib", "-object", appTests,
        ])
        XCTAssertEqual(fileManager.fileExistsAtPath, [
            app, app + ".debug.dylib", appTests, appTests + ".debug.dylib", appUITests, appUITests + ".debug.dylib",
        ])
    }

    // xccov lists a package's library as a framework that isn't built when the library is linked into its tests, and
    // llvm-cov fails on a file that doesn't exist.
    func test_aProductThatDoesntExist_isLeftOut() async {
        let library = debug + "/PackageFrameworks/Core_3124CAE0_PackageProduct.framework/Core_3124CAE0_PackageProduct"
        let tests = debug + "/CoreTests.xctest/Contents/MacOS/CoreTests"
        answerWithACoverageRun(
            report: report(
                target(
                    "Core",
                    buildProductPath: library,
                    files: [file("/project/Core/Parser.swift", executable: 4, covered: 2)]
                ),
                target("CoreTests", buildProductPath: tests, files: [])
            ),
            existing: [false, true, false]
        )

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export", tests, "-instr-profile", profile,
        ])
        XCTAssertEqual(fileManager.fileExistsAtPath, [library, tests, tests + ".debug.dylib"])
    }

    // Without regions, xccov's lines still say which files no test ran: when llvm-cov fails, or no product it lists
    // exists.
    func test_withoutRegions_xccovsCoverageIsStillGiven() async throws {
        let xccovs = Coverage.make(percent: 10, filesWithoutCoverage: ["Sources/file1.swift"])
        answerWithACoverageRun(
            report: Data(coverageData.utf8),
            existing: [true, false, false],
            export: { _ in self.result(status: 1, errors: "error: failed to load coverage: 'Project': No such file\n") }
        )

        let whenLLVMCovFails = try await sut.run(with: muterConfiguration).get()
        XCTAssertEqual(whenLLVMCovFails, xccovs)
        XCTAssertEqual(process.commandsRun.last?.prefix(3), ["/usr/bin/xcrun", "llvm-cov", "export"])

        answerWithACoverageRun(report: Data(coverageData.utf8), existing: [false, false])

        let withoutAProduct = try await sut.run(with: muterConfiguration).get()
        XCTAssertEqual(withoutAProduct, xccovs)
        XCTAssertEqual(process.commandsRun.count, 3, "llvm-cov ran without a product")
    }

    // A build for every architecture, as `ONLY_ACTIVE_ARCH=NO` makes, gives universal binaries, which llvm-cov reads
    // only for an architecture named, as in this real export, where it warned first. This Mac's is named then, not
    // from the start: llvm-cov would then fail for a binary built only for another, as for an Intel Mac's destination.
    func test_aUniversalBinary_isReadForThisMacsArchitecture() async throws {
        let sut = XcodeBuildCoverage(architecture: "arm64")
        let universal = result(status: 1, errors: """
        warning: App: profile data may be out of date - object is newer
        error: failed to load coverage: 'App.debug.dylib': `-arch` specifier is invalid or missing for universal binary
        error: could not load coverage information

        """)
        answerWithACoverageRun(report: appReport, existing: [true, true, false, false]) { command in
            command.contains("-arch") ? self.result(output: self.loadFixture("llvmCovExport.json")) : universal
        }

        let coverage = try await sut.run(with: muterConfiguration).get()

        let export = [
            "/usr/bin/xcrun", "llvm-cov", "export", app, "-object", app + ".debug.dylib", "-instr-profile", profile,
        ]
        XCTAssertEqual(process.commandsRun.suffix(2), [export, export + ["-arch", "arm64"]])
        XCTAssertEqual(coverage.functionsCoverage.regionsForFile("/path/to/file.swift").count, 1)
    }

    // Why llvm-cov failed is the first line that says so, not a warning before it.
    func test_whyLLVMCovFailed_isItsFirstError() async {
        process.commandResult = { _ in
            self.result(
                status: 1,
                errors: "warning: 2 functions have mismatched data\nerror: malformed coverage data\n"
            )
        }

        let result = await sut.llvmCovExport(of: [app], profile: profile, llvmCov: ("/usr/bin/xcrun", ["llvm-cov"]))
        XCTAssertEqual(
            result,
            .failure(.llvmCovFailed("error: malformed coverage data"))
        )
    }

    // MARK: - Reading the report

    // A file exactly at the threshold has no coverage, as on SwiftPM.
    func test_filesAtOrBelowTheThreshold_haveNoCoverage() throws {
        let coverage = try XcodeBuildCoverage.coverage(
            fromReport: report(target("App.app", files: [
                file("/project/A.swift", executable: 4, covered: 1),
                file("/project/B.swift", executable: 4, covered: 2),
                file("/project/C.swift", executable: 4, covered: 3),
            ])),
            projectRoot: "/project",
            coverageThreshold: 50
        ).get()

        XCTAssertEqual(coverage.filesWithoutCoverage, ["A.swift", "B.swift"])
        XCTAssertEqual(coverage.percent, 50)
    }

    // xccov's share of 7 of 100 lines, 0.07, times 100 is just above 7.
    func test_aFileExactlyAtTheThreshold_hasNoCoverage_whateverItsShareRoundsTo() throws {
        let coverage = try XcodeBuildCoverage.coverage(
            fromReport: report(target("App.app", files: [file("/project/A.swift", executable: 100, covered: 7)])),
            projectRoot: "/project",
            coverageThreshold: 7
        ).get()

        XCTAssertEqual(coverage.filesWithoutCoverage, ["A.swift"])
    }

    // The project's percentage counts the lines of every target but the tests, where it was the first target's.
    func test_thePercent_countsTheLinesOfEveryTarget() throws {
        let coverage = try XcodeBuildCoverage.coverage(
            fromReport: report(
                target("App.app", files: [file("/project/App/AppModel.swift", executable: 10, covered: 1)]),
                target(
                    "Core",
                    buildProductPath: "/derived/Build/Products/Debug/PackageFrameworks/"
                        + "Core_3124CAE0_PackageProduct.framework/Core_3124CAE0_PackageProduct",
                    files: [file("/project/Core/Sources/Core/Parser.swift", executable: 30, covered: 29)]
                )
            ),
            projectRoot: "/project",
            coverageThreshold: 0
        ).get()

        XCTAssertEqual(coverage.percent, 75)
    }

    // 29 of 100 lines is 29%, where xccov's share, 0.29, times 100 is just under 29.
    func test_thePercent_isWorkedOutFromTheLineCounts() throws {
        let coverage = try XcodeBuildCoverage.coverage(
            fromReport: report(target("App.app", files: [file("/project/A.swift", executable: 100, covered: 29)])),
            projectRoot: "/project",
            coverageThreshold: 0
        ).get()

        XCTAssertEqual(coverage.percent, 29)
    }

    // Only the project's own files count, by their path in it, as on SwiftPM: not those of a package it depends on,
    // checked out under DerivedData, nor one Xcode generates there.
    func test_onlyTheProjectsOwnFiles_count() throws {
        let coverage = try XcodeBuildCoverage.coverage(
            fromReport: report(
                target("App.app", files: [
                    file("/project/App/AppModel.swift", executable: 10, covered: 9),
                    file("/project/App/Untested.swift", executable: 10, covered: 0),
                    file(
                        "/derived/Build/Intermediates.noindex/App.build/Debug/App.build/DerivedSources/"
                            + "GeneratedAssetSymbols.swift",
                        executable: 40,
                        covered: 0
                    ),
                ]),
                target(
                    "ViewInspector",
                    buildProductPath: "/derived/Build/Products/Debug/PackageFrameworks/"
                        + "ViewInspector_4E6CD4C8_PackageProduct.framework/ViewInspector_4E6CD4C8_PackageProduct",
                    files: [
                        file(
                            "/derived/SourcePackages/checkouts/ViewInspector/Sources/ViewInspector/Inspector.swift",
                            executable: 100,
                            covered: 0
                        ),
                    ]
                )
            ),
            projectRoot: "/project",
            coverageThreshold: 0
        ).get()

        XCTAssertEqual(coverage.percent, 45)
        XCTAssertEqual(coverage.filesWithoutCoverage, ["App/Untested.swift"])
    }

    // `-derivedDataPath` can put the derived data in the project, with the packages the project depends on and the
    // files the build generates. They are still the build's: its products' paths show where it is.
    func test_filesInTheDerivedData_areLeftOut_evenInTheProject() throws {
        let derivedData = "/project/DerivedData"
        let coverage = try XcodeBuildCoverage.coverage(
            fromReport: report(
                target(
                    "App.app",
                    buildProductPath: derivedData + "/Build/Products/Debug/App.app/Contents/MacOS/App",
                    files: [
                        file("/project/App/AppModel.swift", executable: 10, covered: 9),
                        file(
                            derivedData + "/Build/Intermediates.noindex/App.build/Debug/App.build/DerivedSources/"
                                + "GeneratedAssetSymbols.swift",
                            executable: 40,
                            covered: 0
                        ),
                    ]
                ),
                target(
                    "ViewInspector",
                    buildProductPath: derivedData + "/Build/Products/Debug/PackageFrameworks/"
                        + "ViewInspector_4E6CD4C8_PackageProduct.framework/ViewInspector_4E6CD4C8_PackageProduct",
                    files: [
                        file(
                            derivedData + "/SourcePackages/checkouts/ViewInspector/Sources/ViewInspector/"
                                + "Inspector.swift",
                            executable: 100,
                            covered: 0
                        ),
                    ]
                )
            ),
            projectRoot: "/project",
            coverageThreshold: 0
        ).get()

        XCTAssertEqual(coverage.percent, 90)
        XCTAssertEqual(coverage.filesWithoutCoverage, [])
    }

    // A test target's product is a `.xctest` bundle. xcodebuild names a package's test target without the `.xctest`,
    // so only its product shows it is one.
    func test_testTargets_areLeftOut_byTheirName_orTheirProduct() throws {
        let coverage = try XcodeBuildCoverage.coverage(
            fromReport: report(
                target("App.app", files: [file("/project/App/AppModel.swift", executable: 4, covered: 2)]),
                target("AppTests.xctest", files: [file("/project/Support/Stubs.swift", executable: 6, covered: 0)]),
                target(
                    "CoreTests",
                    buildProductPath: "/derived/Build/Products/Debug/CoreTests.xctest/Contents/MacOS/CoreTests",
                    files: [file("/project/Support/Fixtures.swift", executable: 6, covered: 0)]
                )
            ),
            projectRoot: "/project",
            coverageThreshold: 0
        ).get()

        XCTAssertEqual(coverage.percent, 50)
        XCTAssertEqual(coverage.filesWithoutCoverage, [])
    }

    // A file built into two targets, such as an app and its extension, counts once, and has coverage if the tests ran
    // it in either.
    func test_aFileInSeveralTargets_countsOnce_asFarAsTheTestsRanIt() throws {
        let coverage = try XcodeBuildCoverage.coverage(
            fromReport: report(
                target("App.app", files: [file("/project/Shared/Store.swift", executable: 10, covered: 8)]),
                target("Widget.appex", files: [
                    file("/project/Shared/Store.swift", executable: 10, covered: 0),
                    file("/project/Widget/Widget.swift", executable: 10, covered: 0),
                ])
            ),
            projectRoot: "/project",
            coverageThreshold: 0
        ).get()

        XCTAssertEqual(coverage.percent, 40)
        XCTAssertEqual(coverage.filesWithoutCoverage, ["Widget/Widget.swift"])
    }

    // A file with no lines to run has nothing to mutate, so it never lacks coverage.
    func test_aFileWithNoLinesToRun_isNeverWithoutCoverage() throws {
        let coverage = try XcodeBuildCoverage.coverage(
            fromReport: report(
                target("App.app", files: [file("/project/Declarations.swift", executable: 0, covered: 0)])
            ),
            projectRoot: "/project",
            coverageThreshold: 0
        ).get()

        XCTAssertEqual(coverage.percent, 0)
        XCTAssertEqual(coverage.filesWithoutCoverage, [])
    }

    // SwiftMutator's working directory, from `getcwd()`, has every link resolved, but xcodebuild names the files of a
    // project in `/private/tmp` by `/tmp`.
    func test_aFileNamedThroughASymbolicLink_isTheProjects() throws {
        let (directory, link) = try makeDirectoryWithSymbolicLink()
        FileManager.default.createFile(atPath: directory + "/A.swift", contents: nil)

        let coverage = try XcodeBuildCoverage.coverage(
            fromReport: report(target("App.app", files: [file(link + "/A.swift", executable: 2, covered: 0)])),
            projectRoot: directory.canonicalPath,
            coverageThreshold: 0
        ).get()

        XCTAssertEqual(coverage.filesWithoutCoverage, ["A.swift"])
    }

    func test_anUnreadableReport_fails() {
        let report = Data("not json".utf8)

        XCTAssertEqual(
            failure(of: XcodeBuildCoverage.coverage(fromReport: report, projectRoot: "/project", coverageThreshold: 0)),
            .build
        )
    }

    // xccov's report of a package tested through xcodebuild lists only its tests' files, as in this real run's, so its
    // lines say nothing of the project's coverage: rather than 0%, there is none, and `run` reads llvm-cov's export.
    func test_aReportOfNoneOfTheProjectsFiles_givesNoLines() {
        let lines = XcodeBuildCoverage.coverage(fromReport: packageReport, projectRoot: "/project", coverageThreshold: 0)

        XCTAssertEqual(failure(of: lines), .noProjectFilesInXccovReport)
        XCTAssertEqual(
            CoverageError.noProjectFilesInXccovReport.reason,
            "xccov's report covers none of the project's source files"
        )
    }

    // MARK: - A Swift package

    // xccov lists a package's library with no files, and its tests with only theirs, though their bundle holds the
    // library's code. So the files, lines and regions all come from llvm-cov's export of that bundle, as on SwiftPM, in
    // this real run's, where `neverCalled()` and the files `Untested.swift` and `Other.swift` never ran. The library
    // has no binary of its own, and `-showBuildSettings` prints nothing for a package's scheme.
    func test_aPackage_getsItsCoverage_fromLLVMCovsExportOfItsTests() async throws {
        answerWithACoverageRun(report: packageReport, existing: [false, true, false], buildSettings: "") { _ in
            self.result(output: self.loadFixture("llvmCovExport_xcodebuildPackage.json"))
        }

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(coverage.percent, 20)
        XCTAssertEqual(coverage.filesWithoutCoverage, ["Sources/Calc/Untested.swift", "Sources/Other/Other.swift"])
        let neverRun = coverage.functionsCoverage.regionsForFile("/project/Sources/Calc/Calc.swift")
        XCTAssertEqual(neverRun.map { [$0.lineStart, $0.lineEnd] }, [[5, 10], [6, 6], [6, 8], [8, 9]])
        XCTAssertNil(coverage.testsFailedWithCoverageOn)
        XCTAssertEqual(process.commandsRun.filter { $0.contains("llvm-cov") }, [
            ["/usr/bin/xcrun", "llvm-cov", "export", packageTests, "-instr-profile", profile],
        ])
        XCTAssertEqual(profilesLookedFor, ["/DerivedData/Build"])
    }

    // Xcode builds the products of a package whose folder isn't named after it, as SwiftMutator's copy of a project
    // isn't, in derived data named after the folder, and keeps the result bundle and the profile in derived data named
    // after the package, with the same hash, as in this real run.
    func test_aPackagesProfile_isInTheDerivedDataOfItsResultBundle_notOfItsProducts() async throws {
        let products = "/DerivedData/PkgProbe_mutated-heuxeczqnwuysrfhawjcixylzvcq/Build/Products/Debug"
        let packageProfile = "/DerivedData/PkgProbe-heuxeczqnwuysrfhawjcixylzvcq/Build/ProfileData/MAC/"
            + "Coverage.profdata"
        answerWithACoverageRun(
            report: packageReport(in: products),
            existing: [false, true, false],
            log: "/DerivedData/PkgProbe-heuxeczqnwuysrfhawjcixylzvcq/Logs/Test/Test-PkgProbe.xcresult\n",
            buildSettings: "",
            profiles: [packageProfile + "\n", ""]
        ) { _ in
            self.result(output: self.loadFixture("llvmCovExport_xcodebuildPackage.json"))
        }

        let result = try await sut.run(with: muterConfiguration).get().percent
        XCTAssertEqual(result, 20)
        XCTAssertEqual(profilesLookedFor, [
            "/DerivedData/PkgProbe-heuxeczqnwuysrfhawjcixylzvcq/Build",
            "/DerivedData/PkgProbe_mutated-heuxeczqnwuysrfhawjcixylzvcq/Build",
        ])
        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export",
            products + "/CalcTests.xctest/Contents/MacOS/CalcTests",
            "-instr-profile", packageProfile,
        ])
    }

    // `-resultBundlePath` moves the result bundle out of the derived data, and `SYMROOT` or `BUILD_DIR` the products,
    // but neither moves the profile.
    func test_theDerivedData_isFoundFromEitherTheResultBundle_orTheProducts() async {
        answerWithACoverageRun(
            report: packageReport,
            existing: [false, true, false],
            log: "/out/Coverage.xcresult\n",
            buildSettings: ""
        )

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(profilesLookedFor, ["/DerivedData/Build"])

        answerWithACoverageRun(
            report: packageReport(in: "/project/sym/Debug"),
            existing: [false, true, false],
            buildSettings: ""
        )

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(profilesLookedFor.last, "/DerivedData/Build")
        XCTAssertEqual(profilesLookedFor.count, 2)
    }

    // With both moved, only `-showBuildSettings` can say where the build is, and for a package's scheme it says
    // nothing.
    func test_withNeitherInTheDerivedData_theProfile_isLookedForAboveBuildDir_ifThereIsOne() async throws {
        let packageReport = packageReport(in: "/project/out/Debug")
        let testsExport: (([String]) -> CommandResult?) = { _ in
            self.result(output: self.loadFixture("llvmCovExport_xcodebuildPackage.json"))
        }
        answerWithACoverageRun(
            report: packageReport,
            existing: [false, true, false],
            log: "/out/Coverage.xcresult\n",
            buildSettings: "Build settings for action test and target CalcTests:\n    BUILD_DIR = /project/out\n",
            profiles: ["/project/ProfileData/MAC/Coverage.profdata\n"],
            export: testsExport
        )

        let percent = try await sut.run(with: muterConfiguration).get().percent
        XCTAssertEqual(percent, 20)
        XCTAssertEqual(profilesLookedFor, ["/project"])

        answerWithACoverageRun(
            report: packageReport,
            existing: [false, true, false],
            log: "/out/Coverage.xcresult\n",
            buildSettings: "",
            profiles: [],
            export: testsExport
        )

        let withoutBuildDir = await sut.run(with: muterConfiguration)
        XCTAssertEqual(withoutBuildDir, .failure(.noXcodeBuildFolder))
        XCTAssertEqual(process.arguments, ["-showBuildSettings"])
        XCTAssertEqual(process.commandsRun.filter { $0.contains("llvm-cov") }.count, 1, "llvm-cov ran without a build")
    }

    // With Xcode's Build Location set to Custom, relative to the workspace, as here, or to Shared Folder, the products
    // and the profile go with the build's intermediate files, and the result bundle stays in derived data, which can
    // hold the profile of a run from before the setting changed. The newest profile is the run's.
    func test_theNewestProfile_inAnyBuildFolder_isTheRuns() async {
        let fresh = "/project/Build/Intermediates.noindex/CodeCoverage/ProfileData/MAC/Coverage.profdata"
        let app = "/project/Build/Products/Debug/App.app/Contents/MacOS/App"
        answerWithACoverageRun(
            report: report(
                target(
                    "App.app",
                    buildProductPath: app,
                    files: [file("/project/App/Model.swift", executable: 4, covered: 2)]
                )
            ),
            existing: [true, false],
            buildSettings: "Build settings for action test and target App:\n    BUILD_DIR = /project/Build/Products\n",
            profiles: [profile + "\n", fresh + "\n", fresh + "\n" + profile + "\n"]
        )

        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(profilesLookedFor, ["/DerivedData/Build", "/project/Build"])
        XCTAssertEqual(process.arguments, ["-t", profile, fresh])
        XCTAssertEqual(process.commandsRun.last, ["/usr/bin/xcrun", "llvm-cov", "export", app, "-instr-profile", fresh])
    }

    // A package's test target can have a `path` of its own, outside a `Tests` folder, and xccov names its files. Nor do
    // the files in derived data count, which `-derivedDataPath` can put in the project: those of the packages it
    // depends on, which its tests' bundle holds too, and those the build generates.
    func test_aPackagesTestFiles_andDerivedData_areLeftOut_whereverTheyAre() async throws {
        let derivedData = "/project/DerivedData"
        let tests = derivedData + "/Build/Products/Debug/CalcSpecs.xctest/Contents/MacOS/CalcSpecs"
        answerWithACoverageRun(
            report: report(
                target(
                    "CalcSpecs",
                    buildProductPath: tests,
                    files: [file("/project/Specs/CalcSpecs.swift", executable: 10, covered: 10)]
                )
            ),
            existing: [true, false],
            log: derivedData + "/Logs/Test/Test-PkgProbe.xcresult\n",
            buildSettings: "",
            profiles: [derivedData + "/Build/ProfileData/MAC/Coverage.profdata\n"]
        ) { _ in
            self.result(output: String(decoding: self.export(files: [
                self.exportedFile("/project/Sources/Calc/Calc.swift", count: 4, covered: 2),
                self.exportedFile("/project/Specs/CalcSpecs.swift", count: 10, covered: 10),
                self.exportedFile(
                    derivedData + "/SourcePackages/checkouts/Dep/Sources/Dep/Dep.swift",
                    count: 8,
                    covered: 0
                ),
                self.exportedFile(
                    derivedData + "/Build/Intermediates.noindex/Calc.build/Debug/Calc.build/DerivedSources/"
                        + "resource_bundle_accessor.swift",
                    count: 5,
                    covered: 0
                ),
            ]), as: UTF8.self))
        }

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(coverage.percent, 50)
        XCTAssertEqual(coverage.filesWithoutCoverage, [])
    }

    // The coverage of a run in which tests failed is kept, as an app's is, and they are named.
    func test_aPackagesFailedTests_keepItsCoverage_andAreNamed() async throws {
        answerWithACoverageRun(
            report: packageReport,
            existing: [false, true, false],
            log: loadFixture("TestLogsForParsing/coverageRun_xcodebuild_testFailed.log"),
            status: 65,
            buildSettings: ""
        ) { _ in
            self.result(output: self.loadFixture("llvmCovExport_xcodebuildPackage.json"))
        }

        let coverage = try await sut.run(with: muterConfiguration).get()

        XCTAssertEqual(coverage.percent, 20)
        XCTAssertEqual(
            coverage.testsFailedWithCoverageOn?.tests.map(\.name),
            ["sFails()", "-[ATests.ATests test_fails]"]
        )
    }

    // Without llvm-cov's export, a package has no coverage, as xccov's report says nothing of it, and the reason is
    // what kept the export from being had.
    func test_aPackageWhoseExportCantBeHad_givesNoCoverage_andSaysWhy() async {
        // Without a product, `find` never runs, and its answer is left for the next run, so that one comes last.
        typealias Export = ([String]) -> CommandResult?
        let runs: [(existing: [Bool], profiles: [String]?, export: Export?, error: CoverageError)] = [
            ([false, true, false], [""], nil, .noProfileData(atPath: "/DerivedData/Build")),
            ([false, true, false], nil, { _ in nil }, .couldNotRun("llvm-cov")),
            (
                [false, true, false],
                nil,
                { _ in self.result(status: 1, errors: "error: malformed coverage data\n") },
                .llvmCovFailed("error: malformed coverage data")
            ),
            ([false, true, false], nil, { _ in self.result(output: "not json") }, .unreadableReport),
            ([false, true, false], nil, nil, .noProjectFiles),
            ([false, false], nil, nil, .noBuiltProducts),
        ]

        for run in runs {
            answerWithACoverageRun(
                report: packageReport,
                existing: run.existing,
                buildSettings: "",
                profiles: run.profiles,
                export: run.export
            )

            let result = await sut.run(with: muterConfiguration)
            XCTAssertEqual(result, .failure(run.error))
        }
    }

    // Follow "Gathering coverage failed: ".
    func test_aPackagesOwnFailures_sayWhy() {
        XCTAssertEqual(
            CoverageError.noBuiltProducts.reason,
            "none of the products xccov says the coverage run built exists"
        )
        XCTAssertEqual(
            CoverageError.noXcodeBuildFolder.reason,
            "the coverage run's profile couldn't be found: its result bundle isn't in <DerivedData>/Logs/Test, "
                + "nor its products in <DerivedData>/Build/Products, "
                + "and xcodebuild -showBuildSettings gave no BUILD_DIR"
        )
        XCTAssertEqual(
            CoverageError.noProfileData(atPath: "/a/Build or /b/Build").reason,
            "there is no profile data at /a/Build or /b/Build"
        )
    }

    // MARK: - Helpers

    /// Answers the coverage run, which ends with `status`, or at its time limit, having printed `output`, and `errors`
    /// to standard error.
    private func answerTheCoverageRun(
        printing output: String,
        errors: String = "",
        status: Int32 = 0,
        timedOut: Bool = false
    ) {
        process.commandResult = { _ in
            CommandResult(status: status, endedBySignal: timedOut, output: output, errors: errors, timedOut: timedOut)
        }
    }

    /// What xcodebuild logs first to standard error on a Mac whose simulators are out of date, as in the real runs.
    private let simulatorsOutOfDate = """
    2026-10-23 08:28:48.639 xcodebuild[66861:8758778]  DVTErrorPresenter: Unable to load simulator devices.
    Domain: DVTCoreSimulatorAdditionsErrorDomain
    2026-10-23 08:28:48.639 xcodebuild[66861:8758778]  iOSSimulator: [SimServiceContext \
    sharedServiceContextForDeveloperDir:error:] returned nil (Error Domain=DVTCoreSimulatorAdditionsErrorDomain Code=3 \
    "CoreSimulator is out of date."). Simulator device support disabled.

    """

    /// Answers a coverage run that ended with `status` and printed `log`, which says where its result bundle is, with
    /// xccov's `report` of it, `buildSettings`, the folder above whose `BUILD_DIR` is by default `/DerivedData/Build`,
    /// what `find` lists in each build folder, then `ls -t` if it lists more than one profile, by default `profile`,
    /// and llvm-cov's export from `export`, given llvm-cov's command, or else from `llvmCovExport.json`. Each product
    /// `report` lists, and the `.debug.dylib` looked for beside each that exists, exists as `existing` says, in that
    /// order.
    private func answerWithACoverageRun(
        report: Data,
        existing: [Bool],
        log: String = "Testing started\n/DerivedData/Logs/Test/Test-App.xcresult\n",
        status: Int32 = 0,
        buildSettings: String = """
        Build settings for action test and target App:
            BUILD_DIR = /DerivedData/Build/Products

        """,
        profiles: [String]? = nil,
        export: (([String]) -> CommandResult?)? = nil
    ) {
        fileManager.currentDirectoryPathToReturn = "/project"
        fileManager.fileExistsToReturn = existing
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = String(decoding: report, as: UTF8.self)
        process.stdoutToBeReturned = buildSettings
        for found in profiles ?? [profile + "\n"] {
            process.stdoutToBeReturned = found
        }
        let exported = result(output: loadFixture("llvmCovExport.json"))
        process.commandResult = { command in
            command.contains("llvm-cov")
                ? export.map { $0(command) } ?? exported
                : self.result(status: status, output: log)
        }
    }

    /// The folders `find` looked for profiles in, in order.
    private var profilesLookedFor: [String] {
        process.processesRun.filter { $0.first == "/usr/bin/find" }.map { $0[1] }
    }

    private let debug = "/DerivedData/Build/Products/Debug"
    private let profile = "/DerivedData/Build/ProfileData/MAC/Coverage.profdata"
    private var app: String { debug + "/App.app/Contents/MacOS/App" }
    private var appTests: String { debug + "/App.app/Contents/PlugIns/AppTests.xctest/Contents/MacOS/AppTests" }
    private var appUITests: String {
        debug + "/AppUITests-Runner.app/Contents/PlugIns/AppUITests.xctest/Contents/MacOS/AppUITests"
    }

    /// xccov's report of an app, with unit tests hosted in it and UI tests in a runner of their own.
    private var appReport: Data {
        report(
            target(
                "App.app",
                buildProductPath: app,
                files: [file("/project/App/Model.swift", executable: 10, covered: 5)]
            ),
            target("AppTests.xctest", buildProductPath: appTests, files: []),
            target("AppUITests.xctest", buildProductPath: appUITests, files: [])
        )
    }

    private var packageTests: String { debug + "/CalcTests.xctest/Contents/MacOS/CalcTests" }

    /// xccov's report of a real run of a package's tests through xcodebuild: its library, `Calc`, as a framework that
    /// isn't built, with no files, and its tests with only theirs.
    private var packageReport: Data {
        packageReport(in: debug)
    }

    /// `packageReport`, with the products in `products`.
    private func packageReport(in products: String) -> Data {
        report(
            target(
                "Calc",
                buildProductPath: products
                    + "/PackageFrameworks/Calc_598848FE7_PackageProduct.framework/Calc_598848FE7_PackageProduct",
                files: []
            ),
            target(
                "CalcTests",
                buildProductPath: products + "/CalcTests.xctest/Contents/MacOS/CalcTests",
                files: [file("/project/Tests/CalcTests/CalcTests.swift", executable: 8, covered: 8)]
            )
        )
    }

    /// llvm-cov's JSON export of `files`, with no functions.
    private func export(files: [String]) -> Data {
        Data("""
        {"type": "llvm.coverage.json.export", "version": "3.0.1",
         "data": [{"files": [\(files.joined(separator: ","))], "functions": []}]}
        """.utf8)
    }

    /// A file of llvm-cov's export, of whose `count` lines the tests ran `covered`.
    private func exportedFile(_ path: String, count: Int, covered: Int) -> String {
        #"{"filename": "\#(path)", "summary": {"lines": {"count": \#(count), "covered": \#(covered)}}}"#
    }

    /// The error `result` failed with; nil if it didn't.
    private func failure(of result: Result<XcodeBuildCoverage.LineCoverage, CoverageError>) -> CoverageError? {
        guard case let .failure(error) = result else {
            return nil
        }
        return error
    }

    private func result(status: Int32 = 0, output: String = "", errors: String = "") -> CommandResult {
        CommandResult(status: status, endedBySignal: false, output: output, errors: errors)
    }

    /// xccov's JSON report of `targets`, without the counts it gives for the whole report and for each target.
    private func report(_ targets: String...) -> Data {
        Data(#"{"targets": [\#(targets.joined(separator: ","))]}"#.utf8)
    }

    /// A target of xccov's report, whose product is at `buildProductPath`.
    private func target(_ name: String, buildProductPath: String? = nil, files: [String]) -> String {
        let product = buildProductPath.map { #""buildProductPath": "\#($0)", "# } ?? ""
        return #"{\#(product)"files": [\#(files.joined(separator: ","))], "name": "\#(name)"}"#
    }

    /// A file of xccov's report, of whose `executable` lines the tests ran `covered`.
    private func file(_ path: String, executable: Int, covered: Int) -> String {
        let lineCoverage = executable > 0 ? Double(covered) / Double(executable) : 0
        return """
        {"coveredLines": \(covered), "executableLines": \(executable), "functions": [], \
        "lineCoverage": \(lineCoverage), "name": "\(URL(fileURLWithPath: path).lastPathComponent)", "path": "\(path)"}
        """
    }
}

/// xccov's report of a framework, whose three files the tests ran 0%, 10% and 20% of, and of its tests.
let coverageData =
    """
    {
      "coveredLines": 33,
      "executableLines": 60,
      "lineCoverage": 0.55000000000000004,
      "targets": [
        {
          "buildProductPath": "/DerivedData/Build/Products/Debug/Project.framework/Versions/A/Project",
          "coveredLines": 3,
          "executableLines": 30,
          "files": [
            {
              "coveredLines": 0,
              "executableLines": 10,
              "functions": [],
              "lineCoverage": 0,
              "name": "file1.swift",
              "path": "/project/Sources/file1.swift"
            },
            {
              "coveredLines": 1,
              "executableLines": 10,
              "functions": [],
              "lineCoverage": 0.10000000000000001,
              "name": "file2.swift",
              "path": "/project/Sources/file2.swift"
            },
            {
              "coveredLines": 2,
              "executableLines": 10,
              "functions": [],
              "lineCoverage": 0.20000000000000001,
              "name": "file3.swift",
              "path": "/project/Sources/file3.swift"
            }
          ],
          "lineCoverage": 0.10000000000000001,
          "name": "Project.framework"
        },
        {
          "buildProductPath": "/DerivedData/Build/Products/Debug/ProjectTests.xctest/Contents/MacOS/ProjectTests",
          "coveredLines": 30,
          "executableLines": 30,
          "files": [
            {
              "coveredLines": 30,
              "executableLines": 30,
              "functions": [],
              "lineCoverage": 1,
              "name": "ProjectSpec.swift",
              "path": "/project/ProjectSpecs/ProjectSpec.swift"
            }
          ],
          "lineCoverage": 1,
          "name": "ProjectTests.xctest"
        }
      ]
    }
    """
