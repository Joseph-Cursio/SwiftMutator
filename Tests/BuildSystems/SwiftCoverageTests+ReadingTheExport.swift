import Foundation
@testable import muterCore
import TestingExtensions

extension SwiftCoverageTests {
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
        )
        .get()

        // 8 of 16 lines; a file with no lines to run isn't one without coverage.
        XCTAssertEqual(coverage.percent, 50)
        XCTAssertEqual(coverage.filesWithoutCoverage, ["Sources/Core/Untested.swift"])
        // Discovery keeps only these, whether the tests ran them or not.
        XCTAssertEqual(coverage.filesInCoverage, [
            "Sources/Core/Declarations.swift", "Sources/Core/Shared.swift", "Sources/Core/Untested.swift",
        ])
    }

    // A file named through a link and by its own path, as two binaries can name it, is in coverage once.
    func test_aFileNamedTwice_isInCoverageOnce() throws {
        let directory = try makeTemporaryDirectory()
        let link = directory + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory)
        defer { try? FileManager.default.removeItem(atPath: link) }

        let coverage = try SwiftCoverage.coverage(
            fromExport: export(files: [
                file(directory + "/B.swift", count: 2, covered: 1),
                file(link + "/B.swift", count: 2, covered: 1),
                file(directory + "/A.swift", count: 2, covered: 0),
            ]),
            projectRoot: directory,
            coverageThreshold: 0
        )
        .get()

        XCTAssertEqual(coverage.filesInCoverage, ["A.swift", "B.swift"])
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
        )
        .get()

        XCTAssertEqual(coverage.filesWithoutCoverage, ["A.swift", "B.swift"])
        XCTAssertEqual(coverage.percent, 50)
    }

    // llvm-cov's share of 7 of 100 lines, 7 / 100 * 100, is just above 7.
    func test_aFileExactlyAtTheThreshold_hasNoCoverage_whateverItsShareRoundsTo() throws {
        let coverage = try SwiftCoverage.coverage(
            fromExport: export(files: [file("/project/A.swift", count: 100, covered: 7)]),
            projectRoot: "/project",
            coverageThreshold: 7
        )
        .get()

        XCTAssertEqual(coverage.filesWithoutCoverage, ["A.swift"])
    }

    // A share that doesn't divide evenly is rounded down, as llvm-cov's total was.
    func test_thePercent_isRoundedDown() throws {
        let coverage = try SwiftCoverage.coverage(
            fromExport: export(files: [file("/project/A.swift", count: 3, covered: 2)]),
            projectRoot: "/project",
            coverageThreshold: 0
        )
        .get()

        XCTAssertEqual(coverage.percent, 66)
    }

    func test_aProjectWithNoLinesToRun_hasNoCoverage_andNoFileWithout() throws {
        let coverage = try SwiftCoverage.coverage(
            fromExport: export(files: [file("/project/Declarations.swift", count: 0, covered: 0)]),
            projectRoot: "/project",
            coverageThreshold: 0
        )
        .get()

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
            )
            .get()

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
        )
        .get()

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
}
