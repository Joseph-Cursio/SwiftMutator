@testable import muterCore
import XCTest

extension LoadConfigurationTests {
    // As --report's are: each needs a file of its own, resolved against the project's folder, which -o's is beside.
    func test_reportsThatClash_withOutputOrEachOther_areRefused() async throws {
        let clashes = [
            (
                Run.Options.make(reportURL: URL(fileURLWithPath: "\(fixturesDirectory)/summary.md")),
                "-o \(fixturesDirectory)/summary.md and reports: markdown:\(fixturesDirectory)/summary.md would save "
                    + "to the same file"
            ),
            (
                .make(writeBaseline: "\(fixturesDirectory)/summary.md"),
                "reports: markdown:\(fixturesDirectory)/summary.md and --write-baseline "
                    + "\(fixturesDirectory)/summary.md would save to the same file"
            ),
            (
                .make(reportURL: URL(fileURLWithPath: "\(fixturesDirectory)/summary.partial.md")),
                "-o \(fixturesDirectory)/summary.partial.md would save where reports: "
                    + "markdown:\(fixturesDirectory)/summary.md's partial report goes when a run stops"
            ),
        ]
        for (options, clash) in clashes {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data(
                "executable: /usr/bin/swift\narguments: [test]\nreports: [markdown:summary.md]\n".utf8
            )
            state.runOptions = options

            await assertThrowsMuterError(try await sut.run(with: state)) { error in
                XCTAssertEqual(
                    error,
                    .configurationParsingError(reason: "\(clash): give each report a path of its own.")
                )
            }
        }
    }

    // Saving would replace it and everything in it, so a run refuses it before it starts, as `report` does.
    func test_aReportPathThatIsAFolder_isRefused() async throws {
        let refusals = [
            (
                Run.Options.make(),
                "\(fixturesDirectory)/Docs is a folder: name the file to save the report to, in reports: "
                    + "markdown:\(fixturesDirectory)/Docs."
            ),
            (
                .make(reports: [ReportRequest(format: .html, path: "\(fixturesDirectory)/Docs")]),
                "\(fixturesDirectory)/Docs is a folder: name the file to save the report to, in --report "
                    + "html:\(fixturesDirectory)/Docs."
            ),
            (
                .make(reportURL: URL(fileURLWithPath: "\(fixturesDirectory)/Docs"), reports: []),
                "\(fixturesDirectory)/Docs is a folder: name the file to save the report to, in -o "
                    + "\(fixturesDirectory)/Docs."
            ),
            (
                .make(reports: [], writeBaseline: "\(fixturesDirectory)/Docs"),
                "\(fixturesDirectory)/Docs is a folder: name the file to save the report to, in --write-baseline "
                    + "\(fixturesDirectory)/Docs."
            ),
        ]
        fileManager.directoriesToReturn = ["\(fixturesDirectory)/Docs"]
        for (options, reason) in refusals {
            fileManager.fileExistsToReturn = [false, true]
            fileManager.fileContentsToReturn = Data(
                "executable: /usr/bin/swift\narguments: [test]\nreports: [markdown:Docs]\n".utf8
            )
            state.runOptions = options

            await assertThrowsMuterError(try await sut.run(with: state)) { error in
                XCTAssertEqual(error, .configurationParsingError(reason: reason))
            }
        }
    }
}
