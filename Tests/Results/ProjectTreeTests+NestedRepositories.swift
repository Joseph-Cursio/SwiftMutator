@testable import muterCore
import XCTest

extension ProjectTreeTests {
    func test_listsANestedRepository_throughItsOwnListing() async throws {
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

        let listing = await GitFileListing.list(in: projectURL)
        XCTAssertEqual(listing?.contains("vendor/lib/a.json"), true)
        let fingerprinted = await fingerprint().files.keys.sorted()
        XCTAssertEqual(fingerprinted, [
            "Sources/Sum.swift",
            "vendor/lib/.gitignore",
            "vendor/lib/a.json",
        ])
    }

    func test_aProjectNestedInARepository_listsItsTrackedFiles() async throws {
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

        let tree = await fingerprint(hashingIn: copy)

        XCTAssertEqual(tree.listedBy, .git)
        XCTAssertEqual(tree.files.keys.sorted(), [
            ".gitignore",
            "Sources/Lib/A.swift",
            "Tests/Fixtures/f.json",
            "notes.txt",
        ])
        let result = await GitFileListing.list(in: URL(fileURLWithPath: copy))
        XCTAssertNil(result, "why the project is listed, not the copy")
    }

    // A run started from a git hook inherits what git exports to it: a relative GIT_INDEX_FILE, -c settings as
    // GIT_CONFIG_PARAMETERS, and GIT_DIR=.git after `git --git-dir=.git commit`. In a nested project that GIT_DIR names
    // a folder that isn't there, and the files the repository tracks would be walked as if it had none.
    func test_aListingInAGitHook_leavesOutTheRepositoryVariablesItInherits() async throws {
        let repository = project
        project = "\(repository)/proj"
        try write([".gitignore": "Tests/Fixtures/*.json\n", "Sources/Lib/A.swift": "a", "Tests/Fixtures/f.json": "{}"])
        try git("init", in: repository)
        try git("add", "proj/.gitignore", "proj/Sources", in: repository)
        try git("add", "-f", "proj/Tests/Fixtures/f.json", in: repository)
        setEnvironment("GIT_DIR", to: ".git")
        setEnvironment("GIT_INDEX_FILE", to: ".git/index")
        setEnvironment("GIT_CONFIG_PARAMETERS", to: "'user.name'='Me'")

        let result = await GitFileListing.list(in: projectURL)
        XCTAssertEqual(
            result,
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
    func test_theUsersGlobalExcludes_areKept() async throws {
        try write(["Sources/Sum.swift": "sum", "README.md": "readme", "settings.local.json": "a tool's"])
        let configuration = try makeTemporaryDirectory()
        try Data("settings.local.json\n".utf8).write(to: URL(fileURLWithPath: "\(configuration)/ignore"))
        try Data("[core]\n\texcludesFile = \(configuration)/ignore\n".utf8)
            .write(to: URL(fileURLWithPath: "\(configuration)/config"))
        setEnvironment("GIT_CONFIG_GLOBAL", to: "\(configuration)/config")
        try git("init", in: project)

        let result = await GitFileListing.list(in: projectURL)
        XCTAssertEqual(result, ["README.md", "Sources/Sum.swift"])
    }

    // A project with no repository of its own, in a folder its enclosing repository ignores: git lists none of its
    // untracked files, and only the files forced in, so it is walked.
    func test_aProjectInAFolderItsRepositoryIgnores_isWalked() async throws {
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

        let tree = await fingerprint()

        let listing = await GitFileListing.list(in: projectURL)
        XCTAssertNil(listing)
        XCTAssertEqual(tree.listedBy, .walk)
        XCTAssertEqual(tree.files.keys.sorted(), everyFile)

        try git("add", "-f", "scratch/Pkg/Sources/Pkg/A.swift", in: repository)
        let listingWithAFileForcedIn = await GitFileListing.list(in: projectURL)
        XCTAssertNil(listingWithAFileForcedIn, "a file forced in leaves the rest unlisted")
        let fingerprinted = await fingerprint().files.keys.sorted()
        XCTAssertEqual(fingerprinted, everyFile)
    }
}
