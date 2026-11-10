@testable import muterCore
import TestingExtensions
import XCTest

final class XcodeBuildCoverageTests: MuterTestCase {
    let sut = XcodeBuildCoverage()

    var coverageThreshold: Double = 0
    lazy var muterConfiguration = MuterConfiguration(
        executable: "/path/to/xcodebuild",
        arguments: [],
        coverageThreshold: coverageThreshold
    )

    func test_whenUsesSupportedBuildSystem_shouldRunWithCoverage() async {
        _ = await sut.run(with: muterConfiguration)

        XCTAssertEqual(process.commandsRun, [
            [
                "/path/to/xcodebuild",
                "OTHER_SWIFT_FLAGS=$(inherited) -Xllvm -instrprof-atomic-counter-update-all",
                "-enableCodeCoverage", "YES",
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

    // MARK: - Helpers

    /// Answers the coverage run, which ends with `status`, or at its time limit, having printed `output`, and `errors`
    /// to standard error.
    func answerTheCoverageRun(
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
    let simulatorsOutOfDate = """
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
    func answerWithACoverageRun(
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
        process.stdoutToBeReturned = String(lossyUTF8: report)
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
    var profilesLookedFor: [String] {
        process.processesRun.filter { $0.first == "/usr/bin/find" }.map { $0[1] }
    }

    let debug = "/DerivedData/Build/Products/Debug"
    let profile = "/DerivedData/Build/ProfileData/MAC/Coverage.profdata"
    var app: String { debug + "/App.app/Contents/MacOS/App" }
    var appTests: String { debug + "/App.app/Contents/PlugIns/AppTests.xctest/Contents/MacOS/AppTests" }
    var appUITests: String {
        debug + "/AppUITests-Runner.app/Contents/PlugIns/AppUITests.xctest/Contents/MacOS/AppUITests"
    }

    /// xccov's report of an app, with unit tests hosted in it and UI tests in a runner of their own.
    var appReport: Data {
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

    var packageTests: String { debug + "/CalcTests.xctest/Contents/MacOS/CalcTests" }

    /// xccov's report of a real run of a package's tests through xcodebuild: its library, `Calc`, as a framework that
    /// isn't built, with no files, and its tests with only theirs.
    var packageReport: Data {
        packageReport(in: debug)
    }

    /// `packageReport`, with the products in `products`.
    func packageReport(in products: String) -> Data {
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
    func export(files: [String]) -> Data {
        Data("""
        {"type": "llvm.coverage.json.export", "version": "3.0.1",
         "data": [{"files": [\(files.joined(separator: ","))], "functions": []}]}
        """.utf8)
    }

    /// A file of llvm-cov's export, of whose `count` lines the tests ran `covered`.
    func exportedFile(_ path: String, count: Int, covered: Int) -> String {
        #"{"filename": "\#(path)", "summary": {"lines": {"count": \#(count), "covered": \#(covered)}}}"#
    }

    /// The error `result` failed with; nil if it didn't.
    func failure(of result: Result<XcodeBuildCoverage.LineCoverage, CoverageError>) -> CoverageError? {
        guard case let .failure(error) = result else {
            return nil
        }
        return error
    }

    func result(status: Int32 = 0, output: String = "", errors: String = "") -> CommandResult {
        CommandResult(status: status, endedBySignal: false, output: output, errors: errors)
    }

    /// xccov's JSON report of `targets`, without the counts it gives for the whole report and for each target.
    func report(_ targets: String...) -> Data {
        Data(#"{"targets": [\#(targets.joined(separator: ","))]}"#.utf8)
    }

    /// A target of xccov's report that names no product.
    func target(_ name: String, files: [String]) -> String {
        target(name, buildProductPath: nil, files: files)
    }

    /// A target of xccov's report, whose product is at `buildProductPath`.
    func target(_ name: String, buildProductPath: String?, files: [String]) -> String {
        let product = buildProductPath.map { #""buildProductPath": "\#($0)", "# } ?? ""
        return #"{\#(product)"files": [\#(files.joined(separator: ","))], "name": "\#(name)"}"#
    }

    /// A file of xccov's report, of whose `executable` lines the tests ran `covered`.
    func file(_ path: String, executable: Int, covered: Int) -> String {
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
