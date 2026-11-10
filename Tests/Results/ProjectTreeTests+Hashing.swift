@testable import muterCore
import XCTest

extension ProjectTreeTests {
    // Folders given to prune, by their paths from the root, are left out whatever they hold, listed or walked. A
    // folder of the same name elsewhere, or a file whose name starts with theirs, is kept.
    func test_prunedFolders_areLeftOut_listedOrWalked() async throws {
        try write([
            "Sources/Sum.swift": "kept",
            "TestContents/Build/Intermediates.noindex/App.build/DerivedSources/GeneratedAssetSymbols.swift": "pruned",
            "TestContents/Build/Products/Debug/App.app/Info.plist": "pruned",
            "build/dd/Build/Products/Debug/Generated.swift": "pruned",
            "build/notes.txt": "kept",
            "Sources/TestContents/Fixture.swift": "kept",
            "TestContentsList.txt": "kept",
        ])
        try git("init", in: project)
        try git("add", "-f", ".", in: project)
        let kept = [
            "Sources/Sum.swift", "Sources/TestContents/Fixture.swift", "TestContentsList.txt", "build/notes.txt",
        ]

        let listed = await fingerprint(pruning: ["TestContents", "build/dd"]).files.keys.sorted()
        XCTAssertEqual(listed, kept, "listed by git")
        let walked = await fingerprint(pruning: ["TestContents", "build/dd"]) { _ in nil }.files.keys.sorted()
        XCTAssertEqual(walked, kept, "walked")
    }

    func test_withoutGit_walksEveryFile() async throws {
        try write([
            "Sources/Sum.swift": "sum",
            "notes.txt": "notes",
            "Tests/Fixtures/f.json": "{}",
            "Nested/.git/HEAD": "not a repository git can read",
            "Nested/Sources/Lib.swift": "lib",
        ])

        let tree = await fingerprint()

        let result = await GitFileListing.list(in: projectURL)
        XCTAssertNil(result, "not in a repository: git fails")
        XCTAssertEqual(tree.listedBy, .walk)
        XCTAssertEqual(tree.files.keys.sorted(), [
            "Nested/Sources/Lib.swift",
            "Sources/Sum.swift",
            "Tests/Fixtures/f.json",
            "notes.txt",
        ])
    }

    func test_aSymbolicLinkIsHashedByWhereItPoints() async throws {
        try write(["Docs/rules/rule.md": "a rule", "notes.txt": "notes"])
        let manager = FileManager.default
        try manager.createDirectory(atPath: "\(project)/Sources", withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: "\(project)/Sources/rules", withDestinationPath: "../Docs/rules")
        try manager.createSymbolicLink(atPath: "\(project)/link.txt", withDestinationPath: "notes.txt")
        try git("init", in: project)
        try git("add", ".", in: project)

        let listings: [(String, ProjectFileListing)] = [
            ("listed by git", { await GitFileListing.list(in: $0) }),
            ("walked", { _ in nil }),
        ]
        for (name, list) in listings {
            let tree = await fingerprint(list: list)

            XCTAssertEqual(
                tree.files.keys.sorted(),
                [
                    "Docs/rules/rule.md",
                    "Sources/rules",
                    "link.txt",
                    "notes.txt",
                ],
                name
            )
            XCTAssertEqual(tree.files["Sources/rules"], "link:" + sha256("../Docs/rules"), name)
            XCTAssertEqual(tree.files["link.txt"], "link:" + sha256("notes.txt"), name)
            XCTAssertNotEqual(tree.files["link.txt"], tree.files["notes.txt"], name)
        }
    }

    // SwiftMutator copies only the project, beside it, so `../Core` names the same folder from the project and the
    // copy, and every session builds whatever that folder holds then. Each local package the manifests name with a
    // literal path, theirs in turn, and those Xcode references, is listed and hashed where it is.
    func test_localPackagesOutsideTheProject_areFingerprintedWhereTheyAre() async throws {
        let root = project
        project = "\(root)/App"
        try writeAppAndItsLocalPackages(around: root)
        let copy = "\(project)_mutated"
        try FileManager.default.copyItem(atPath: project, toPath: copy)

        let tree = await fingerprint { _ in nil }

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
        let inTheCopy = await fingerprint(hashingIn: copy) { _ in nil }
        XCTAssertEqual(inTheCopy, tree, "the copy builds the same folders")

        try write(["Core/Sources/Core/Core.swift": "changed"], in: root)
        let changes = await fingerprint { _ in nil }.changes(since: tree)
        XCTAssertEqual(
            changes,
            [.init(path: "../Core/Sources/Core/Core.swift", kind: .changed)]
        )
    }

    /// Writes an app in `project` whose manifests and Xcode project name local packages, by literal paths, inside it
    /// and beside it in `root`, and writes those, with a commented-out one and one that nothing names.
    private func writeAppAndItsLocalPackages(around root: String) throws {
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
    }

    func test_listsTheProjectButHashesTheCopy() async throws {
        try write(["Sources/Sum.swift": "sum", "notes.txt": "notes", "Gone.txt": "only in the project"])
        try git("init", in: project)
        try git("add", ".", in: project)
        let copy = "\(project)_mutated"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: copy) }
        try FileManager.default.copyItem(atPath: project, toPath: copy)
        try Data("changed in the copy".utf8).write(to: URL(fileURLWithPath: "\(copy)/Sources/Sum.swift"))
        try FileManager.default.removeItem(atPath: "\(copy)/Gone.txt")

        let tree = await fingerprint(hashingIn: copy)

        XCTAssertEqual(tree.files.keys.sorted(), ["Sources/Sum.swift", "notes.txt"])
        XCTAssertEqual(tree.files["Sources/Sum.swift"], sha256("changed in the copy"))
    }

    func test_treeHash_doesNotDependOnListingOrder() async throws {
        try write(["a.txt": "a", "b.txt": "b"])

        let forwards = await fingerprint { _ in ["a.txt", "b.txt"] }
        let backwards = await fingerprint { _ in ["b.txt", "a.txt"] }

        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards.treeSHA256, sha256("a.txt\0\(sha256("a"))\nb.txt\0\(sha256("b"))\n"))
        try write(["b.txt": "changed"])
        let result = await fingerprint { _ in ["a.txt", "b.txt"] }.treeSHA256
        XCTAssertNotEqual(result, forwards.treeSHA256)
    }
}
