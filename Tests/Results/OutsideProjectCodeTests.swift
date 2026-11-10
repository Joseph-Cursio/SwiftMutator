import Foundation
@testable import muterCore
import XCTest

/// Real folders: a project, `App`, inside a folder that holds the code its workspaces reference.
final class OutsideProjectCodeTests: XCTestCase {
    private let root = XCTestCase.unusedTemporaryPath()
    private var project: String { "\(root)/App" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    // A workspace's references resolve as Xcode resolves them: `group:` against the groups they are in, a top-level
    // one and `container:` against the folder that holds the workspace, and `absolute:` on its own. Only Xcode
    // projects and package folders outside the project are kept: a file or a plain folder isn't built, something
    // missing isn't either, nor is anything inside the project, a folder that holds it, or a location of another kind.
    func test_workspaceReferences_keepTheProjectsAndPackagesOutsideTheProject() throws {
        try write([
            "App.xcworkspace/contents.xcworkspacedata": """
            <?xml version="1.0" encoding="UTF-8"?>
            <Workspace
               version = "1.0">
               <FileRef
                  location = "group:App.xcodeproj">
               </FileRef>
               <FileRef
                  location = "group:../Other/Other.xcodeproj">
               </FileRef>
               <FileRef location = "container:../Shared"></FileRef>
               <FileRef location = "absolute:\(root)/Absolute/Absolute.xcodeproj"></FileRef>
               <FileRef location = "group:../Notes.md"></FileRef>
               <FileRef location = "group:../Docs"></FileRef>
               <FileRef location = "group:../Missing/Missing.xcodeproj"></FileRef>
               <FileRef location = "group:.."></FileRef>
               <FileRef location = "group:Packages/Inside"></FileRef>
               <FileRef location = "developer:Other/Other.xcodeproj"></FileRef>
               <Group location = "group:../Libs" name = "Libs">
                  <FileRef location = "group:Lib/Lib.xcodeproj"></FileRef>
                  <Group location = "group:Nested" name = "Nested">
                     <FileRef location = "group:Deep"></FileRef>
                  </Group>
               </Group>
               <Group name = "Only a name">
                  <FileRef location = "group:../Named &amp; Escaped"></FileRef>
               </Group>
               <Group location = "developer:Somewhere" name = "Elsewhere">
                  <FileRef location = "group:Other/Other.xcodeproj"></FileRef>
               </Group>
            </Workspace>
            """,
            "App.xcodeproj/project.pbxproj": "",
            "Packages/Inside/Package.swift": "",
        ], in: project)
        try write([
            "Other/Other.xcodeproj/project.pbxproj": "",
            "Shared/Package.swift": "",
            "Absolute/Absolute.xcodeproj/project.pbxproj": "",
            "Notes.md": "",
            "Docs/Guide.md": "",
            "Libs/Lib/Lib.xcodeproj/project.pbxproj": "",
            "Libs/Nested/Deep/Package.swift": "",
            "Named & Escaped/Package@swift-6.0.swift": "",
            "Package.swift": "a package that holds the project",
        ], in: root)

        let references = OutsideProjectCode.workspaceReferences(
            outside: URL(fileURLWithPath: project),
            workspaces: ["App.xcworkspace/contents.xcworkspacedata", "App.xcodeproj/project.pbxproj"]
        )

        XCTAssertEqual(references.map(\.relativePath), [
            "../Absolute/Absolute.xcodeproj",
            "../Libs/Lib/Lib.xcodeproj",
            "../Libs/Nested/Deep",
            "../Named & Escaped",
            "../Other/Other.xcodeproj",
            "../Shared",
        ])
        XCTAssertEqual(references.first?.url, URL(fileURLWithPath: "\(root)/Absolute/Absolute.xcodeproj"))
    }

    // A workspace in a folder of the project resolves its references from that folder. The workspace inside an Xcode
    // project only references the project itself, so it isn't read, and nor is a workspace the listing doesn't hold.
    func test_aWorkspaceInAFolder_resolvesFromThere_andOnlyListedWorkspacesOfTheirOwnAreRead() throws {
        try write([
            "Example/Example.xcworkspace/contents.xcworkspacedata":
                #"<Workspace version = "1.0"><FileRef location = "group:../../Kit/Kit.xcodeproj"/></Workspace>"#,
            "App.xcodeproj/project.xcworkspace/contents.xcworkspacedata":
                #"<Workspace version = "1.0"><FileRef location = "group:../Embedded"/></Workspace>"#,
            "Unlisted.xcworkspace/contents.xcworkspacedata":
                #"<Workspace version = "1.0"><FileRef location = "group:../Unlisted"/></Workspace>"#,
        ], in: project)
        try write([
            "Kit/Kit.xcodeproj/project.pbxproj": "",
            "Embedded/Package.swift": "",
            "Unlisted/Package.swift": "",
        ], in: root)

        let references = OutsideProjectCode.workspaceReferences(
            outside: URL(fileURLWithPath: project),
            workspaces: [
                "Example/Example.xcworkspace/contents.xcworkspacedata",
                "App.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
            ]
        )

        XCTAssertEqual(references.map(\.relativePath), ["../Kit/Kit.xcodeproj"])
    }

    // A workspace that doesn't parse keeps what was read before the error, and one that can't be read gives nothing.
    func test_aBrokenWorkspace_keepsWhatWasReadBeforeTheError() throws {
        try write([
            "Broken.xcworkspace/contents.xcworkspacedata":
                #"<Workspace version = "1.0"><FileRef location = "group:../Kit/Kit.xcodeproj"/><FileRef"#,
        ], in: project)
        try write(["Kit/Kit.xcodeproj/project.pbxproj": ""], in: root)

        let references = OutsideProjectCode.workspaceReferences(
            outside: URL(fileURLWithPath: project),
            workspaces: ["Broken.xcworkspace/contents.xcworkspacedata", "Gone.xcworkspace/contents.xcworkspacedata"]
        )

        XCTAssertEqual(references.map(\.relativePath), ["../Kit/Kit.xcodeproj"])
    }

    // The notice lists the local packages and the workspaces' references together, each once, by path.
    func test_paths_listLocalPackagesAndWorkspaceReferences_onceEach_sorted() throws {
        try write([
            "App.xcworkspace/contents.xcworkspacedata": """
            <Workspace version = "1.0">
               <FileRef location = "group:../Shared"/>
               <FileRef location = "group:../Other/Other.xcodeproj"/>
            </Workspace>
            """,
        ], in: project)
        try write(["Shared/Package.swift": "", "Other/Other.xcodeproj/project.pbxproj": ""], in: root)
        let localPackages = ["Shared", "Core"].map {
            LocalPackageDependencies.Dependency(url: URL(fileURLWithPath: "\(root)/\($0)"), relativePath: "../\($0)")
        }

        let paths = OutsideProjectCode.paths(
            in: URL(fileURLWithPath: project),
            listed: ["App.xcworkspace/contents.xcworkspacedata", "Sources/App.swift"],
            localPackages: localPackages
        )

        XCTAssertEqual(paths, ["../Core", "../Other/Other.xcodeproj", "../Shared"])
    }

    // An absolute path names the same folder from the copy, so code in the project that a workspace or a manifest
    // names by one is built from the project. A relative path into the project, a `group:` location in a group whose
    // own is relative, the project's folder itself, a folder that holds it and code outside it don't count, and nor
    // does a workspace reference that isn't built. Each is listed once, by its path from the project.
    func test_namedByAbsolutePath_listsCodeInTheProjectThatAnAbsolutePathNames() throws {
        try write([
            "App.xcworkspace/contents.xcworkspacedata": """
            <Workspace version = "1.0">
               <FileRef location = "absolute:\(project)/App.xcodeproj"></FileRef>
               <FileRef location = "group:Relative/Relative.xcodeproj"></FileRef>
               <FileRef location = "absolute:\(project)/Notes.md"></FileRef>
               <FileRef location = "absolute:\(project)"></FileRef>
               <FileRef location = "absolute:\(root)/Other/Other.xcodeproj"></FileRef>
               <Group location = "absolute:\(project)/Packages" name = "Packages">
                  <FileRef location = "group:Core"></FileRef>
               </Group>
               <Group location = "group:Packages" name = "Relative packages">
                  <FileRef location = "group:Kit"></FileRef>
               </Group>
            </Workspace>
            """,
            "Package.swift": """
            let package = Package(dependencies: [
                .package(path: "\(project)/Packages/Core"),
                .package(path: "\(project)/Packages/Util"),
                .package(path: "Packages/Kit"),
                .package(path: "\(root)"),
            ])
            """,
            "App.xcodeproj/project.pbxproj": "",
            "Relative/Relative.xcodeproj/project.pbxproj": "",
            "Notes.md": "",
            "Packages/Core/Package.swift": "",
            "Packages/Kit/Package.swift": "",
        ], in: project)
        try write(["Other/Other.xcodeproj/project.pbxproj": ""], in: root)

        let paths = OutsideProjectCode.namedByAbsolutePath(
            in: URL(fileURLWithPath: project),
            listed: ["App.xcworkspace/contents.xcworkspacedata", "Package.swift", "App.xcodeproj/project.pbxproj"]
        )

        XCTAssertEqual(paths, ["App.xcodeproj", "Packages/Core", "Packages/Util"])
    }

    func test_isWorkspace() {
        XCTAssertTrue(OutsideProjectCode.isWorkspace("App.xcworkspace/contents.xcworkspacedata"))
        XCTAssertTrue(OutsideProjectCode.isWorkspace("Example/Example.xcworkspace/contents.xcworkspacedata"))
        XCTAssertFalse(OutsideProjectCode.isWorkspace("App.xcodeproj/project.xcworkspace/contents.xcworkspacedata"))
        XCTAssertFalse(OutsideProjectCode.isWorkspace("contents.xcworkspacedata"))
        XCTAssertFalse(OutsideProjectCode.isWorkspace("App.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
        XCTAssertFalse(OutsideProjectCode.isWorkspace("Docs/contents.xcworkspacedata"))
    }
}

private extension OutsideProjectCodeTests {
    /// Writes each file, relative to `folder`, making its folders.
    func write(_ files: [String: String], in folder: String) throws {
        for (path, contents) in files {
            let file = URL(fileURLWithPath: "\(folder)/\(path)")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
    }
}
