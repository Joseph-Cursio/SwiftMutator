@testable import muterCore
import TestingExtensions
import XCTest

/// A real project and results file in a temporary folder, the file opened and locked by the real opener. The project is
/// listed by a walk, as outside a repository, and the build and toolchain are injected.
final class LoadResumeStateTests: MuterTestCase {
    let state = MutationTestState()
    let sut = LoadResumeState()
    let configuration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
    var project = ""
    var logs = ""
    /// The folders the project's files were listed in.
    let listed = Locked<[URL]>([])

    var resultsPath: String {
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
        current.listProjectFiles = { [listed] directory in
            listed.change { $0.append(directory) }
            return nil
        }
    }

    // A run that stopped before its first mutant has nothing to resume: refused, saying why, before anything is copied,
    // and its lock let go.
    func test_aRunThatStoppedBeforeItsFirstMutant_isRefused() async throws {
        let stopped = ResultsStopped.make(step: .baseline, reason: .failed, detail: "baselineTestFailed")
        try writeResults(stopped)

        await assertRefused(
            ResumeRefused(path: resultsPath, reasons: [.stoppedBeforeFirstMutant(stopped)], beforeTheCopy: true)
        )
        let reopened = try ResultsFile.Opener().openForResume(at: resultsPath)
        reopened.close()
    }

