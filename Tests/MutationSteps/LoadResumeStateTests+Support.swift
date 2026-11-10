@testable import muterCore
import TestingExtensions
import XCTest

extension LoadResumeStateTests {
    /// Resumes the run whose results `target` names: the file itself, or its log folder.
    func reuse(_ target: String, ignoring globs: [String] = [], forcing: Bool = false, reportURL: URL? = nil) {
        state.runOptions = .make(
            reportURL: reportURL,
            mutationOperatorsList: [.ror],
            skipCoverage: true,
            reuseURL: URL(fileURLWithPath: target),
            resumeIgnoring: globs,
            forceResume: forcing
        )
    }

    func resume(_ target: String, ignoring globs: [String] = [], forcing: Bool = false, reportURL: URL? = nil) {
        state.runOptions = .make(
            reportURL: reportURL,
            mutationOperatorsList: [.ror],
            skipCoverage: true,
            resumeURL: URL(fileURLWithPath: target),
            resumeIgnoring: globs,
            forceResume: forcing
        )
    }

    /// Resumes the run in the results file, as a run of a test plan whose bytes have `sha256`, loaded.
    func resumePlan(sha256: String) {
        let planPath = "\(project)/muter-mappings.json"
        state.runOptions = .make(
            mutationOperatorsList: [.ror],
            skipCoverage: true,
            testPlanURL: URL(fileURLWithPath: planPath),
            resumeURL: URL(fileURLWithPath: resultsPath)
        )
        state.testPlan = LoadedTestPlan(
            path: planPath,
            sha256: sha256,
            formatVersion: TestPlanCoding.formatVersion,
            swiftMutatorVersion: "16",
            scope: nil,
            sources: nil,
            mutatedFiles: nil,
            linkedFiles: nil,
            mutatedPaths: []
        )
    }

    func planRecord(sha256: String) -> TestPlanRecord {
        TestPlanRecord(
            path: "\(project)/muter-mappings.json",
            sha256: sha256,
            formatVersion: TestPlanCoding.formatVersion,
            swiftMutatorVersion: "16"
        )
    }

    /// The log folder of a session that resumed the run in `logs`, beside it: it holds only its note naming the file.
    func makeAResumedSessionsLogFolder() throws -> String {
        let folder = logs.deletingLastPathComponent + "/Oct 6, 2026 at 9:40 AM"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let note = Data(ResultsFile.note(pointingTo: resultsPath, session: 2).utf8)
        try note.write(to: URL(fileURLWithPath: "\(folder)/\(ResultsFile.noteFileName)"))
        return folder
    }

    /// Checks that the step refuses with `expected`.
    func assertRefused(_ expected: ResumeRefused, file: StaticString = #filePath, line: UInt = #line) async {
        await AssertThrowsError(try await sut.run(with: state), file: file, line: line) { error in
            XCTAssertEqual(error as? ResumeRefused, expected, file: file, line: line)
        }
        XCTAssertNil(state.resumeState, file: file, line: line)
    }

    /// The project's files as they are now.
    func projectTree() async -> ProjectTree {
        await ProjectTree.fingerprint(
            listingIn: URL(fileURLWithPath: project),
            hashingIn: URL(fileURLWithPath: project),
            excluding: []
        ) { _ in nil }
    }

    /// `Provenance.fixture`, written by another process, or with another toolchain.
    func provenance(
        process: Int32 = Provenance.fixture.processIdentifier,
        host: String = Provenance.fixture.host,
        toolchain: String? = Provenance.fixture.toolchain.testCommandVersion
    ) -> Provenance {
        let fixture = Provenance.fixture
        return Provenance(
            swiftMutator: fixture.swiftMutator,
            toolchain: .init(
                testCommandVersion: toolchain,
                testExecutableSHA256: fixture.toolchain.testExecutableSHA256,
                environment: fixture.toolchain.environment
            ),
            processIdentifier: process,
            host: host,
            arguments: fixture.arguments
        )
    }

    /// Writes `lines` as the results file, each on a line of its own.
    func writeResults(_ lines: any Encodable...) throws {
        try resultsFileData(lines).write(to: URL(fileURLWithPath: resultsPath))
    }

    /// Writes each file, relative to `root`, making its folders.
    func write(_ files: [String: String], in root: String) throws {
        for (path, contents) in files {
            let file = URL(fileURLWithPath: "\(root)/\(path)")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
    }
}
