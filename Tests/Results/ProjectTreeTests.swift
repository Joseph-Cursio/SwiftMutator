@testable import muterCore
import XCTest

/// Real folders and a real git: `git init` and `git add`, never a commit.
final class ProjectTreeTests: XCTestCase {
    private var project = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        project = try makeTemporaryDirectory()
    }

    func test_listsTrackedAndUntrackedFiles_butNotIgnoredOnes() throws {
        try write([
            ".gitignore": "*.log\nbuild/\n",
            "README.md": "readme",
            "Sources/Sum/Sum.swift": "sum",
            "notes.txt": "untracked",
            "debug.log": "ignored",
            "build/output.txt": "ignored",
        ])
        try git("init", in: project)
        try git("add", ".gitignore", "README.md", "Sources", in: project)

        let tree = fingerprint()

        XCTAssertEqual(tree.listedBy, .git)
        XCTAssertEqual(tree.files.keys.sorted(), [".gitignore", "README.md", "Sources/Sum/Sum.swift", "notes.txt"])
        XCTAssertEqual(tree.files["Sources/Sum/Sum.swift"], digest(of: "Sources/Sum/Sum.swift"))
        XCTAssertEqual(tree.files["notes.txt"], digest(of: "notes.txt"))
    }

    func test_aTrackedFileThatIsIgnored_isStillListed() throws {
        try write([
            ".gitignore": "Tests/Fixtures/*.json\n",
            "Tests/Fixtures/tracked.json": "{}",
            "Tests/Fixtures/ignored.json": "{}",
        ])
        try git("init", in: project)
        try git("add", ".gitignore", in: project)
        try git("add", "-f", "Tests/Fixtures/tracked.json", in: project)

        XCTAssertEqual(fingerprint().files.keys.sorted(), [".gitignore", "Tests/Fixtures/tracked.json"])
    }

    func test_alwaysAddsSwiftAndPackageFiles_evenWhenIgnored() throws {
        try write([
            ".gitignore": "*\n",
            "Package.swift": "manifest",
            "Package@swift-5.9.swift": "manifest",
            "Package.resolved": "pins",
            ".swift-version": "6.4",
            "Sources/Generated/Generated.swift": "generated",
            "Sub/Package.resolved": "a nested package's pins",
            "Sub/.swift-version": "6.3",
            "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved": "Xcode's pins",
            "App.xcworkspace/xcshareddata/swiftpm/Package.resolved": "Xcode's pins",
            "App.xcodeproj/project.pbxproj": "ignored",
            "notes.txt": "ignored",
        ])
        try git("init", in: project)

        XCTAssertEqual(fingerprint().files.keys.sorted(), [
            ".swift-version",
            "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "App.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "Package.resolved",
            "Package.swift",
            "Package@swift-5.9.swift",
            "Sources/Generated/Generated.swift",
            "Sub/.swift-version",
        ])
    }

    func test_prunesBuildGitSwiftPMDerivedDataAndXcuserdata_atAnyDepth() throws {
        try write([
            "Sources/Sum.swift": "kept",
            "Sub/muter-mappings.json": "kept: only the root's is SwiftMutator's",
            ".build/checkouts/Dependency/Sources/Dependency.swift": "pruned",
            "Sub/.build/debug/Generated.swift": "pruned",
            ".swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata": "pruned",
            "Sub/.swiftpm/configuration/Package.resolved": "pruned",
            "DerivedData/Build/Intermediates.swift": "pruned",
            "App.xcodeproj/xcuserdata/me.xcuserdatad/xcschemes/App.xcscheme": "pruned",
            ".DS_Store": "pruned",
            "Sources/.DS_Store": "pruned",
            "muter-mappings.json": "pruned",
            ".swiftmutator-active-mutant": "pruned",
            "muter.xctestrun": "pruned",
        ])
        try git("init", in: project)
        try git("add", "-f", ".", in: project)
        let kept = ["Sources/Sum.swift", "Sub/muter-mappings.json"]

        XCTAssertEqual(fingerprint().files.keys.sorted(), kept, "listed by git")
        XCTAssertEqual(fingerprint(list: { _ in nil }).files.keys.sorted(), kept, "walked")
        XCTAssertTrue(ProjectTree.isPruned(".git/config"))
        XCTAssertTrue(ProjectTree.isPruned("Sub/.git/HEAD"))
    }

    func test_leavesOutTheExcludedReportAndItsPartialSibling() throws {
        let folders = try makeDirectoryWithSymbolicLink()
        project = folders.directory
        try write(["Sources/Sum.swift": "sum", "report.txt": "report", "report.partial.txt": "partial report"])
        // Spelled through a symbolic link, as `/tmp` is `/private/tmp`, it is still inside the project.
        let options = Run.Options.make(reportURL: URL(fileURLWithPath: "\(folders.link)/report.txt"))

        let excluded = ProjectTree.reportPaths(options, under: projectURL)
        let tree = fingerprint(excluding: excluded, list: { _ in nil })

        XCTAssertEqual(excluded, ["report.txt", "report.partial.txt"])
        XCTAssertEqual(tree.files.keys.sorted(), ["Sources/Sum.swift"])
        XCTAssertEqual(tree.excluded, ["report.partial.txt", "report.txt"])
        XCTAssertEqual(
            ProjectTree.reportPaths(.make(reportURL: URL(fileURLWithPath: "\(project)/out/report")), under: projectURL),
            ["out/report", "out/report.partial"]
        )
        XCTAssertEqual(
            ProjectTree.reportPaths(.make(reportURL: URL(fileURLWithPath: "\(project)_report.txt")), under: projectURL),
            [],
            "a report beside the project, not inside it"
        )
        XCTAssertEqual(ProjectTree.reportPaths(.make(), under: projectURL), [], "no report")
    }

    // A run leaves its configuration file out too: its settings are in the header, which a resume compares key by key.
    func test_excludedPaths_addTheConfigurationFileTheRunLoads() throws {
        let report = URL(fileURLWithPath: "\(project)/report.txt")
        XCTAssertEqual(
            ProjectTree.excludedPaths(.make(reportURL: report), under: projectURL),
            ["report.txt", "report.partial.txt", "muter.conf.yml"]
        )
        let named = URL(fileURLWithPath: "\(project)/Config/ci.yml")
        XCTAssertEqual(ProjectTree.excludedPaths(.make(configurationURL: named), under: projectURL), ["Config/ci.yml"])
        let folder = URL(fileURLWithPath: "\(project)/Config")
        XCTAssertEqual(
            ProjectTree.excludedPaths(.make(configurationURL: folder), under: projectURL),
            ["Config/muter.conf.yml"]
        )
        let outside = URL(fileURLWithPath: "\(project)_configuration.yml")
        XCTAssertEqual(ProjectTree.excludedPaths(.make(configurationURL: outside), under: projectURL), [])
    }

    func test_doesNotDescendIntoAnIgnoredNestedCheckout() throws {
        try write([
            ".gitignore": "/.claude/\n",
            "Sources/Sum.swift": "sum",
            ".claude/worktrees/x/.git": "gitdir: /elsewhere/.git/worktrees/x\n",
            ".claude/worktrees/x/Sources/Sum.swift": "another checkout's",
            ".claude/notes/Draft.swift": "ignored, but Swift",
        ])
        try git("init", in: project)
        try git("add", ".gitignore", "Sources", in: project)

        XCTAssertEqual(fingerprint().files.keys.sorted(), [
            ".claude/notes/Draft.swift",
            ".gitignore",
            "Sources/Sum.swift",
        ])
    }

    func test_listsANestedRepository_throughItsOwnListing() throws {
        try write([
            "Sources/Sum.swift": "sum",
            "vendor/lib/a.json": "a fixture",
            "vendor/lib/b.log": "ignored by the nested repository",
            "vendor/lib/.gitignore": "*.log\n",
        ])
        try git("init", in: project)
        try git("add", "Sources", in: project)
        try git("init", in: "\(project)/vendor/lib")
        try git("add", "a.json", in: "\(project)/vendor/lib")

        XCTAssertEqual(GitFileListing.list(in: projectURL)?.contains("vendor/lib/a.json"), true)
        XCTAssertEqual(fingerprint().files.keys.sorted(), [
            "Sources/Sum.swift",
            "vendor/lib/.gitignore",
            "vendor/lib/a.json",
        ])
    }

    func test_aProjectNestedInARepository_listsItsTrackedFiles() throws {
        // The repository ignores SwiftMutator's copies: git, asked about the copy, lists nothing in it.
        let repository = project
        project = "\(repository)/proj"
        let copy = "\(repository)/proj_mutated"
        try write([
            ".gitignore": "Tests/Fixtures/*.json\n",
            "Sources/Lib/A.swift": "a",
            "Tests/Fixtures/f.json": "{}",
            "notes.txt": "untracked",
        ])
        try Data("*_mutated/\n".utf8).write(to: URL(fileURLWithPath: "\(repository)/.gitignore"))
        try git("init", in: repository)
        try git("add", ".gitignore", "proj/.gitignore", "proj/Sources", in: repository)
        try git("add", "-f", "proj/Tests/Fixtures/f.json", in: repository)
        try FileManager.default.copyItem(atPath: project, toPath: copy)

        let tree = fingerprint(hashingIn: copy)

        XCTAssertEqual(tree.listedBy, .git)
        XCTAssertEqual(tree.files.keys.sorted(), [
            ".gitignore",
            "Sources/Lib/A.swift",
            "Tests/Fixtures/f.json",
            "notes.txt",
        ])
        XCTAssertNil(GitFileListing.list(in: URL(fileURLWithPath: copy)), "why the project is listed, not the copy")
    }

    // A run started from a git hook inherits what git exports to it: a relative GIT_INDEX_FILE, -c settings as
    // GIT_CONFIG_PARAMETERS, and GIT_DIR=.git after `git --git-dir=.git commit`. In a nested project that GIT_DIR names
    // a folder that isn't there, and the files the repository tracks would be walked as if it had none.
    func test_aListingInAGitHook_leavesOutTheRepositoryVariablesItInherits() throws {
        let repository = project
        project = "\(repository)/proj"
        try write([".gitignore": "Tests/Fixtures/*.json\n", "Sources/Lib/A.swift": "a", "Tests/Fixtures/f.json": "{}"])
        try git("init", in: repository)
        try git("add", "proj/.gitignore", "proj/Sources", in: repository)
        try git("add", "-f", "proj/Tests/Fixtures/f.json", in: repository)
        setEnvironment("GIT_DIR", to: ".git")
        setEnvironment("GIT_INDEX_FILE", to: ".git/index")
        setEnvironment("GIT_CONFIG_PARAMETERS", to: "'user.name'='Me'")

        XCTAssertEqual(
            GitFileListing.list(in: projectURL),
            [".gitignore", "Sources/Lib/A.swift", "Tests/Fixtures/f.json"]
        )
        XCTAssertEqual(
            GitFileListing.environment([
                "GIT_DIR": ".git",
                "GIT_INDEX_FILE": ".git/index",
                "GIT_CONFIG_PARAMETERS": "'a.b'='c'",
                "HOME": "/Users/me",
            ]),
            ["HOME": "/Users/me", "GIT_OPTIONAL_LOCKS": "0"]
        )
    }

    // What only the user's global excludes ignore, such as a tool's settings, isn't a project file: listed, it would
    // refuse a resume each time the tool rewrote it.
    func test_theUsersGlobalExcludes_areKept() throws {
        try write(["Sources/Sum.swift": "sum", "README.md": "readme", "settings.local.json": "a tool's"])
        let configuration = try makeTemporaryDirectory()
        try Data("settings.local.json\n".utf8).write(to: URL(fileURLWithPath: "\(configuration)/ignore"))
        try Data("[core]\n\texcludesFile = \(configuration)/ignore\n".utf8)
            .write(to: URL(fileURLWithPath: "\(configuration)/config"))
        setEnvironment("GIT_CONFIG_GLOBAL", to: "\(configuration)/config")
        try git("init", in: project)

        XCTAssertEqual(GitFileListing.list(in: projectURL), ["README.md", "Sources/Sum.swift"])
    }

    // A project with no repository of its own, in a folder its enclosing repository ignores: git lists none of its
    // untracked files, and only the files forced in, so it is walked.
    func test_aProjectInAFolderItsRepositoryIgnores_isWalked() throws {
        let repository = project
        project = "\(repository)/scratch/Pkg"
        try write([
            "Sources/Pkg/A.swift": "a",
            "Tests/Fixtures/input.json": "{}",
            "muter.conf.yml": "executable: swift",
        ])
        try Data("scratch/\n".utf8).write(to: URL(fileURLWithPath: "\(repository)/.gitignore"))
        try git("init", in: repository)
        try git("add", ".gitignore", in: repository)
        let everyFile = ["Sources/Pkg/A.swift", "Tests/Fixtures/input.json", "muter.conf.yml"]

        let tree = fingerprint()

        XCTAssertNil(GitFileListing.list(in: projectURL))
        XCTAssertEqual(tree.listedBy, .walk)
        XCTAssertEqual(tree.files.keys.sorted(), everyFile)

        try git("add", "-f", "scratch/Pkg/Sources/Pkg/A.swift", in: repository)
        XCTAssertNil(GitFileListing.list(in: projectURL), "a file forced in leaves the rest unlisted")
        XCTAssertEqual(fingerprint().files.keys.sorted(), everyFile)
    }

    func test_withoutGit_walksEveryFile() throws {
        try write([
            "Sources/Sum.swift": "sum",
            "notes.txt": "notes",
            "Tests/Fixtures/f.json": "{}",
            "Nested/.git/HEAD": "not a repository git can read",
            "Nested/Sources/Lib.swift": "lib",
        ])

        let tree = fingerprint()

        XCTAssertNil(GitFileListing.list(in: projectURL), "not in a repository: git fails")
        XCTAssertEqual(tree.listedBy, .walk)
        XCTAssertEqual(tree.files.keys.sorted(), [
            "Nested/Sources/Lib.swift",
            "Sources/Sum.swift",
            "Tests/Fixtures/f.json",
            "notes.txt",
        ])
    }

    func test_aSymbolicLinkIsHashedByWhereItPoints() throws {
        try write(["Docs/rules/rule.md": "a rule", "notes.txt": "notes"])
        let manager = FileManager.default
        try manager.createDirectory(atPath: "\(project)/Sources", withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: "\(project)/Sources/rules", withDestinationPath: "../Docs/rules")
        try manager.createSymbolicLink(atPath: "\(project)/link.txt", withDestinationPath: "notes.txt")
        try git("init", in: project)
        try git("add", ".", in: project)

        let listings: [(String, ProjectFileListing)] = [("listed by git", GitFileListing.list(in:)), ("walked", { _ in nil })]
        for (name, list) in listings {
            let tree = fingerprint(list: list)

            XCTAssertEqual(tree.files.keys.sorted(), [
                "Docs/rules/rule.md",
                "Sources/rules",
                "link.txt",
                "notes.txt",
            ], name)
            XCTAssertEqual(tree.files["Sources/rules"], "link:" + sha256("../Docs/rules"), name)
            XCTAssertEqual(tree.files["link.txt"], "link:" + sha256("notes.txt"), name)
            XCTAssertNotEqual(tree.files["link.txt"], tree.files["notes.txt"], name)
        }
    }

    // SwiftMutator copies only the project, beside it, so `../Core` names the same folder from the project and the
    // copy, and every session builds whatever that folder holds then. Each local package the manifests name with a
    // literal path, theirs in turn, and those Xcode references, is listed and hashed where it is.
    func test_localPackagesOutsideTheProject_areFingerprintedWhereTheyAre() throws {
        let root = project
        project = "\(root)/App"
        try write([
            "Package.swift": """
            let package = Package(dependencies: [
                .package(path: "../Core"),
                .package(name: "Util", path: "Packages/Util"),
                // .package(path: "../Old"),
                .package(path: ".."),
            ])
            """,
            "Packages/Util/Package.swift": #"dependencies: [.package(path:"../../../Shared")]"#,
            "Sources/App/App.swift": "app",
            "App.xcodeproj/project.pbxproj": """
            isa = XCLocalSwiftPackageReference;
            \t\t\trelativePath = "../Xcode Kit";
            """,
        ])
        try write([
            "Core/Package.swift": #".package(path: "../Base")"#,
            "Core/Sources/Core/Core.swift": "core",
            "Core/.build/debug/Core.o": "a build product",
            "Base/Package.swift": "base",
            "Base/Tests/Fixtures/table.json": "{}",
            "Shared/Package.swift": "shared",
            "Xcode Kit/Package.swift": "kit",
            "Old/Package.swift": "commented out",
            "Unused/Package.swift": "named by nothing",
        ], in: root)
        let copy = "\(project)_mutated"
        try FileManager.default.copyItem(atPath: project, toPath: copy)

        let tree = fingerprint(list: { _ in nil })

        XCTAssertEqual(tree.files.keys.sorted(), [
            "../Base/Package.swift",
            "../Base/Tests/Fixtures/table.json",
            "../Core/Package.swift",
            "../Core/Sources/Core/Core.swift",
            "../Shared/Package.swift",
            "../Xcode Kit/Package.swift",
            "App.xcodeproj/project.pbxproj",
            "Package.swift",
            "Packages/Util/Package.swift",
            "Sources/App/App.swift",
        ])
        XCTAssertEqual(tree.files["../Core/Sources/Core/Core.swift"], sha256("core"))
        XCTAssertEqual(fingerprint(hashingIn: copy, list: { _ in nil }), tree, "the copy builds the same folders")

        try write(["Core/Sources/Core/Core.swift": "changed"], in: root)
        XCTAssertEqual(
            fingerprint(list: { _ in nil }).changes(since: tree),
            [.init(path: "../Core/Sources/Core/Core.swift", kind: .changed)]
        )
    }

    func test_listsTheProjectButHashesTheCopy() throws {
        try write(["Sources/Sum.swift": "sum", "notes.txt": "notes", "Gone.txt": "only in the project"])
        try git("init", in: project)
        try git("add", ".", in: project)
        let copy = "\(project)_mutated"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: copy) }
        try FileManager.default.copyItem(atPath: project, toPath: copy)
        try Data("changed in the copy".utf8).write(to: URL(fileURLWithPath: "\(copy)/Sources/Sum.swift"))
        try FileManager.default.removeItem(atPath: "\(copy)/Gone.txt")

        let tree = fingerprint(hashingIn: copy)

        XCTAssertEqual(tree.files.keys.sorted(), ["Sources/Sum.swift", "notes.txt"])
        XCTAssertEqual(tree.files["Sources/Sum.swift"], sha256("changed in the copy"))
    }

    func test_treeHash_doesNotDependOnListingOrder() throws {
        try write(["a.txt": "a", "b.txt": "b"])

        let forwards = fingerprint(list: { _ in ["a.txt", "b.txt"] })
        let backwards = fingerprint(list: { _ in ["b.txt", "a.txt"] })

        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards.treeSHA256, sha256("a.txt\0\(sha256("a"))\nb.txt\0\(sha256("b"))\n"))
        try write(["b.txt": "changed"])
        XCTAssertNotEqual(fingerprint(list: { _ in ["a.txt", "b.txt"] }).treeSHA256, forwards.treeSHA256)
    }

    func test_changes_nameChangedAddedAndRemoved_ignoringBothSessionsExclusions() {
        let recorded = tree(
            ["Same.swift": "1", "Changed.swift": "2", "Removed.txt": "3", "new-report.txt": "an earlier file"],
            excluding: ["old-report.txt"]
        )
        let now = tree(
            ["Same.swift": "1", "Changed.swift": "9", "Added.txt": "4", "old-report.txt": "now a project file"],
            excluding: ["new-report.txt"]
        )

        XCTAssertEqual(now.changes(since: recorded), [
            .init(path: "Added.txt", kind: .added),
            .init(path: "Changed.swift", kind: .changed),
            .init(path: "Removed.txt", kind: .removed),
        ])
        XCTAssertEqual(now.changes(since: now), [])
    }

    func test_partition_starMatchesSlash_andDotSlashIsDropped() {
        let changes: [ProjectTree.FileChange] = [
            .init(path: "Docs/rules/rule.md", kind: .changed),
            .init(path: "README.md", kind: .changed),
            .init(path: "notes.txt", kind: .added),
            .init(path: "Sources/Sum.swift", kind: .removed),
        ]

        let split = changes.partition(by: ["Docs/*", "./README.md", "./*.txt"])

        XCTAssertEqual(split.waived.map(\.path), ["Docs/rules/rule.md", "README.md", "notes.txt"])
        XCTAssertEqual(split.unwaived.map(\.path), ["Sources/Sum.swift"])
        XCTAssertEqual(changes.partition(by: ["*.md"]).waived.map(\.path), ["Docs/rules/rule.md", "README.md"])
        XCTAssertEqual(changes.partition(by: []).unwaived, changes)
    }
}

