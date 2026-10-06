@testable import muterCore
import XCTest

final class MutationTestStateTests: MuterTestCase {
    private let sut = MutationTestState(
        from: .make(
            filesToMutate: [
                "/path/to/file1.swift,/path/to/file3.swift,/path/to/file3.swift,",
            ]
        )
    )

    func test_shouldParseFilesToMutate() {
        XCTAssertEqual(sut.filesToMutate.count, 3)
        XCTAssertEqual(sut.filesToMutate[safe: 0], "/path/to/file1.swift")
        XCTAssertEqual(sut.filesToMutate[safe: 1], "/path/to/file3.swift")
        XCTAssertEqual(sut.filesToMutate[safe: 2], "/path/to/file3.swift")
    }

    func test_loggingDirectoryCreated_setsIt() {
        XCTAssertEqual(sut.loggingDirectory, "")

        sut.apply([.loggingDirectoryCreated("/project_muter_logs/Oct 4, 2026 at 1:16 PM")])

        XCTAssertEqual(sut.loggingDirectory, "/project_muter_logs/Oct 4, 2026 at 1:16 PM")
    }

    func test_aRunThatIsntResumed_hasNoResumeState_andWaivesNothing() {
        XCTAssertNil(sut.resumeState)
        XCTAssertEqual(sut.resumeWaived, [])
    }

    func test_resumeStateLoaded_andProjectChangesWaived_setThem() throws {
        let resume = try ResumeState.make(
            lines: [ResultsHeader.make(), ResultsEnd.make()],
            file: resultsFiles.openForResume(at: "/project_muter_logs/session 1/results.jsonl")
        )

        sut.apply([.resumeStateLoaded(resume), .projectChangesWaived(["README.md"])])

        XCTAssertTrue(sut.resumeState === resume)
        XCTAssertEqual(sut.resumeWaived, ["README.md"])
    }
}
