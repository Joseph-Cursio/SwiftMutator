@testable import muterCore
import TestingExtensions
import XCTest

extension FingerprintProjectTreeTests {
    // A test plan's run copies nothing: it records the plan's copy as it is tested, once it is locked. The plan file,
    // which the project may hold anywhere and the copy doesn't, is left out.
    func test_inATestPlansRun_theCopyIsHashedAsTested_andThePlanLeftOut() async throws {
        let said = recordCopyEdits()
        let left = "let sum = a + b"
        testPlan(at: "\(project)/plans/plan.json", mutatedFiles: ["Sources/Sum.swift": sha256(left)])
        try write(["README.md": "readme", "Sources/Sum.swift": "let sum = 1", "plans/plan.json": "{}"], in: project)
        try write(["README.md": "readme", "Sources/Sum.swift": left], in: copyPath)
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
        try write(files, in: copyPath)
        current.listProjectFiles = { _ in Array(files.keys) }

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(said.value, [["Sources/Sum.swift"]])
        XCTAssertEqual(state.projectTree?.files["Sources/Sum.swift"], sha256("let sum = a + b // fixed by hand"))
    }

    // A plan in format 0 doesn't record what it left in the copy, so nothing is compared.
    func test_inATestPlansRun_ofAPlanThatRecordsNoFiles_nothingIsSaid() async throws {
        let said = recordCopyEdits()
        testPlan(at: "\(project)/muter-mappings.json", mutatedFiles: nil)
        try write(["Sources/Sum.swift": "let sum = 1"], in: copyPath)
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
        try write(["README.md": "readme", "Sources/Sum.swift": "let sum = a + b // fixed by hand"], in: copyPath)
        current.listProjectFiles = { _ in ["README.md", "Sources/Sum.swift"] }
        try resumePlan(recorded)

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? ResumeRefused,
                ResumeRefused(
                    path: self.resultsPath,
                    reasons: [.copyChanged([.init(path: "Sources/Sum.swift", kind: .changed)], copy: self.copyPath)],
                    beforeTheCopy: true
                )
            )
        }
    }

    func test_aResumedTestPlansRun_whoseCopyChanged_goesAheadWithResumeIgnoring() async throws {
        let recorded = try projectTree(of: ["README.md": "readme", "Sources/Sum.swift": "let sum = a + b"])
        try write(["README.md": "readme", "Sources/Sum.swift": "let sum = a + b // fixed by hand"], in: copyPath)
        current.listProjectFiles = { _ in ["README.md", "Sources/Sum.swift"] }
        try resumePlan(recorded, ignoring: ["Sources/*"])

        let changes = try await sut.run(with: state)
        state.apply(changes)

        XCTAssertEqual(state.resumeWaived, ["Sources/Sum.swift"])
        XCTAssertEqual(state.projectTree?.files["Sources/Sum.swift"], sha256("let sum = a + b // fixed by hand"))
    }

    func test_aResumedTestPlansRun_whoseCopyIsUnchanged_goesAhead() async throws {
        let files = ["README.md": "readme", "Sources/Sum.swift": "let sum = a + b"]
        try write(files, in: copyPath)
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
        try write(files.merging(["notes.txt": "added since"]) { $1 }, in: copyPath)
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
        try write(files, in: copyPath)
        let listed = recordListings(["README.md", "Sources/Sum.swift"])
        try resumePlan(projectTree(of: files))

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(listed.value, [], "the project was listed")
        XCTAssertEqual(state.resumeWaived, [])
        XCTAssertEqual(state.projectTree?.files, try projectTree(of: files).files)
    }

    func test_aResumedTestPlansRun_whoseCopyChangedAFileTheProjectNoLongerLists_isRefused() async throws {
        let files = ["README.md": "readme", "Sources/Sum.swift": "let sum = a + b", "Tests/Fixtures/data.json": "{}"]
        try write(files.merging(["Tests/Fixtures/data.json": "{\"fixed\": true}"]) { $1 }, in: copyPath)
        _ = recordListings(["README.md", "Sources/Sum.swift"])
        try resumePlan(projectTree(of: files))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? ResumeRefused,
                ResumeRefused(
                    path: self.resultsPath,
                    reasons: [
                        .copyChanged([.init(path: "Tests/Fixtures/data.json", kind: .changed)], copy: self.copyPath),
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
            in: copyPath
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
        try write(["Sources/Sum.swift": "sum", "TestContents/Generated.swift": "generated"], in: copyPath)
        _ = recordListings(["Sources/Sum.swift"])

        state.apply(try await sut.run(with: state))

        XCTAssertEqual(state.projectTree?.files.keys.sorted(), ["Sources/Sum.swift", "TestContents/Generated.swift"])
    }

    // A Package.resolved the project didn't have when the plan was made, as one it ignores, is the copy's build's:
    // when it changes, as the build resolves the dependencies, it is said, and the run goes ahead.
    func test_aResumedTestPlansRun_whoseBuildWroteAPackageResolved_goesAhead_andSaysIt() async throws {
        let said = recordResolutionChanges()
        let files = ["Package.swift": "// swift-tools-version:6.0", "Sources/Sum.swift": "let sum = a + b"]
        try write(files.merging(["Package.resolved": "{}"]) { $1 }, in: copyPath)
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
        try write(files.merging(["Package.resolved": "{}"]) { $1 }, in: copyPath)
        _ = recordListings(Array(files.keys))
        try resumePlan(projectTree(of: files), sources: projectTree(of: files))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? ResumeRefused,
                ResumeRefused(
                    path: self.resultsPath,
                    reasons: [.copyChanged([.init(path: "Package.resolved", kind: .changed)], copy: self.copyPath)],
                    beforeTheCopy: true
                )
            )
        }
        XCTAssertEqual(said.value, [])
    }
}
