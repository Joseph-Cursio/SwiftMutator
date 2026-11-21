import XCTest

/// Runs the built `swift-mutator` from the project's parent folder with `--project-folder`, on `ResumeHarness`'s
/// project, whose test command is a shell script.
final class ProjectFolderAcceptanceTests: XCTestCase {
    /// The project, and the processes a test starts on it.
    private let harness = ResumeHarness()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try harness.create()
    }

    override func tearDownWithError() throws {
        harness.cleanUp()
        try super.tearDownWithError()
    }

    // The project is the folder given, so the copy and the log folder are beside it, but `-o`'s relative path is the
    // folder the command was given in, as it is without the flag.
    func test_aRunFromTheParentFolder_testsTheProjectGiven_andSavesTheReportWhereTheCommandWasGiven() throws {
        let arguments = ["run", "--skip-update-check", "--skip-coverage", "--project-folder", "project"]
            + ["-f", "json", "-o", "report.json"]

        let ended = try harness.waitForEnd(of: harness.launch(arguments, in: harness.root))

        XCTAssertEqual(ended.status, 0, ended.standardError + ended.standardOutput)
        XCTAssertEqual(try harness.outcomes(inJSONReportAt: harness.report), ["failed", "failed", "passed", "passed"])
        XCTAssertFalse(harness.exists("project/report.json"), "the report was saved in the project")
        XCTAssertEqual(harness.ranLines().count, 5, "the baseline and 4 mutants: \(harness.ranLines())")
        XCTAssertTrue(harness.exists("project_mutated.noindex"), "the copy isn't beside the project")
        let resultsFile = try harness.onlyResultsFile()
        let header = try XCTUnwrap(harness.records(in: resultsFile).first)
        XCTAssertEqual(
            (header["projectPath"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            harness.project.resolvingSymlinksInPath().path
        )
        XCTAssertFalse(harness.exists("project/project_muter_logs"), "the log folder is in the project")
    }
}
