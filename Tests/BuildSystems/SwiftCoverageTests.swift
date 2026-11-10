@testable import muterCore
import TestingExtensions
import XCTest

final class SwiftCoverageTests: MuterTestCase {
    /// macOS's build folder and tools, on any host.
    let sut = SwiftCoverage(platform: .darwin)
    let onLinux = SwiftCoverage(platform: .linux)
    /// Swift Build's build folder on Linux.
    let linuxBuild = "/project/.build/out/Products/Debug-linux"

    var coverageThreshold: Double = 0
    lazy var muterConfiguration = MuterConfiguration(
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

    // The probe orders a mutant's test bundles by their test files.
    func test_testTargetSources_givesEachTestTargetsFiles() async {
        process.commandResult = { _ in
            self.result(output: """
                {"name": "Project", "targets": [
                  {"name": "CoreTests", "type": "test", "sources": ["FooTests.swift", "Bar/BarTests.swift"]},
                  {"name": "AppTests", "type": "test"},
                  {"name": "Core", "type": "library", "sources": ["Foo.swift"]}
                ]}
                """)
        }

        let sources = await sut.testTargetSources(muterConfiguration)

        XCTAssertEqual(sources, ["CoreTests": ["FooTests.swift", "Bar/BarTests.swift"], "AppTests": []])
        XCTAssertEqual(process.commandsRun, [["/path/to/swift", "package", "describe", "--type", "json"]])
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

    // MARK: - Helpers

    /// Answers a coverage run that ends as `testRun` says, whose build is at `buildDirectory` and holds `bundles`, in a
    /// package whose test targets are `testTargets`, or that can't be described, with the export `exportJSON` gives.
    /// `bundles` also lists the build's `codecov` folder, so it holds any profiles there too. The LLVM tools, by
    /// whatever path, answer as llvm-cov and llvm-profdata.
    func answerWithACoverageRun(
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
            return command.contains { $0.hasSuffix("llvm-cov") }
                ? self.result(output: export)
                : testRun ?? self.result(output: "Test run passed\n")
        }
    }

    /// A coverage run's output in which an XCTest test and a Swift Testing test failed, as `failedTests` names them.
    let failedTestsOutput = """
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

    let failedTests = FailedTestLine.FailedTests(
        tests: [
            .init(name: "-[CTests.CTests test_failsOnlyUnderCoverage]", location: nil),
            .init(name: "failsOnlyUnderCoverage()", location: "BTests.swift:11:9"),
        ],
        total: 2,
        firstLine: "Test Case '-[CTests.CTests test_failsOnlyUnderCoverage]' failed (0.039 seconds)."
    )

    func bundle(_ name: String) -> String {
        "/project/.build/out/Products/Debug/\(name).xctest/Contents/MacOS/\(name)"
    }

    var exportJSON: String {
        String(lossyUTF8: export(
            files: [
                file("/project/Sources/Core/Shared.swift", count: 6, covered: 4),
                file("/project/Sources/Core/Untested.swift", count: 2, covered: 0),
            ],
            functions: """
            {"filenames": ["/project/Sources/Core/Shared.swift"],
             "regions": [[1, 30, 6, 2, 3, 0, 0, 0], [3, 20, 5, 2, 0, 0, 0, 0]]}
            """
        ))
    }

    func export(files: [String], functions: String = "") -> Data {
        Data("""
        {"type": "llvm.coverage.json.export", "version": "3.0.1",
         "data": [{"files": [\(files.joined(separator: ","))], "functions": [\(functions)]}]}
        """.utf8)
    }

    /// A file of llvm-cov's export, with its percentage worked out as llvm-cov does.
    func file(_ path: String, count: Int, covered: Int) -> String {
        let percent = count > 0 ? Double(covered) / Double(count) * 100 : 0
        return """
        {"filename": "\(path)", "summary": {"lines": {"count": \(count), "covered": \(covered), "percent": \(percent)}}}
        """
    }

    func result(status: Int32 = 0, output: String = "", errors: String = "") -> CommandResult {
        CommandResult(status: status, endedBySignal: false, output: output, errors: errors)
    }
}
