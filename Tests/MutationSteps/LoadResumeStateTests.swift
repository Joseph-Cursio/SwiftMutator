@testable import muterCore
import TestingExtensions
import XCTest

/// A real project and results file in a temporary folder, the file opened and locked by the real opener. The project is
/// listed by a walk, as outside a repository, and the build and toolchain are injected.
final class LoadResumeStateTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = LoadResumeState()
    private let configuration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
    private var project = ""
    private var logs = ""
    /// The folders the project's files were listed in.
    private var listed: [URL] = []

    private var resultsPath: String {
        "\(logs)/results.jsonl"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = try makeTemporaryDirectory()
        project = "\(root)/project"
        logs = "\(root)/project_muter_logs/Oct 6, 2026 at 9:12 AM"
        try write(["README.md": "readme", "Sources/Sum.swift": "func sum() {}"], in: project)
        try FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        state.projectDirectoryURL = URL(fileURLWithPath: project)
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "\(root)/project_mutated")
        state.muterConfiguration = configuration
        state.mutationOperatorList = [.ror]
        resume(resultsPath)
    }

    // After setUpWithError, which XCTest calls first: MuterTestCase installs the spies in both.
    override func setUp() {
        super.setUp()

        // Real files: the spy's contentsOfDirectory can't tell a folder from a file, and the real opener locks them.
        current.fileManager = FileManager.default
        current.resultsFiles = ResultsFile.Opener()
        current.listProjectFiles = { [unowned self] directory in
            self.listed.append(directory)
            return nil
        }
    }

    // A run still writing the file holds its lock. The refusal comes before anything is removed or copied, and names
    // the process that wrote the file's last session, which is likely the one that holds it.
    func test_aLockedFile_isRefused_namingTheLastSessionsProcessAndHost() async throws {
        try writeResults(
            ResultsHeader.make(project: projectTree(), provenance: provenance(process: 1200, host: "laptop.local")),
            ResultsEnd.make(),
            ResultsHeader.make(
                formatVersion: ResultsCoding.resumedFormatVersion,
                session: 2,
                project: projectTree(),
                provenance: provenance(process: 81234, host: "studio.local")
            )
        )
        let written = try Data(contentsOf: URL(fileURLWithPath: resultsPath))
        let running = try ResultsFile.Opener().openForResume(at: resultsPath)
        defer { running.close() }

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.inUse(lastProcess: 81234, lastHost: "studio.local")],
                beforeTheCopy: true
            )
        )

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: resultsPath)), written, "nothing is written to it")
    }

    func test_aLogFolder_findsItsResultsFile() async throws {
        let header = ResultsHeader.make(project: projectTree())
        let mutant = MutantResult.make(path: "Sources/Sum.swift", fileSHA256: projectTree().files["Sources/Sum.swift"])
        try writeResults(header, mutant, ResultsEnd.make(recorded: 1))
        resume(logs)

        let changes = try await sut.run(with: state)
        state.apply(changes)

        let loaded = try XCTUnwrap(state.resumeState)
        XCTAssertEqual(changes, [.resumeStateLoaded(loaded)])
        XCTAssertEqual(loaded.path, resultsPath)
        XCTAssertEqual(loaded.lastHeader, header)
        XCTAssertEqual(loaded.lastSession, 1)
        XCTAssertEqual(loaded.recorded.latest, [mutant.key: mutant])
        XCTAssertEqual(loaded.provenance, .fixture)
        XCTAssertEqual(loaded.forced, [])
        XCTAssertEqual(loaded.notices, [])
        XCTAssertEqual(listed, [state.projectDirectoryURL], "the project itself is listed: there is no copy yet")
    }

    // Every reason is found before the copy, so one message says all there is to fix, and the file's lock goes with it.
    func test_everyRefusal_comesTogether_beforeTheCopy() async throws {
        try writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            testSuiteTimeOut: 120
        )
        current.provenance = { _ in self.provenance(toolchain: "Apple Swift version 6.5") }
        try write(["README.md": "a changed readme"], in: project)

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [
                    .configurationChanged(.init(name: "mutationTestTimeout", was: nil, isNow: "120")),
                    .needsForce(
                        .init(
                            name: "toolchain.testCommandVersion",
                            was: #""Apple Swift version 6.4""#,
                            isNow: #""Apple Swift version 6.5""#
                        )
                    ),
                    .filesChanged([.init(path: "README.md", kind: .changed)]),
                ],
                beforeTheCopy: true
            )
        )

        XCTAssertNoThrow(try ResultsFile.Opener().openForResume(at: resultsPath), "the refused resume holds no lock")
    }

    func test_aToolchainChange_isLetThroughByForce_andRecordedAsForced() async throws {
        try writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        let changed = provenance(toolchain: "Apple Swift version 6.5")
        var probed: [MuterConfiguration] = []
        current.provenance = { configuration in
            probed.append(configuration)
            return changed
        }
        resume(resultsPath, forcing: true)

        let changes = try await sut.run(with: state)
        state.apply(changes)

        let loaded = try XCTUnwrap(state.resumeState)
        XCTAssertEqual(loaded.forced, ["toolchain.testCommandVersion"])
        XCTAssertEqual(loaded.provenance, changed, "the header records what was checked")
        XCTAssertEqual(probed, [configuration], "probed once, with the configuration as loaded")
    }

    func test_aChangedFileAGlobMatches_isLetThrough() async throws {
        try writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        try write(["README.md": "a changed readme", "Docs/notes.txt": "new notes"], in: project)
        resume(resultsPath, ignoring: ["README.md", "*.txt"])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes.count, 1)
        guard case .resumeStateLoaded? = changes.first else {
            return XCTFail("Expected the resume to be loaded, got \(changes)")
        }
    }

    // muter.conf.yml is in the project, but its settings are in the header, and compared one by one: a change that no
    // result depends on goes ahead, and is said, without --resume-ignoring.
    func test_aWorkersChangeInMuterConfYml_goesAhead_andIsSaid() async throws {
        try write(["muter.conf.yml": "mutationTestWorkers: 1\n"], in: project)
        try writeResults(
            ResultsHeader.make(
                project: projectTree(),
                configuration: MuterConfiguration(
                    executable: "/usr/bin/swift",
                    arguments: ["test"],
                    mutationTestWorkers: 1
                )
            ),
            ResultsEnd.make()
        )
        try write(["muter.conf.yml": "mutationTestWorkers: 2\n"], in: project)
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            mutationTestWorkers: 2
        )

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(
            try XCTUnwrap(state.resumeState).notices,
            ["mutationTestWorkers was 1 and is 2 now, which no result depends on."]
        )
    }

    // Saving the report there would replace every result the resume keeps.
    func test_aReportPathThatIsTheResultsFile_isRefused() async throws {
        try writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        resume(resultsPath, reportURL: URL(fileURLWithPath: resultsPath))

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.reportWouldReplaceTheResultsFile(resultsPath)],
                beforeTheCopy: true
            )
        )
    }

    // A `swift --version` that stopping the run killed says nothing, which would read as a toolchain change.
    func test_aKilledProbe_throwsCancellation_notARefusal() async throws {
        try writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        current.provenance = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return self.provenance(toolchain: nil)
        }

        let result = await Task { [sut, state] in try await sut.run(with: state) }.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertNil(state.resumeState)
    }

    func test_aNewerFormat_passesItsErrorThrough() async throws {
        try writeResults(ResultsHeader.make(formatVersion: 3, project: projectTree()))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(error as? ResultsFileError, .newerFormat(path: self.resultsPath, version: 3))
        }
    }
}

private extension LoadResumeStateTests {
    /// Resumes the run whose results `target` names: the file itself, or its log folder.
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

    /// Checks that the step refuses with `expected`.
    func assertRefused(_ expected: ResumeRefused, file: StaticString = #filePath, line: UInt = #line) async {
        await AssertThrowsError(try await sut.run(with: state), file: file, line: line) { error in
            XCTAssertEqual(error as? ResumeRefused, expected, file: file, line: line)
        }
        XCTAssertNil(state.resumeState, file: file, line: line)
    }

    /// The project's files as they are now.
    func projectTree() -> ProjectTree {
        ProjectTree.fingerprint(
            listingIn: URL(fileURLWithPath: project),
            hashingIn: URL(fileURLWithPath: project),
            excluding: [],
            list: { _ in nil }
        )
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
