@testable import muterCore
import TestingExtensions
import XCTest

/// Real folders for the project and its copy, and an injected listing in place of git.
final class FingerprintProjectTreeTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = FingerprintProjectTree()
    private var project = ""
    private var copy = ""
    private let resultsPath = "/project_muter_logs/session 1/results.jsonl"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = try makeTemporaryDirectory()
        project = "\(root)/project"
        copy = "\(root)/project_mutated"
        state.projectDirectoryURL = URL(fileURLWithPath: project)
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: copy)
    }

    // The files are listed in the project and hashed in the copy, as it was tested. The -o report and its partial
    // sibling, which the run itself writes in the project, are left out, and so is the configuration file, whose
    // settings the header records.
    func test_fingerprintsTheCopy_andHandsTheTreeToTheState() async throws {
        state.runOptions = .make(reportURL: URL(fileURLWithPath: "\(project)/mutation-report.txt"))
        try write(["README.md": "readme", "Sources/Sum.swift": "as in the project"], in: project)
        try write(
            [
                "README.md": "readme",
                "Sources/Sum.swift": "as copied",
                "mutation-report.txt": "an earlier report",
                "muter.conf.yml": "mutationTestWorkers: 4",
            ],
            in: copy
        )
        let listed = Locked<[URL]>([])
        current.listProjectFiles = { directory in
            listed.change { $0.append(directory) }
            return ["README.md", "Sources/Sum.swift", "mutation-report.txt", "muter.conf.yml"]
        }

        let changes = try await sut.run(with: state)
        state.apply(changes)

        XCTAssertEqual(listed.value, [state.projectDirectoryURL])
        let files = [
            "README.md": FileDigest.sha256(of: Data("readme".utf8)),
            "Sources/Sum.swift": FileDigest.sha256(of: Data("as copied".utf8)),
        ]
        let tree = ProjectTree(
            listedBy: .git,
            files: files,
            excluded: ["mutation-report.partial.txt", "mutation-report.txt", "muter.conf.yml"],
            treeSHA256: ProjectTree.treeHash(of: files)
        )
        XCTAssertEqual(changes, [.projectTreeFingerprinted(tree)])
        XCTAssertEqual(state.projectTree, tree)
    }

    // As -o's is, each report the configuration's reports: asks for, and its partial sibling, is left out: a resume
    // after a stop that wrote one would otherwise find the project changed. One outside the project isn't named.
    func test_theConfigurationsReports_andTheirPartialSiblings_areLeftOut() async throws {
        state.muterConfiguration = MuterConfiguration(reports: [
            ReportRequest(format: .markdown, path: "summary.md"),
            ReportRequest(format: .html, path: "/elsewhere/report.html"),
        ])
        let copied = ["README.md": "readme", "summary.md": "an earlier report", "summary.partial.md": "a stop's"]
        try write(copied, in: copy)
        current.listProjectFiles = { _ in Array(copied.keys) }

        let changes = try await sut.run(with: state)

        let files = ["README.md": FileDigest.sha256(of: Data("readme".utf8))]
        let tree = ProjectTree(
            listedBy: .git,
            files: files,
            excluded: ["muter.conf.yml", "summary.md", "summary.partial.md"],
            treeSHA256: ProjectTree.treeHash(of: files)
        )
        XCTAssertEqual(changes, [.projectTreeFingerprinted(tree)])
    }

    // A git that stopping the run killed reads as no repository, so the step stops rather than hand on a walk's tree.
    func test_aListingTheStopKilled_throwsCancellation() async throws {
        try write(["Sources/Sum.swift": "sum"], in: copy)
        current.listProjectFiles = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return nil
        }

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertNil(state.projectTree)
    }

    // The copy builds a local package and a workspace's project outside the project from where they are, unmutated,
    // so the step says so once, from the fingerprint's own listing. The package's files are fingerprinted, and the
    // workspace's project's aren't, so earlier results files still resume.
    func test_codeOutsideTheProject_isSaidOnce_andOnlyLocalPackagesAreFingerprinted() async throws {
        let projectFiles = [
            "Package.swift": #"let package = Package(dependencies: [.package(path: "../Core")])"#,
            "App.xcworkspace/contents.xcworkspacedata":
                #"<Workspace version = "1.0"><FileRef location = "group:../Other/Other.xcodeproj"/></Workspace>"#,
        ]
        try write(projectFiles, in: self.project)
        try write(projectFiles, in: copy)
        let root = (self.project as NSString).deletingLastPathComponent
        try write(["Core/Package.swift": "core", "Other/Other.xcodeproj/project.pbxproj": "other"], in: root)
        let listed = recordListings(Array(projectFiles.keys))
        let said = recordPaths(of: .codeOutsideTheProjectBuilt)
        let warned = recordPaths(of: .projectCodeNamedByAbsolutePath)

        let changes = try await sut.run(with: state)
        state.apply(changes)

        XCTAssertEqual(said.value, [["../Core", "../Other/Other.xcodeproj"]])
        XCTAssertEqual(warned.value, [])
        XCTAssertEqual(listed.value.map(\.lastPathComponent), ["project", "Core"], "the project is listed once")
        XCTAssertEqual(
            state.projectTree?.files.keys.sorted(),
            ["../Core/Package.swift", "App.xcworkspace/contents.xcworkspacedata", "Package.swift"]
        )
    }

    // A run of a test plan lists its copy by the files the plan recorded, so the workspaces and manifests among them
    // are what the step reads, in the project.
    func test_inATestPlansRun_codeOutsideTheProject_isFoundFromThePlansFiles() async throws {
        let files = [
            "Package.swift": #"let package = Package(dependencies: [.package(path: "../Core")])"#,
            "App.xcworkspace/contents.xcworkspacedata":
                #"<Workspace version = "1.0"><FileRef location = "group:../Other/Other.xcodeproj"/></Workspace>"#,
        ]
        try write(files, in: project)
        try write(files, in: copy)
        let root = (project as NSString).deletingLastPathComponent
        try write(["Core/Package.swift": "core", "Other/Other.xcodeproj/project.pbxproj": "other"], in: root)
        let listed = recordListings([])
        try testPlan(at: "\(project)/muter-mappings.json", mutatedFiles: nil, sources: projectTree(of: files))
        let said = recordPaths(of: .codeOutsideTheProjectBuilt)

        _ = try await sut.run(with: state)

        XCTAssertEqual(said.value, [["../Core", "../Other/Other.xcodeproj"]])
        XCTAssertEqual(listed.value.map(\.lastPathComponent), ["Core"], "the project was listed")
    }

    // A workspace that names the project's own Xcode project by an absolute path makes the copy build the project's,
    // unmutated, so the step warns of it once. It isn't outside the project, so the notice says nothing.
    func test_codeInTheProjectNamedByAnAbsolutePath_isWarnedOfOnce() async throws {
        let files = [
            "App.xcworkspace/contents.xcworkspacedata":
                #"<Workspace version = "1.0"><FileRef location = "absolute:\#(project)/App.xcodeproj"/></Workspace>"#,
            "App.xcodeproj/project.pbxproj": "app",
        ]
        try write(files, in: project)
        try write(files, in: copy)
        _ = recordListings(Array(files.keys))
        let said = recordPaths(of: .codeOutsideTheProjectBuilt)
        let warned = recordPaths(of: .projectCodeNamedByAbsolutePath)

        _ = try await sut.run(with: state)

        XCTAssertEqual(warned.value, [["App.xcodeproj"]])
        XCTAssertEqual(said.value, [])
    }

    // A project whose workspaces and manifests name only code in it, by relative paths, says nothing about either.
    func test_noCodeOutsideTheProject_saysNothing() async throws {
        let files = [
            "Package.swift": #"let package = Package(dependencies: [.package(path: "Packages/Core")])"#,
            "App.xcworkspace/contents.xcworkspacedata": """
            <Workspace version = "1.0">
               <FileRef location = "self:"/>
               <FileRef location = "group:App.xcodeproj"/>
               <FileRef location = "container:Packages/Core"/>
            </Workspace>
            """,
            "App.xcodeproj/project.pbxproj": "app",
            "Packages/Core/Package.swift": "core",
        ]
        try write(files, in: project)
        try write(files, in: copy)
        _ = recordListings(Array(files.keys))
        let said = recordPaths(of: .codeOutsideTheProjectBuilt)
        let warned = recordPaths(of: .projectCodeNamedByAbsolutePath)

        _ = try await sut.run(with: state)

        XCTAssertEqual(said.value, [])
        XCTAssertEqual(warned.value, [])
    }

    // LoadResumeState found the project as the last session left it, and the copy holds the same files.
    func test_onResume_anUnchangedCopy_passes() async throws {
        let files = ["README.md": "readme", "Sources/Sum.swift": "sum"]
        try write(files, in: copy)
        current.listProjectFiles = { _ in Array(files.keys) }
        let recorded = try projectTree(of: files)
        try resume(recorded)

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes, [.projectTreeFingerprinted(recorded), .projectChangesWaived([])])
    }

    // A file edited while the project was copied: only this check sees it. Its message doesn't say nothing was copied.
    func test_onResume_aChangeDuringTheCopy_refusesAfterIt() async throws {
        try write(["README.md": "readme", "Sources/Sum.swift": "edited as it was copied"], in: copy)
        current.listProjectFiles = { _ in ["README.md", "Sources/Sum.swift"] }
        try resume(projectTree(of: ["README.md": "readme", "Sources/Sum.swift": "sum"]))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? ResumeRefused,
                ResumeRefused(
                    path: self.resultsPath,
                    reasons: [.filesChanged([.init(path: "Sources/Sum.swift", kind: .changed)])],
                    beforeTheCopy: false
                )
            )
        }
        XCTAssertNil(state.projectTree)
    }

    // The header records which changes were let through.
    func test_onResume_waivedChanges_areHandedToTheState() async throws {
        try write(["README.md": "a changed readme", "notes.txt": "new notes", "Sources/Sum.swift": "sum"], in: copy)
        current.listProjectFiles = { _ in ["README.md", "notes.txt", "Sources/Sum.swift"] }
        try resume(
            projectTree(of: ["README.md": "readme", "Sources/Sum.swift": "sum"]),
            ignoring: ["./README.md", "*.txt"]
        )

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(state.resumeWaived, ["README.md", "notes.txt"])
        XCTAssertEqual(state.projectTree?.files.keys.sorted(), ["README.md", "Sources/Sum.swift", "notes.txt"])
    }

    // A reuse is never refused for changed files: each session's changes since its own tree decide which of its
    // results it keeps. A session that resumed the run after a waived change has another tree than the first.
    func test_onReuse_eachSessionsChanges_areHandedToTheState_testFilesReadFromTheCopy() async throws {
        let first = ["README.md": "readme", "Sources/Sum.swift": "sum", "Tests/SumTests/SumTests.swift": "old tests"]
        let second = first.merging(["README.md": "a changed readme"]) { $1 }
        let tests = "import Testing\n@Test func adds() {}"
        let now = second.merging(["Tests/SumTests/SumTests.swift": tests, "notes.txt": "new"]) { $1 }
        try write(now, in: copy)
        current.listProjectFiles = { _ in Array(now.keys) }
        state.runOptions = .make(reuseURL: URL(fileURLWithPath: resultsPath), resumeIgnoring: ["*.txt"])
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [
                ResultsHeader.make(project: projectTree(of: first)),
                ResultsHeader.make(
                    formatVersion: 2,
                    session: 2,
                    project: projectTree(of: second),
                    waived: ["README.md"]
                ),
            ],
            file: nil
        )

        state.apply(try await sut.run(with: state))

        let changes = try XCTUnwrap(state.reuseChanges)
        XCTAssertEqual(changes.keys.sorted(), [1, 2])
        XCTAssertEqual(changes[1]?.otherFiles, [.init(path: "README.md", kind: .changed)])
        XCTAssertEqual(changes[2]?.otherFiles, [])
        for session in [1, 2] {
            XCTAssertEqual(changes[session]?.waived, ["notes.txt"])
            XCTAssertEqual(changes[session]?.testFiles, [.init(path: "Tests/SumTests/SumTests.swift", kind: .changed)])
            XCTAssertEqual(changes[session]?.testSources, ["Tests/SumTests/SumTests.swift": tests])
        }
        XCTAssertEqual(state.resumeWaived, ["notes.txt"])
        XCTAssertNotNil(state.projectTree)
    }

    // The last session's report is still in the project, although this run writes its report elsewhere, or none.
    func test_onResume_theRecordedReportPaths_arentChanges() async throws {
        try write(["README.md": "readme", "old-report.txt": "the last session's report"], in: copy)
        current.listProjectFiles = { _ in ["README.md", "old-report.txt"] }
        let files = ["README.md": FileDigest.sha256(of: Data("readme".utf8))]
        try resume(
            ProjectTree(
                listedBy: .git,
                files: files,
                excluded: ["old-report.partial.txt", "old-report.txt"],
                treeSHA256: ProjectTree.treeHash(of: files)
            )
        )

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(state.projectTree?.files, files)
        XCTAssertEqual(state.projectTree?.excluded, ["muter.conf.yml", "old-report.partial.txt", "old-report.txt"])
        XCTAssertEqual(state.resumeWaived, [])
    }

    // A test plan's run copies nothing: it records the plan's copy as it is tested, once it is locked. The plan file,
    // which the project may hold anywhere and the copy doesn't, is left out.
    func test_inATestPlansRun_theCopyIsHashedAsTested_andThePlanLeftOut() async throws {
        let said = recordCopyEdits()
        let left = "let sum = a + b"
        testPlan(at: "\(project)/plans/plan.json", mutatedFiles: ["Sources/Sum.swift": sha256(left)])
        try write(["README.md": "readme", "Sources/Sum.swift": "let sum = 1", "plans/plan.json": "{}"], in: project)
        try write(["README.md": "readme", "Sources/Sum.swift": left], in: copy)
        let listed = Locked<[URL]>([])
        current.listProjectFiles = { directory in
            listed.change { $0.append(directory) }
            return ["README.md", "Sources/Sum.swift", "plans/plan.json"]
        }

        let changes = try await sut.run(with: state)

        XCTAssertEqual(listed.value, [state.projectDirectoryURL])
        let files = ["README.md": sha256("readme"), "Sources/Sum.swift": sha256(left)]
        XCTAssertEqual(
            changes,
            [
                .projectTreeFingerprinted(
                    ProjectTree(
                        listedBy: .git,
                        files: files,
                        excluded: ["muter.conf.yml", "plans/plan.json"],
                        treeSHA256: ProjectTree.treeHash(of: files)
                    )
                ),
            ]
        )
        XCTAssertEqual(said.value, [], "the copy holds what the plan left there")
    }

    // A fix by hand is never refused: the run says which files with mutants differ from what the plan left in the
    // copy, and tests them as they are. A file outside the copy isn't compared.
    func test_inATestPlansRun_aFileFixedByHand_isSaid_andTestedAsItIs() async throws {
        let said = recordCopyEdits()
        testPlan(
            at: "\(project)/muter-mappings.json",
            mutatedFiles: [
                "Sources/Sum.swift": sha256("let sum = a + b"),
                "Sources/Max.swift": sha256("let max = 2"),
                "/elsewhere/Outside.swift": sha256("outside"),
            ]
        )
        let files = ["Sources/Sum.swift": "let sum = a + b // fixed by hand", "Sources/Max.swift": "let max = 2"]
        try write(files, in: copy)
        current.listProjectFiles = { _ in Array(files.keys) }

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(said.value, [["Sources/Sum.swift"]])
        XCTAssertEqual(state.projectTree?.files["Sources/Sum.swift"], sha256("let sum = a + b // fixed by hand"))
    }

    // A plan in format 0 doesn't record what it left in the copy, so nothing is compared.
    func test_inATestPlansRun_ofAPlanThatRecordsNoFiles_nothingIsSaid() async throws {
        let said = recordCopyEdits()
        testPlan(at: "\(project)/muter-mappings.json", mutatedFiles: nil)
        try write(["Sources/Sum.swift": "let sum = 1"], in: copy)
        current.listProjectFiles = { _ in ["Sources/Sum.swift"] }

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(said.value, [])
        XCTAssertEqual(state.projectTree?.files, ["Sources/Sum.swift": sha256("let sum = 1")])
    }

    // A resumed plan run's last session recorded the copy it tested. A fix by hand since then changes what its results
    // would be, so it is refused as a changed project file is, before anything is built or tested. A plan run copies
    // and removes nothing, which the message says.
    func test_aResumedTestPlansRun_whoseCopyChanged_isRefused() async throws {
        let recorded = try projectTree(of: ["README.md": "readme", "Sources/Sum.swift": "let sum = a + b"])
        try write(["README.md": "readme", "Sources/Sum.swift": "let sum = a + b // fixed by hand"], in: copy)
        current.listProjectFiles = { _ in ["README.md", "Sources/Sum.swift"] }
        try resumePlan(recorded)

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? ResumeRefused,
                ResumeRefused(
                    path: self.resultsPath,
                    reasons: [.copyChanged([.init(path: "Sources/Sum.swift", kind: .changed)], copy: self.copy)],
                    beforeTheCopy: true
                )
            )
        }
    }

    func test_aResumedTestPlansRun_whoseCopyChanged_goesAheadWithResumeIgnoring() async throws {
        let recorded = try projectTree(of: ["README.md": "readme", "Sources/Sum.swift": "let sum = a + b"])
        try write(["README.md": "readme", "Sources/Sum.swift": "let sum = a + b // fixed by hand"], in: copy)
        current.listProjectFiles = { _ in ["README.md", "Sources/Sum.swift"] }
        try resumePlan(recorded, ignoring: ["Sources/*"])

        let changes = try await sut.run(with: state)
        state.apply(changes)

        XCTAssertEqual(state.resumeWaived, ["Sources/Sum.swift"])
        XCTAssertEqual(state.projectTree?.files["Sources/Sum.swift"], sha256("let sum = a + b // fixed by hand"))
    }

    func test_aResumedTestPlansRun_whoseCopyIsUnchanged_goesAhead() async throws {
        let files = ["README.md": "readme", "Sources/Sum.swift": "let sum = a + b"]
        try write(files, in: copy)
        current.listProjectFiles = { _ in Array(files.keys) }
        try resumePlan(projectTree(of: files))

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(state.resumeWaived, [])
        XCTAssertEqual(state.projectTree?.files, try projectTree(of: files).files)
    }

    // The copy's files are those the plan recorded, not those the project lists now: a file the project added since is
    // the project's, not the copy's, and the project isn't listed.
    func test_inATestPlansRun_theCopysFilesAreThoseThePlanRecorded() async throws {
        let files = ["README.md": "readme", "Sources/Sum.swift": "let sum = a + b"]
        try write(files.merging(["notes.txt": "added since"]) { $1 }, in: copy)
        let listed = recordListings(["README.md", "Sources/Sum.swift", "notes.txt"])
        try testPlan(
            at: "\(project)/muter-mappings.json",
            mutatedFiles: nil,
            sources: projectTree(of: files, by: .walk)
        )

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(listed.value, [], "the project was listed")
        XCTAssertEqual(state.projectTree?.files, try projectTree(of: files).files)
        XCTAssertEqual(state.projectTree?.listedBy, .walk, "as the plan's files were found")
    }

    // A file the project no longer lists, as after `git rm` or a switch to another branch, is still the copy's: the
    // copy is compared by the files the last session recorded, so it isn't taken for a fix by hand.
    func test_aResumedTestPlansRun_whoseProjectNoLongerListsAFile_goesAhead() async throws {
        let files = ["README.md": "readme", "Sources/Sum.swift": "let sum = a + b", "Tests/Fixtures/data.json": "{}"]
        try write(files, in: copy)
        let listed = recordListings(["README.md", "Sources/Sum.swift"])
        try resumePlan(projectTree(of: files))

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(listed.value, [], "the project was listed")
        XCTAssertEqual(state.resumeWaived, [])
        XCTAssertEqual(state.projectTree?.files, try projectTree(of: files).files)
    }

    func test_aResumedTestPlansRun_whoseCopyChangedAFileTheProjectNoLongerLists_isRefused() async throws {
        let files = ["README.md": "readme", "Sources/Sum.swift": "let sum = a + b", "Tests/Fixtures/data.json": "{}"]
        try write(files.merging(["Tests/Fixtures/data.json": "{\"fixed\": true}"]) { $1 }, in: copy)
        _ = recordListings(["README.md", "Sources/Sum.swift"])
        try resumePlan(projectTree(of: files))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? ResumeRefused,
                ResumeRefused(
                    path: self.resultsPath,
                    reasons: [
                        .copyChanged([.init(path: "Tests/Fixtures/data.json", kind: .changed)], copy: self.copy),
                    ],
                    beforeTheCopy: true
                )
            )
        }
    }

    // xcodebuild builds in the plan's copy, which keeps the build from one session to the next, and copies it to
    // TestContents: neither is the copy's own change, whatever Swift it generates, wherever -derivedDataPath puts it.
    func test_aResumedXcodebuildTestPlansRun_leavesOutTheBuildItWroteInTheCopy() async throws {
        let files = ["Sources/Sum.swift": "let sum = a + b"]
        let generated = "Build/Intermediates.noindex/App.build/DerivedSources/GeneratedAssetSymbols.swift"
        try write(
            files.merging(["TestContents/\(generated)": "generated", "build/\(generated)": "generated"]) { $1 },
            in: copy
        )
        _ = recordListings(Array(files.keys))
        try resumePlan(
            projectTree(of: files),
            configuration: MuterConfiguration(
                executable: "/usr/bin/xcodebuild",
                arguments: ["-scheme", "App", "-derivedDataPath", "build", "test"]
            )
        )

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(state.projectTree?.files, try projectTree(of: files).files)
    }

    // A run without a plan copies the project afresh each session, so its fingerprint leaves out nothing more.
    func test_aRunWithoutAPlan_keepsTheFoldersAPlansRunLeavesOut() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        try write(["Sources/Sum.swift": "sum", "TestContents/Generated.swift": "generated"], in: copy)
        _ = recordListings(["Sources/Sum.swift"])

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(state.projectTree?.files.keys.sorted(), ["Sources/Sum.swift", "TestContents/Generated.swift"])
    }

    // A Package.resolved the project didn't have when the plan was made, as one it ignores, is the copy's build's:
    // when it changes, as the build resolves the dependencies, it is said, and the run goes ahead.
    func test_aResumedTestPlansRun_whoseBuildWroteAPackageResolved_goesAhead_andSaysIt() async throws {
        let said = recordResolutionChanges()
        let files = ["Package.swift": "// swift-tools-version:6.0", "Sources/Sum.swift": "let sum = a + b"]
        try write(files.merging(["Package.resolved": "{}"]) { $1 }, in: copy)
        _ = recordListings(Array(files.keys))
        try resumePlan(projectTree(of: files), sources: projectTree(of: files))

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(said.value, [[.init(path: "Package.resolved", kind: .added)]])
        XCTAssertEqual(state.resumeWaived, [])
        XCTAssertEqual(state.projectTree?.files["Package.resolved"], sha256("{}"))
    }

    // One the project had is the plan's: a change to it in the copy is refused as any other.
    func test_aResumedTestPlansRun_whosePackageResolvedThePlanRecordedChanged_isRefused() async throws {
        let said = recordResolutionChanges()
        let files = ["Package.resolved": "{\"pins\": []}", "Sources/Sum.swift": "let sum = a + b"]
        try write(files.merging(["Package.resolved": "{}"]) { $1 }, in: copy)
        _ = recordListings(Array(files.keys))
        try resumePlan(projectTree(of: files), sources: projectTree(of: files))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? ResumeRefused,
                ResumeRefused(
                    path: self.resultsPath,
                    reasons: [.copyChanged([.init(path: "Package.resolved", kind: .changed)], copy: self.copy)],
                    beforeTheCopy: true
                )
            )
        }
        XCTAssertEqual(said.value, [])
    }
}

