@testable import muterCore
import TestingExtensions
import XCTest

/// Real folders for the project and its copy, and an injected listing in place of git.
final class FingerprintProjectTreeTests: MuterTestCase {
    let state = MutationTestState()
    let sut = FingerprintProjectTree()
    var project = ""
    var copyPath = ""
    let resultsPath = "/project_muter_logs/session 1/results.jsonl"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = try makeTemporaryDirectory()
        project = "\(root)/project"
        copyPath = "\(root)/project_mutated"
        state.projectDirectoryURL = URL(fileURLWithPath: project)
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: copyPath)
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
            in: copyPath
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
        try write(copied, in: copyPath)
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
        try write(["Sources/Sum.swift": "sum"], in: copyPath)
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
        try write(projectFiles, in: copyPath)
        let root = self.project.deletingLastPathComponent
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
        try write(files, in: copyPath)
        let root = project.deletingLastPathComponent
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
        try write(files, in: copyPath)
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
        try write(files, in: copyPath)
        _ = recordListings(Array(files.keys))
        let said = recordPaths(of: .codeOutsideTheProjectBuilt)
        let warned = recordPaths(of: .projectCodeNamedByAbsolutePath)

        _ = try await sut.run(with: state)

        XCTAssertEqual(said.value, [])
        XCTAssertEqual(warned.value, [])
    }
}