private extension ProjectTreeTests {
    var projectURL: URL { URL(fileURLWithPath: project) }

    func fingerprint(
        hashingIn hashingRoot: String? = nil,
        excluding excluded: [String] = [],
        list: ProjectFileListing = GitFileListing.list(in:)
    ) -> ProjectTree {
        ProjectTree.fingerprint(
            listingIn: projectURL,
            hashingIn: URL(fileURLWithPath: hashingRoot ?? project),
            excluding: excluded,
            list: list
        )
    }

    func tree(_ files: [String: String], excluding excluded: [String]) -> ProjectTree {
        ProjectTree(listedBy: .git, files: files, excluded: excluded, treeSHA256: ProjectTree.treeHash(of: files))
    }

    /// Writes each file, relative to `folder`, the project unless given, making its folders.
    func write(_ files: [String: String], in folder: String? = nil) throws {
        for (path, contents) in files {
            let file = URL(fileURLWithPath: "\(folder ?? project)/\(path)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
    }

    func digest(of path: String) -> String? {
        FileDigest.sha256(of: URL(fileURLWithPath: "\(project)/\(path)"))
    }

    func sha256(_ text: String) -> String {
        FileDigest.sha256(of: Data(text.utf8)) ?? ""
    }

    /// Sets the environment variable `name` to `value` until the test ends.
    func setEnvironment(_ name: String, to value: String) {
        let earlier = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        addTeardownBlock {
            if let earlier {
                setenv(name, earlier, 1)
            } else {
                unsetenv(name)
            }
        }
    }

    /// Runs git in `directory`, as SwiftMutator does: never in a repository the environment names, as a hook's does.
    func git(_ arguments: String..., in directory: String) throws {
        let git = Foundation.Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", directory] + arguments
        git.environment = GitFileListing.environment(ProcessInfo.processInfo.environment)
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        git.terminationHandler = { _ in exited.signal() }
        try git.run()
        guard exited.wait(timeout: .now() + 60) == .success else {
            git.terminate()
            _ = exited.wait(timeout: .now() + 5)
            throw GitTimedOut(arguments: arguments)
        }
        XCTAssertEqual(git.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}

private struct GitTimedOut: Error {
    let arguments: [String]
}