    // A run still writing the file holds its lock, and records itself beside it. The refusal comes before anything is
    // removed or copied, and names the holder, not the process that wrote the file's last session: a resume holds the
    // lock long before it writes its session.
    func test_aLockedFile_isRefused_namingTheHolder() async throws {
        try await writeResults(
            ResultsHeader.make(project: projectTree(), provenance: provenance(process: 1_200, host: "laptop.local")),
            ResultsEnd.make(),
            ResultsHeader.make(
                formatVersion: ResultsCoding.resumedFormatVersion,
                session: 2,
                project: projectTree(),
                provenance: provenance(process: 81_234, host: "studio.local")
            )
        )
        let written = try Data(contentsOf: URL(fileURLWithPath: resultsPath))
        let running = try ResultsFile.Opener().openForResume(at: resultsPath)
        defer { running.close() }

        let holder = try XCTUnwrap(LockHolder.current())

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.inUse(holder: .running(holder), lastProcess: nil, lastHost: nil)],
                beforeTheCopy: true
            )
        )

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: resultsPath)), written, "nothing is written to it")
    }

    // A SwiftMutator older than this one locks the file without recording itself. The process that wrote the last
    // session is then all the file shows, which may not be the holder.
    func test_aFileLockedWithoutARecord_isRefused_namingTheLastSessionsProcessAndHost() async throws {
        try await writeResults(
            ResultsHeader.make(project: projectTree(), provenance: provenance(process: 1_200, host: "laptop.local")),
            ResultsEnd.make(),
            ResultsHeader.make(
                formatVersion: ResultsCoding.resumedFormatVersion,
                session: 2,
                project: projectTree(),
                provenance: provenance(process: 81_234, host: "studio.local")
            )
        )
        let descriptor = open(resultsPath, O_RDONLY | O_CLOEXEC)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.inUse(holder: nil, lastProcess: 81_234, lastHost: "studio.local")],
                beforeTheCopy: true
            )
        )
    }

    func test_aLogFolder_findsItsResultsFile() async throws {
        let tree = await projectTree()
        let header = ResultsHeader.make(project: tree)
        let mutant = MutantResult.make(path: "Sources/Sum.swift", fileSHA256: tree.files["Sources/Sum.swift"])
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
        XCTAssertEqual(listed.value, [state.projectDirectoryURL], "the project itself is listed: there is no copy yet")
    }

    // A resumed session's folder holds no results file but its note, so a resume of the resume, given that folder,
    // continues the file the note names.
    func test_aResumedSessionsLogFolder_findsTheFileItsNoteNames() async throws {
        let header = ResultsHeader.make(project: await projectTree())
        try writeResults(header, ResultsEnd.make())
        let resumed = try makeAResumedSessionsLogFolder()
        resume(resumed)

        let changes = try await sut.run(with: state)
        state.apply(changes)

        let loaded = try XCTUnwrap(state.resumeState)
        XCTAssertEqual(loaded.path, resultsPath)
        XCTAssertNotNil(loaded.file)
        XCTAssertEqual(loaded.lastHeader, header)
        loaded.file?.close()
    }

    // Every reason is found before the copy, so one message says all there is to fix, and the file's lock goes with it.
    func test_everyRefusal_comesTogether_beforeTheCopy() async throws {
        try await writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            // Shorter than the session's limit, 96.5 s.
            testSuiteTimeOut: 60
        )
        let changed = provenance(toolchain: "Apple Swift version 6.5")
        current.provenance = { _ in changed }
        try write(["README.md": "a changed readme"], in: project)

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [
                    .configurationChanged(.init(name: "mutationTestTimeout", was: nil, isNow: "60")),
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
        try await writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        let changed = provenance(toolchain: "Apple Swift version 6.5")
        let probed = Locked<[MuterConfiguration]>([])
        current.provenance = { configuration in
            probed.change { $0.append(configuration) }
            return changed
        }
        resume(resultsPath, forcing: true)

        let changes = try await sut.run(with: state)
        state.apply(changes)

        let loaded = try XCTUnwrap(state.resumeState)
        XCTAssertEqual(loaded.forced, ["toolchain.testCommandVersion"])
        XCTAssertEqual(loaded.provenance, changed, "the header records what was checked")
        XCTAssertEqual(probed.value, [configuration], "probed once, with the configuration as loaded")
    }

    func test_aChangedFileAGlobMatches_isLetThrough() async throws {
        try await writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        try write(["README.md": "a changed readme", "Docs/notes.txt": "new notes"], in: project)
        resume(resultsPath, ignoring: ["README.md", "*.txt"])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes.count, 1)
        guard case .resumeStateLoaded? = changes.first else {
            XCTFail("Expected the resume to be loaded, got \(changes)")
            return
        }
    }

    // muter.conf.yml is in the project, but its settings are in the header, and compared one by one: a change that no
    // result depends on goes ahead, and is said, without --resume-ignoring.
    func test_aWorkersChangeInMuterConfYml_goesAhead_andIsSaid() async throws {
        try write(["muter.conf.yml": "mutationTestWorkers: 1\n"], in: project)
        try await writeResults(
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

    // A `swift --version` that stopping the run killed says nothing, which would read as a toolchain change.
    func test_aKilledProbe_throwsCancellation_notARefusal() async throws {
        try await writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        let saidNothing = provenance(toolchain: nil)
        current.provenance = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return saidNothing
        }

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertNil(state.resumeState)
    }

    func test_aNewerFormat_passesItsErrorThrough() async throws {
        let newer = ResultsCoding.newestFormatVersion + 1
        try await writeResults(ResultsHeader.make(formatVersion: newer, project: projectTree()))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(error as? ResultsFileError, .newerFormat(path: self.resultsPath, version: newer))
        }
    }

    // The command that continues a run names the merge base, not the ref, which the reports go on calling by its name.
    func test_aResumedSinceRun_keepsTheFirstSessionsRef() async throws {
        let recorded = ChangeSelection.make(ref: "origin/main")
        try await writeResults(ResultsHeader.make(project: projectTree(), since: recorded), ResultsEnd.make())
        state.apply([.changesSelected(.make(ref: recorded.mergeBase, commit: recorded.mergeBase))])

        let changes = try await sut.run(with: state)
        state.apply(changes)

        XCTAssertEqual(state.changeSelection?.ref, "origin/main")
        XCTAssertEqual(state.changeSelection?.commit, recorded.commit)
        XCTAssertEqual(state.changeSelection?.mergeBase, recorded.mergeBase)
    }
}
