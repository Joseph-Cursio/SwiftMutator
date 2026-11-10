@testable import muterCore
import TestingExtensions
import XCTest

extension XcodeBuildCoverageTests {
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
        )
        .get()

        XCTAssertEqual(coverage.filesWithoutCoverage, ["A.swift", "B.swift"])
        XCTAssertEqual(coverage.percent, 50)
    }

    // xccov's share of 7 of 100 lines, 0.07, times 100 is just above 7.
    func test_aFileExactlyAtTheThreshold_hasNoCoverage_whateverItsShareRoundsTo() throws {
        let coverage = try XcodeBuildCoverage.coverage(
            fromReport: report(target("App.app", files: [file("/project/A.swift", executable: 100, covered: 7)])),
            projectRoot: "/project",
            coverageThreshold: 7
        )
        .get()

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
        )
        .get()

        XCTAssertEqual(coverage.percent, 75)
    }

    // 29 of 100 lines is 29%, where xccov's share, 0.29, times 100 is just under 29.
    func test_thePercent_isWorkedOutFromTheLineCounts() throws {
        let coverage = try XcodeBuildCoverage.coverage(
            fromReport: report(target("App.app", files: [file("/project/A.swift", executable: 100, covered: 29)])),
            projectRoot: "/project",
            coverageThreshold: 0
        )
        .get()

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
        )
        .get()

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
        )
        .get()

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
        )
        .get()

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
        )
        .get()

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
        )
        .get()

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
        )
        .get()

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
        let lines = XcodeBuildCoverage.coverage(
            fromReport: packageReport,
            projectRoot: "/project",
            coverageThreshold: 0
        )

        XCTAssertEqual(failure(of: lines), .noProjectFilesInXccovReport)
        XCTAssertEqual(
            CoverageError.noProjectFilesInXccovReport.reason,
            "xccov's report covers none of the project's source files"
        )
    }
}
