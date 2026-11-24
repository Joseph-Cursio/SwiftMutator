import Foundation
@testable import muterCore
import TestingExtensions
import XCTest

/// For an Xcode project, discovery picks from the files its targets compile (`XcodeTargetSources`).
extension DiscoverSourceFilesTests {
    // An example's file is in no target, so no test could kill its mutants, with coverage or without.
    func test_anXcodeProject_onlyTheFilesItsTargetsCompile() async throws {
        let project = try makeXcodeProject()

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/App/Model.swift"])])
    }

    // `--since` lists the same paths before coverage: without coverage, a change to the example's file alone ends the
    // run there.
    func test_anXcodeProject_aChangeToAFileNoTargetCompiles_endsASinceRunWithoutCoverage() async throws {
        _ = try makeXcodeProject()
        state.runOptions = .make(skipCoverage: true)
        let selection = ChangeSelection.make(files: [ChangedFile(path: "Examples/Demo.swift", sha256: "a")])
        state.apply([.changesSelected(selection)])

        await AssertThrowsError(try await ListChangedSources().run(with: state)) { error in
            XCTAssertEqual(
                error as? NothingToMutate,
                NothingToMutate(reason: .noTargetCompiles(count: 1), selection: selection)
            )
        }
    }

    // A run with coverage goes on to it, whose data may name the file, and keeps it then, as a run without `--since`
    // does.
    func test_anXcodeProject_aSinceRunWithCoverage_keepsACoveredFileNoTargetListed() async throws {
        let project = try makeXcodeProject()
        let selection = ChangeSelection.make(files: [
            ChangedFile(path: "Examples/Demo.swift", sha256: try sha256(of: project + "/Examples/Demo.swift")),
        ])
        state.apply([.changesSelected(selection)])

        let listed = try await ListChangedSources().run(with: state)
        state.apply(listed)
        state.projectCoverage = Coverage.make(filesInCoverage: ["App/Model.swift", "Examples/Demo.swift"])
        let result = try await sut.run(with: state)

        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/Examples/Demo.swift"])])
    }

    // xcodebuild opening a package whose `swift` couldn't be found has no project file to read, and walks it, saying
    // nothing more than before.
    func test_aPackageTestedThroughXcodebuild_withoutItsSwift_isWalkedWithoutAWarning() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory().canonicalPath
        try makeFiles(["Package.swift", "Sources/Lib/Lib.swift"], in: project)
        var warnings: [String] = []
        let observer = runEvents.observe(.xcodeTargetSourcesUnavailable) { warnings.append($0.object as? String ?? "") }
        defer { observer.cancel() }
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/Sources/Lib/Lib.swift"])])
        XCTAssertEqual(warnings, [])
    }

    // A run with coverage keeps every file its data names that the walk keeps, even one the project file reading
    // missed.
    func test_anXcodeProject_withCoverage_keepsACoveredFileNoTargetListed() async throws {
        let project = try makeXcodeProject()
        state.projectCoverage = Coverage.make(filesInCoverage: ["App/Model.swift", "Examples/Demo.swift"])

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered(["\(project)/App/Model.swift", "\(project)/Examples/Demo.swift"]),
        ])
    }

    // What an external tool builds can't be told, so every file counts, with a warning.
    func test_anXcodeProject_whoseTargetsCantBeRead_isWalked_withAWarning() async throws {
        let project = try makeXcodeProject(extra: ["TOOL": ["isa": "PBXLegacyTarget", "name": "Tool"]])
        var warnings: [String] = []
        let observer = runEvents.observe(.xcodeTargetSourcesUnavailable) { warnings.append($0.object as? String ?? "") }
        defer { observer.cancel() }

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered(["\(project)/App/Model.swift", "\(project)/Examples/Demo.swift"]),
        ])
        XCTAssertEqual(warnings, ["App.xcodeproj's target Tool is built by an external tool"])
    }

    private func sha256(of path: String) throws -> String {
        try XCTUnwrap(FileDigest.sha256(of: URL(fileURLWithPath: path)))
    }

    /// A project folder with `App.xcodeproj`, whose target App compiles `App/Model.swift`, and `Examples/Demo.swift`,
    /// which no target compiles, tested by xcodebuild; `extra` objects go in its project file.
    private func makeXcodeProject(extra: [String: [String: Any]] = [:]) throws -> String {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory().canonicalPath
        try makeFiles(["App/Model.swift", "Examples/Demo.swift"], in: project)
        var objects: [String: [String: Any]] = [
            "PROJECT": ["isa": "PBXProject", "mainGroup": "MAIN", "projectDirPath": ""],
            "MAIN": ["isa": "PBXGroup", "children": ["APPGROUP"], "sourceTree": "<group>"],
            "APPGROUP": ["isa": "PBXGroup", "path": "App", "children": ["MODEL"], "sourceTree": "<group>"],
            "MODEL": ["isa": "PBXFileReference", "path": "Model.swift", "sourceTree": "<group>"],
            "MODELFILE": ["isa": "PBXBuildFile", "fileRef": "MODEL"],
            "SOURCES": ["isa": "PBXSourcesBuildPhase", "files": ["MODELFILE"]],
            "APP": [
                "isa": "PBXNativeTarget", "name": "App", "productType": "com.apple.product-type.application",
                "buildPhases": ["SOURCES"],
            ],
        ]
        objects.merge(extra) { _, new in new }
        let plist: [String: Any] = ["rootObject": "PROJECT", "objects": objects]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(atPath: project + "/App.xcodeproj", withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: project + "/App.xcodeproj/project.pbxproj"))
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-project", "App.xcodeproj", "-scheme", "App", "test"]
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        return project
    }
}
