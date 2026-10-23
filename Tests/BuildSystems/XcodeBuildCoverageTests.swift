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

    // Files are named by their path in the project, the working directory, as SwiftPM's coverage names them.
    func test_whenXcovSucceeds_thenReturnFilsWithoutCoverage() throws {
        answerTheCoverageRun(printing: "something\nsomething\npath/to/testResult.xcresult")
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = coverageData
        fileManager.currentDirectoryPathToReturn = "/project"

        let coverage = try XCTUnwrap(sut.run(with: muterConfiguration).get())

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
    func test_theCoverageThreshold_isAPercentage() throws {
        answerTheCoverageRun(printing: "something\nsomething\npath/to/testResult.xcresult")
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = coverageData
        fileManager.currentDirectoryPathToReturn = "/project"

        coverageThreshold = 10

        let coverage = try XCTUnwrap(sut.run(with: muterConfiguration).get())

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

    func test_anUnreadableReport_givesNoCoverage() {
        answerTheCoverageRun(printing: "path/to/testResult.xcresult\n")
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = "not json"

        XCTAssertEqual(sut.run(with: muterConfiguration), .failure(.build))
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

    // Killed at `buildTimeout`, the run gives no coverage, even if it had printed where its result bundle is. What it
    // printed is kept.
    func test_aCoverageRunPastItsTimeLimit_givesNoCoverage() {
        answerTheCoverageRun(printing: "path/to/testResult.xcresult\n", status: 9, timedOut: true)
        let limited = MuterConfiguration(executable: "/path/to/xcodebuild", arguments: [], buildTimeout: 900)

        XCTAssertEqual(sut.run(with: limited), .failure(.timedOut(after: 900)))
        XCTAssertEqual(process.timeLimits, [900])
        XCTAssertNil(process.executableURL, "xccov ran")
        XCTAssertEqual(sut.coverageRunOutput, "path/to/testResult.xcresult\n")
    }

    // What the run printed is kept in the run's log folder, as SwiftPM's is, standard error from a line of its own.
    func test_theCoverageRunsOutput_isKept_standardOutputThenStandardError() {
        XCTAssertNil(sut.coverageRunOutput)
        process.commandResult = { _ in
            CommandResult(
                status: 65,
                endedBySignal: false,
                output: "Testing started",
                errors: "Failing tests:\n\tsFails()\n"
            )
        }

        _ = sut.run(with: muterConfiguration)

        XCTAssertEqual(sut.coverageRunOutput, "Testing started\nFailing tests:\n\tsFails()\n")
    }

    // MARK: - Failed and crashed tests

    // Every test process leaves what it counted in the result bundle, a failed test's too, so the coverage is kept, and
    // says which tests failed. In this real run, a Swift Testing test and an XCTest test failed.
    func test_failedTests_withoutACrash_keepTheCoverage_andAreNamed() throws {
        answerTheCoverageRun(
            printing: loadFixture("TestLogsForParsing/coverageRun_xcodebuild_testFailed.log"),
            status: 65
        )
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = coverageData
        fileManager.currentDirectoryPathToReturn = "/project"

        let coverage = try sut.run(with: muterConfiguration).get()

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
    func test_aCrashedTestProcess_givesNoCoverage_andIsNamed() {
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

            let result = sut.run(with: muterConfiguration)
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
    func test_aFailedRun_thatNamesNoFailedTest_givesNoCoverage() {
        answerTheCoverageRun(
            printing: loadFixture("TestLogsForParsing/coverageRun_xcodebuild_parallel_testCrashed.log"),
            errors: simulatorsOutOfDate + "Failing tests:\n\tCTests.test_z_crash()\n\n** TEST FAILED **\n",
            status: 65
        )
        XCTAssertEqual(sut.run(with: muterConfiguration), .failure(.runFailed(status: 65, error: nil)))

        answerTheCoverageRun(
            printing: "/project/App/Model.swift:3:9: error: cannot find 'x' in scope\n\n** TEST FAILED **\n",
            errors: simulatorsOutOfDate,
            status: 65
        )
        XCTAssertEqual(
            sut.run(with: muterConfiguration),
            .failure(.runFailed(status: 65, error: "/project/App/Model.swift:3:9: error: cannot find 'x' in scope"))
        )

        answerTheCoverageRun(
            printing: "",
            errors: simulatorsOutOfDate + "xcodebuild: error: Unknown build action 'tset'.\n",
            status: 64
        )
        XCTAssertEqual(
            sut.run(with: muterConfiguration),
            .failure(.runFailed(status: 64, error: "xcodebuild: error: Unknown build action 'tset'."))
        )

        answerTheCoverageRun(
            printing: "/project/App/Bridge.m:1:9: fatal error: 'Missing.h' file not found\n",
            errors: simulatorsOutOfDate,
            status: 65
        )
        XCTAssertEqual(
            sut.run(with: muterConfiguration),
            .failure(.runFailed(
                status: 65,
                error: "/project/App/Bridge.m:1:9: fatal error: 'Missing.h' file not found"
            ))
        )
        XCTAssertNil(process.executableURL, "xccov ran")
    }

    // xcodebuild itself was stopped, which says nothing of the tests.
    func test_aCoverageRunEndedByASignal_givesNoCoverage() {
        process.commandResult = { _ in
            CommandResult(status: 15, endedBySignal: true, output: "path/to/testResult.xcresult\n", errors: "")
        }

        XCTAssertEqual(sut.run(with: muterConfiguration), .failure(.endedBySignal(15)))
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

    // MARK: - Regions

    // xccov's report has no regions, so which code no test ran comes from llvm-cov's export.
    func test_functionCoverage() throws {
        answerWithACoverageRun(report: Data(coverageData.utf8), existing: [true, false, false])

        let coverage = try sut.run(with: muterConfiguration).get()

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
    func test_everyProductTheRunBuilt_isExported_inOneCall() {
        answerWithACoverageRun(report: appReport, existing: [true, false, true, false, true, false])

        _ = sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.count, 2)
        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export",
            app, "-object", appTests, "-object", appUITests,
            "-instr-profile", profile,
        ])
    }

    // In a Debug build, an app's executable only loads `<App>.debug.dylib`, which holds the app's code.
    func test_anAppsDebugDylib_isExported_afterTheApp() {
        answerWithACoverageRun(report: appReport, existing: [true, true, true, false, true, false])

        _ = sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last?.dropFirst(3).prefix(5), [
            app, "-object", app + ".debug.dylib", "-object", appTests,
        ])
        XCTAssertEqual(fileManager.fileExistsAtPath, [
            app, app + ".debug.dylib", appTests, appTests + ".debug.dylib", appUITests, appUITests + ".debug.dylib",
        ])
    }

    // xccov lists a package's library as a framework that isn't built when the library is linked into its tests, and
    // llvm-cov fails on a file that doesn't exist.
    func test_aProductThatDoesntExist_isLeftOut() {
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

        _ = sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export", tests, "-instr-profile", profile,
        ])
        XCTAssertEqual(fileManager.fileExistsAtPath, [library, tests, tests + ".debug.dylib"])
    }

    // Without regions, xccov's lines still say which files no test ran: when llvm-cov fails, or no product it lists
    // exists.
    func test_withoutRegions_xccovsCoverageIsStillGiven() throws {
        let xccovs = Coverage.make(percent: 10, filesWithoutCoverage: ["Sources/file1.swift"])
        answerWithACoverageRun(
            report: Data(coverageData.utf8),
            existing: [true, false, false],
            export: { _ in self.result(status: 1, errors: "error: failed to load coverage: 'Project': No such file\n") }
        )

        XCTAssertEqual(try sut.run(with: muterConfiguration).get(), xccovs)
        XCTAssertEqual(process.commandsRun.last?.prefix(3), ["/usr/bin/xcrun", "llvm-cov", "export"])

        answerWithACoverageRun(report: Data(coverageData.utf8), existing: [false, false])

        XCTAssertEqual(try sut.run(with: muterConfiguration).get(), xccovs)
        XCTAssertEqual(process.commandsRun.count, 3, "llvm-cov ran without a product")
    }

    // A build for every architecture, as `ONLY_ACTIVE_ARCH=NO` makes, gives universal binaries, which llvm-cov reads
    // only for an architecture named, as in this real export, where it warned first. This Mac's is named then, not
    // from the start: llvm-cov would then fail for a binary built only for another, as for an Intel Mac's destination.
    func test_aUniversalBinary_isReadForThisMacsArchitecture() throws {
        let sut = XcodeBuildCoverage(architecture: "arm64")
        let universal = result(status: 1, errors: """
        warning: App: profile data may be out of date - object is newer
        error: failed to load coverage: 'App.debug.dylib': `-arch` specifier is invalid or missing for universal binary
        error: could not load coverage information

        """)
        answerWithACoverageRun(report: appReport, existing: [true, true, false, false]) { command in
            command.contains("-arch") ? self.result(output: self.loadFixture("llvmCovExport.json")) : universal
        }

        let coverage = try sut.run(with: muterConfiguration).get()

        let export = [
            "/usr/bin/xcrun", "llvm-cov", "export", app, "-object", app + ".debug.dylib", "-instr-profile", profile,
        ]
        XCTAssertEqual(process.commandsRun.suffix(2), [export, export + ["-arch", "arm64"]])
        XCTAssertEqual(coverage.functionsCoverage.regionsForFile("/path/to/file.swift").count, 1)
    }

    // Why llvm-cov failed is the first line that says so, not a warning before it.
    func test_whyLLVMCovFailed_isItsFirstError() {
        process.commandResult = { _ in
            self.result(
                status: 1,
                errors: "warning: 2 functions have mismatched data\nerror: malformed coverage data\n"
            )
        }

        XCTAssertEqual(
            sut.llvmCovExport(of: [app], profile: profile, llvmCov: ("/usr/bin/xcrun", ["llvm-cov"])),
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

    // xccov's report of a package tested through xcodebuild lists only its tests' files, as in this real run's, so it
    // says nothing of the project's coverage: rather than 0%, there is none, as on SwiftPM.
    func test_aReportOfNoneOfTheProjectsFiles_givesNoCoverage() {
        let packageReport = report(
            target(
                "ATests",
                buildProductPath: debug + "/ATests.xctest/Contents/MacOS/ATests",
                files: [file("/project/Tests/ATests/ATests.swift", executable: 3, covered: 3)]
            ),
            target(
                "Lib",
                buildProductPath: debug + "/PackageFrameworks/Lib_1E0663EA_PackageProduct.framework/"
                    + "Lib_1E0663EA_PackageProduct",
                files: []
            )
        )

        let lines = XcodeBuildCoverage.coverage(fromReport: packageReport, projectRoot: "/project", coverageThreshold: 0)

        XCTAssertEqual(failure(of: lines), .noProjectFilesInXccovReport)

        answerWithACoverageRun(report: packageReport, existing: [true, false, false])

        XCTAssertEqual(sut.run(with: muterConfiguration), .failure(.noProjectFilesInXccovReport))
        XCTAssertFalse(process.commandsRun.contains { $0.contains("llvm-cov") }, "llvm-cov ran")
        XCTAssertEqual(
            CoverageError.noProjectFilesInXccovReport.reason,
            "xccov's report covers none of the project's source files"
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

    /// Answers a coverage run that passed and printed where its result bundle is, with xccov's `report` of it, a build
    /// folder whose one profile is `profile`, and llvm-cov's export from `export`, given llvm-cov's command, or else
    /// from `llvmCovExport.json`. Each product `report` lists, and the `.debug.dylib` looked for beside each that
    /// exists, exists as `existing` says, in that order.
    private func answerWithACoverageRun(
        report: Data,
        existing: [Bool],
        export: (([String]) -> CommandResult)? = nil
    ) {
        fileManager.currentDirectoryPathToReturn = "/project"
        fileManager.fileExistsToReturn = existing
        process.stdoutToBeReturned = "/path/to/xcrun"
        process.stdoutToBeReturned = String(decoding: report, as: UTF8.self)
        process.stdoutToBeReturned = """
        Build settings for action test and target App:
            BUILD_DIR = /DerivedData/Build/Products
        """
        process.stdoutToBeReturned = profile + "\n"
        let exported = result(output: loadFixture("llvmCovExport.json"))
        process.commandResult = { command in
            command.contains("llvm-cov")
                ? export?(command) ?? exported
                : self.result(output: "Testing started\n/DerivedData/Logs/Test/Test-App.xcresult\n")
        }
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