private extension FingerprintProjectTreeTests {
    /// Resumes a run of the plan in the project, whose last session recorded `recorded` as the copy it tested.
    /// The plan recorded the project's files as `sources`, and the run builds with `configuration` if given.
    func resumePlan(
        _ recorded: ProjectTree,
        ignoring globs: [String] = [],
        sources: ProjectTree? = nil,
        configuration: MuterConfiguration? = nil
    ) throws {
        let plan = "\(project)/muter-mappings.json"
        if let configuration {
            state.muterConfiguration = configuration
        }
        state.runOptions = .make(
            testPlanURL: URL(fileURLWithPath: plan),
            resumeURL: URL(fileURLWithPath: resultsPath),
            resumeIgnoring: globs
        )
        state.testPlan = LoadedTestPlan(
            path: plan,
            sha256: "91a",
            formatVersion: TestPlanCoding.formatVersion,
            swiftMutatorVersion: "16",
            scope: nil,
            sources: sources,
            mutatedFiles: nil,
            linkedFiles: nil,
            mutatedPaths: []
        )
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [ResultsHeader.make(project: recorded, usingTestPlan: true), ResultsEnd.make()],
            file: resultsFiles.openForResume(at: resultsPath)
        )
    }

    /// A run of the plan at `path`, which left `mutatedFiles` in the copy, and recorded the project's files as
    /// `sources`.
    func testPlan(at path: String, mutatedFiles: [String: String]?, sources: ProjectTree? = nil) {
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: path))
        state.testPlan = LoadedTestPlan(
            path: path,
            sha256: "",
            formatVersion: mutatedFiles == nil ? 0 : TestPlanCoding.formatVersion,
            swiftMutatorVersion: nil,
            scope: nil,
            sources: sources,
            mutatedFiles: mutatedFiles,
            linkedFiles: nil,
            mutatedPaths: []
        )
    }

    /// The paths of each event named `name` sent from now on, until the test ends.
    func recordPaths(of name: RunEvent.Name) -> Locked<[[String]]> {
        let said = Locked<[[String]]>([])
        let subscription = runEvents.observe(name) { event in
            said.change { $0.append(event.object as? [String] ?? []) }
        }
        addTeardownBlock { subscription.cancel() }
        return said
    }

    /// The paths of each `testPlanCopyEdited` sent from now on, until the test ends.
    func recordCopyEdits() -> Locked<[[String]]> {
        let said = Locked<[[String]]>([])
        let subscription = runEvents.observe(.testPlanCopyEdited) { event in
            said.change { $0.append(event.object as? [String] ?? []) }
        }
        addTeardownBlock { subscription.cancel() }
        return said
    }

    /// The changes of each `testPlanCopyResolutionChanged` sent from now on, until the test ends.
    func recordResolutionChanges() -> Locked<[[ProjectTree.FileChange]]> {
        let said = Locked<[[ProjectTree.FileChange]]>([])
        let subscription = runEvents.observe(.testPlanCopyResolutionChanged) { event in
            said.change { $0.append(event.object as? [ProjectTree.FileChange] ?? []) }
        }
        addTeardownBlock { subscription.cancel() }
        return said
    }

    /// Lists `paths` for the project, and records each folder listed.
    func recordListings(_ paths: [String]) -> Locked<[URL]> {
        let listed = Locked<[URL]>([])
        current.listProjectFiles = { directory in
            listed.change { $0.append(directory) }
            return paths
        }
        return listed
    }

    func sha256(_ text: String) -> String {
        FileDigest.sha256(of: Data(text.utf8))
    }

    /// Resumes a run whose last session recorded `recorded`.
    func resume(_ recorded: ProjectTree, ignoring globs: [String] = []) throws {
        state.runOptions = .make(resumeURL: URL(fileURLWithPath: resultsPath), resumeIgnoring: globs)
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [ResultsHeader.make(project: recorded), ResultsEnd.make()],
            file: resultsFiles.openForResume(at: resultsPath)
        )
    }

    /// The tree of `files`, each a path relative to the project and its contents, as listed by `listing`, and as a run
    /// that loads the project's own configuration records it.
    func projectTree(of files: [String: String], by listing: ProjectTree.Listing = .git) throws -> ProjectTree {
        let hashes = files.mapValues { FileDigest.sha256(of: Data($0.utf8)) }
        return ProjectTree(
            listedBy: listing,
            files: hashes,
            excluded: ["muter.conf.yml"],
            treeSHA256: ProjectTree.treeHash(of: hashes)
        )
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
