@testable import muterCore
import TestingExtensions
import XCTest

final class SwiftCoverageTests: MuterTestCase {
    private let sut = SwiftCoverage()

    private var coverageThreshold: Double = 0
    private lazy var muterConfiguration = MuterConfiguration(
        executable: "/path/to/swift",
        arguments: ["test", "--skip", "Slow"],
        coverageThreshold: coverageThreshold
    )

    // MARK: - Running the coverage

    // Swift Build makes a bundle for each test target, and each maps only the code its target links, so one export
    // takes them all: the first by name, then each other as an object.
    func test_coverage_isExportedFromEveryTestBundle_inOneCall() {
        answerWithACoverageRun(
            bundles: ["CoreTests.xctest", "AppTests.xctest"],
            testTargets: ["CoreTests", "AppTests"]
        )

        _ = sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun, [
            ["/path/to/swift", "test", "--skip", "Slow", "--enable-code-coverage"],
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
    func test_theBundleOfATestTargetThePackageNoLongerHas_isLeftOut() {
        answerWithACoverageRun(bundles: ["CoreTests.xctest", "OldTests.xctest"], testTargets: ["CoreTests"])

        _ = sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export", bundle("CoreTests"),
            "-instr-profile", "/project/.build/out/Products/Debug/codecov/default.profdata",
        ])
    }

    // The native build system names its one bundle after the package. Without the package's description, every
    // bundle is used.
    func test_everyBundle_isKept_whenNoneIsNamedAfterATestTarget_orTheTargetsAreUnknown() {
        answerWithACoverageRun(bundles: ["ProjectPackageTests.xctest"], testTargets: ["CoreTests"])
        _ = sut.run(with: muterConfiguration)
        XCTAssertEqual(process.commandsRun.last?.dropFirst(3).first, bundle("ProjectPackageTests"))

        answerWithACoverageRun(bundles: ["CoreTests.xctest", "OldTests.xctest", "Package.swift"], testTargets: nil)
        _ = sut.run(with: muterConfiguration)
        XCTAssertEqual(process.commandsRun.last, [
            "/usr/bin/xcrun", "llvm-cov", "export", bundle("CoreTests"), "-object", bundle("OldTests"),
            "-instr-profile", "/project/.build/out/Products/Debug/codecov/default.profdata",
        ])
    }

    // The native build system makes one bundle for the whole package.
    func test_aSingleTestBundle_isExportedAlone() {
        answerWithACoverageRun(bundles: ["ProjectPackageTests.xctest"])

        _ = sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun.last?.dropFirst(3).first, bundle("ProjectPackageTests"))
        XCTAssertFalse(process.commandsRun.last?.contains("-object") ?? true)
    }

    func test_theCoverage_comesFromTheExport() throws {
        answerWithACoverageRun(bundles: ["CoreTests.xctest"])
        coverageThreshold = 70

        let coverage = try sut.run(with: muterConfiguration).get()

        XCTAssertEqual(coverage.percent, 50)
        // Shared.swift has 4 of its 6 lines run, under the configured threshold.
        XCTAssertEqual(coverage.filesWithoutCoverage, ["Sources/Core/Shared.swift", "Sources/Core/Untested.swift"])
        XCTAssertEqual(coverage.regionsForFile("/project/Sources/Core/Shared.swift"), [
            .make(lineStart: 3, columnStart: 20, lineEnd: 5, columnEnd: 2, executionCount: 0),
        ])
    }

    // SwiftPM writes no profile data when a test fails, so nothing more is run.
    func test_failingTests_giveNoCoverage() {
        process.commandResult = { _ in self.result(status: 1) }

        XCTAssertEqual(sut.run(with: muterConfiguration), .failure(.testsFailed(status: 1, bySignal: false)))
        XCTAssertEqual(process.commandsRun.count, 1)
    }

    // A crash isn't a failing test, so it is told apart.
    func test_aCoverageRunEndedByASignal_givesNoCoverage() {
        process.commandResult = { _ in CommandResult(status: 9, endedBySignal: true, output: "", errors: "") }

        XCTAssertEqual(sut.run(with: muterConfiguration), .failure(.testsFailed(status: 9, bySignal: true)))
        XCTAssertEqual(process.commandsRun.count, 1)
    }

    func test_aTestCommandThatCantBeStarted_givesNoCoverage() {
        XCTAssertEqual(sut.run(with: muterConfiguration), .failure(.couldNotRun("/path/to/swift")))
    }

    func test_noBuildDirectory_givesNoCoverage() {
        process.commandResult = { command in
            command.last == "--show-codecov-path" ? self.result(status: 1) : self.result()
        }

        XCTAssertEqual(sut.run(with: muterConfiguration), .failure(.noBuildDirectory))
    }

    func test_noProfileData_givesNoCoverage() {
        answerWithACoverageRun(bundles: ["CoreTests.xctest"], profileExists: false)

        XCTAssertEqual(
            sut.run(with: muterConfiguration),
            .failure(.noProfileData(atPath: "/project/.build/out/Products/Debug/codecov/default.profdata"))
        )
    }

    func test_noTestBundle_givesNoCoverage() {
        answerWithACoverageRun(bundles: ["CLI"])

        XCTAssertEqual(
            sut.run(with: muterConfiguration),
            .failure(.noTestBundles(inDirectory: "/project/.build/out/Products/Debug"))
        )
    }

    func test_anLLVMCovFailure_givesItsFirstLine() {
        answerWithACoverageRun(bundles: ["CoreTests.xctest"])
        let answer = process.commandResult
        process.commandResult = { command in
            command.contains("llvm-cov")
                ? self.result(status: 1, errors: "error: failed to load coverage: 'x': No such file\nmore\n")
                : answer(command)
        }

        XCTAssertEqual(
            sut.run(with: muterConfiguration),
            .failure(.llvmCovFailed("error: failed to load coverage: 'x': No such file"))
        )
    }

    func test_anLLVMCovThatCantBeStarted_givesNoCoverage() {
        answerWithACoverageRun(bundles: ["CoreTests.xctest"])
        let answer = process.commandResult
        process.commandResult = { command in command.contains("llvm-cov") ? nil : answer(command) }

        XCTAssertEqual(sut.run(with: muterConfiguration), .failure(.couldNotRun("llvm-cov")))
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

    /// Answers a coverage run whose build is at `/project/.build/out/Products/Debug` and holds `bundles`, in a package
    /// whose test targets are `testTargets`, or that can't be described, with the export `exportJSON` gives.
    private func answerWithACoverageRun(
        bundles: [String],
        testTargets: [String]? = ["CoreTests"],
        profileExists: Bool = true
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
                return self.result(output: "/project/.build/out/Products/Debug/codecov/Project.json\n")
            }
            if command.contains("describe") {
                return description.map { self.result(output: $0) } ?? self.result(status: 1)
            }
            return command.contains("llvm-cov") ? self.result(output: export) : self.result(output: "Test run passed\n")
        }
    }

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

    private func file(_ path: String, count: Int, covered: Int) -> String {
        let percent = count > 0 ? Double(covered) * 100 / Double(count) : 0
        return """
        {"filename": "\(path)", "summary": {"lines": {"count": \(count), "covered": \(covered), "percent": \(percent)}}}
        """
    }

    private func result(status: Int32 = 0, output: String = "", errors: String = "") -> CommandResult {
        CommandResult(status: status, endedBySignal: false, output: output, errors: errors)
    }
}
