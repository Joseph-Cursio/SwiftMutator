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
    private let listed = Locked<[URL]>([])

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
        current.listProjectFiles = { [listed] directory in
            listed.change { $0.append(directory) }
            return nil
        }
    }

    // A run still writing the file holds its lock, and records itself beside it. The refusal comes before anything is
    // removed or copied, and names the holder, not the process that wrote the file's last session: a resume holds the
    // lock long before it writes its session.
    func test_aLockedFile_isRefused_namingTheHolder() async throws {
        try await writeResults(
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
            ResultsHeader.make(project: projectTree(), provenance: provenance(process: 1200, host: "laptop.local")),
            ResultsEnd.make(),
            ResultsHeader.make(
                formatVersion: ResultsCoding.resumedFormatVersion,
                session: 2,
                project: projectTree(),
                provenance: provenance(process: 81234, host: "studio.local")
            )
        )
        let descriptor = open(resultsPath, O_RDONLY | O_CLOEXEC)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.inUse(holder: nil, lastProcess: 81234, lastHost: "studio.local")],
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

    // Against the longest limit of every session, not only the last's: a result of a session with a longer one may
    // need it.
    func test_aLongerTimeLimit_goesAhead_onlyIfNoSessionHadALongerOne() async throws {
        let timed = { (seconds: Double) in
            MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: seconds)
        }
        try await writeResults(
            ResultsHeader.make(project: projectTree(), timeoutSeconds: 120),
            ResultsEnd.make(reason: .interrupted),
            ResultsHeader.make(session: 2, project: projectTree(), timeoutSeconds: 96.5),
            ResultsEnd.make()
        )
        resume(resultsPath)
        state.muterConfiguration = timed(100)

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.configurationChanged(.init(name: "mutationTestTimeout", was: nil, isNow: "100"))],
                beforeTheCopy: true
            )
        )

        state.muterConfiguration = timed(120)
        let changes = try await sut.run(with: state)
        state.apply(changes)

        XCTAssertEqual(
            try XCTUnwrap(state.resumeState).notices,
            [
                "mutationTestTimeout was not set and is 120 now, no shorter than any session's limit: the timeouts "
                    + "under a shorter one are tested again.",
            ]
        )
    }

    // A result that --reuse kept was tested under the earlier run's limit, which the file doesn't record.
    func test_aLongerTimeLimit_isRefused_forAFileThatHoldsAReusedResult() async throws {
        let tree = await projectTree()
        let reused = MutantResult.make(
            path: "Sources/Sum.swift",
            fileSHA256: tree.files["Sources/Sum.swift"],
            reusedFrom: ReusedFrom(resultsFile: "/earlier/results.jsonl", session: 1, despiteChanges: false)
        )
        try writeResults(ResultsHeader.make(project: tree, timeoutSeconds: 20), reused, ResultsEnd.make())
        resume(resultsPath)
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            testSuiteTimeOut: 120
        )

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.timeLimitUnknown(.init(name: "mutationTestTimeout", was: nil, isNow: "120"))],
                beforeTheCopy: true
            )
        )
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
            return XCTFail("Expected the resume to be loaded, got \(changes)")
        }
    }

    // A plan run's last session recorded the copy as it tested it, rewritten and perhaps fixed by hand, which differs
    // from the project. FingerprintProjectTree compares the copy once it is locked, and CheckTestPlanSources has
    // checked the project against the plan, so nothing here lists or hashes the project.
    func test_aTestPlanRun_doesNotCompareTheProjectWithTheRecordedCopy() async throws {
        let copy = state.mutatedProjectDirectoryURL.path
        try write(["README.md": "readme", "Sources/Sum.swift": "func sum() { if __SWIFTMUTATOR_ACTIVE {} }"], in: copy)
        let copyTree = await ProjectTree.fingerprint(
            listingIn: URL(fileURLWithPath: copy),
            hashingIn: URL(fileURLWithPath: copy),
            excluding: [],
            list: { _ in nil }
        )
        let projectTree = await projectTree()
        XCTAssertNotEqual(copyTree.files, projectTree.files, "the copy differs from the project")
        try writeResults(
            ResultsHeader.make(project: copyTree, usingTestPlan: true, testPlan: planRecord(sha256: "91a")),
            ResultsEnd.make()
        )
        resumePlan(sha256: "91a")

        let changes = try await sut.run(with: state)

        guard case .resumeStateLoaded? = changes.first, changes.count == 1 else {
            return XCTFail("Expected the resume to be loaded, got \(changes)")
        }
        XCTAssertEqual(listed.value, [], "the project was listed")
    }

    func test_aTestPlanRun_withAnotherPlan_isRefusedBeforeTheCopy() async throws {
        try await writeResults(
            ResultsHeader.make(project: projectTree(), usingTestPlan: true, testPlan: planRecord(sha256: "91a")),
            ResultsEnd.make()
        )
        resumePlan(sha256: "b07")

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.testPlanChanged(.init(name: "testPlan.sha256", was: #""91a""#, isNow: #""b07""#))],
                beforeTheCopy: true
            )
        )
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

    // Saving the report there would replace every result the resume keeps.
    func test_aReportPathThatIsTheResultsFile_isRefused() async throws {
        try await writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
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
        try await writeResults(ResultsHeader.make(formatVersion: 3, project: projectTree()))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(error as? ResultsFileError, .newerFormat(path: self.resultsPath, version: 3))
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

extension LoadResumeStateTests {
    // A reuse writes a file of its own, so it neither opens the earlier one to append nor locks it: a run still writing
    // it doesn't stop it. Changed files don't refuse it, but decide what it keeps once the copy is fingerprinted, so
    // the project isn't listed here.
    func test_aReuse_readsTheFileWithoutLockingIt_andChangedFilesDontRefuseIt() async throws {
        let header = ResultsHeader.make(project: await projectTree())
        try writeResults(header, ResultsEnd.make())
        try write(["README.md": "a changed readme"], in: project)
        let running = try ResultsFile.Opener().openForResume(at: resultsPath)
        defer { running.close() }
        reuse(logs)

        let changes = try await sut.run(with: state)
        state.apply(changes)

        let loaded = try XCTUnwrap(state.resumeState)
        XCTAssertTrue(loaded.isReuse)
        XCTAssertNil(loaded.file)
        XCTAssertEqual(loaded.path, resultsPath)
        XCTAssertEqual(loaded.lastHeader, header)
        XCTAssertEqual(listed.value, [])
    }

    func test_aReuse_ofAResumedSessionsLogFolder_readsTheFileItsNoteNames() async throws {
        let header = ResultsHeader.make(project: await projectTree())
        try writeResults(header, ResultsEnd.make())
        reuse(try makeAResumedSessionsLogFolder())

        let changes = try await sut.run(with: state)
        state.apply(changes)

        let loaded = try XCTUnwrap(state.resumeState)
        XCTAssertTrue(loaded.isReuse)
        XCTAssertEqual(loaded.path, resultsPath)
        XCTAssertEqual(loaded.lastHeader, header)
    }

    // What a reuse can't take, it refuses as a resume does, naming its own flags.
    func test_aReuse_isRefusedAsAResumeIs_namingForceReuse() async throws {
        try await writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        let changed = provenance(toolchain: "Apple Swift version 6.5")
        current.provenance = { _ in changed }
        reuse(resultsPath, reportURL: URL(fileURLWithPath: resultsPath))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            let refused = error as? ResumeRefused
            XCTAssertEqual(refused?.isReuse, true)
            XCTAssertEqual(refused?.reasons.count, 2)
            let message = refused.map { "\($0)" } ?? ""
            XCTAssertTrue(message.hasPrefix("SwiftMutator won't reuse the results in "), message)
            XCTAssertTrue(message.contains("--force-reuse reuses the results anyway."), message)
            XCTAssertFalse(message.contains("--force-resume"), message)
            XCTAssertTrue(message.contains("is the results file itself"), message)
        }
        XCTAssertNil(state.resumeState)

        current.provenance = { _ in .fixture }
        reuse(resultsPath, forcing: true)
        current.provenance = { _ in changed }
        let changes = try await sut.run(with: state)
        state.apply(changes)
        XCTAssertEqual(state.resumeState?.forced, ["toolchain.testCommandVersion"])
    }
}

private extension LoadResumeStateTests {
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
        let folder = (logs as NSString).deletingLastPathComponent + "/Oct 6, 2026 at 9:40 AM"
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
