@testable import muterCore
import TestingExtensions
import XCTest

extension DiscoverSourceFilesTests {
    // An example app's files, and a tool's in a hidden folder, are in no target, so no test could kill their mutants.
    func test_aSwiftPMProject_onlyTheFilesItsTargetsCompile() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(
            [
                "Sources/Lib/Lib.swift",
                "Tests/LibTests/LibTests.swift",
                "ExampleCode/Example.swift",
                ".swiftinfer/Inferred.swift",
            ],
            in: project
        )
        describing(project, as: [
            target("library", path: "Sources/Lib", sources: ["Lib.swift"]),
            target("test", path: "Tests/LibTests", sources: ["LibTests.swift"]),
        ])
        let describedIn = workingDirectoriesOfDescribe()
        let workingDirectory = FileManager.default.currentDirectoryPath

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/Sources/Lib/Lib.swift"])])
        XCTAssertEqual(process.commandsRun, [
            ["/usr/bin/swift", "package", "--package-path", project, "describe", "--type", "json"],
        ])
        // As the coverage run and the tests are.
        XCTAssertEqual(describedIn.paths, [project.canonicalPath])
        XCTAssertEqual(FileManager.default.currentDirectoryPath, workingDirectory)
    }

    // The tests are those of the package the test command names, not of the tools' package at the project's root.
    func test_aSwiftPMProject_thePackageTheTestCommandNames() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["Sources/Tool/main.swift", "Packages/App/Sources/App/App.swift"], in: project)
        describing(project + "/Packages/App", as: [target("library", path: "Sources/App", sources: ["App.swift"])])

        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test", "--package-path", "Packages/App"]
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/Packages/App/Sources/App/App.swift"])])
    }

    // describe says what the targets compile, so the walk's filters don't apply: a source a script generates before the
    // build, which git ignores, is still mutated, and git isn't asked.
    func test_aSwiftPMProject_keepsTheFilesItsTargetsCompile_thatGitIgnores() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["Sources/Lib/Lib.swift", "Sources/Lib/Generated/Strings.swift"], in: project)
        describing(project, as: [
            target("library", path: "Sources/Lib", sources: ["Generated/Strings.swift", "Lib.swift"]),
        ])
        let asked = Locked(false)
        current.listProjectFiles = { _ in
            asked.change { $0 = true }
            return ["Sources/Lib/Lib.swift"]
        }

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(project)/Sources/Lib/Generated/Strings.swift",
                "\(project)/Sources/Lib/Lib.swift",
            ]),
        ])
        XCTAssertFalse(asked.value)
    }

    // A test helper target under `Tests` is a library, so the default list still leaves it out.
    func test_aSwiftPMProject_theExcludeListAndCoverageStillApply() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(
            [
                "Sources/Lib/Lib.swift",
                "Sources/Lib/Generated.swift",
                "Sources/Lib/Uncovered.swift",
                "Tests/Support/Stub.swift",
            ],
            in: project
        )
        describing(project, as: [
            target("library", path: "Sources/Lib", sources: ["Generated.swift", "Lib.swift", "Uncovered.swift"]),
            target("library", path: "Tests/Support", sources: ["Stub.swift"]),
        ])

        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            excludeList: ["Generated.swift"]
        )
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.projectCoverage = Coverage.make(filesWithoutCoverage: ["Sources/Lib/Uncovered.swift"])

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered(["\(project)/Sources/Lib/Lib.swift"]),
            .uncoveredSourceFilesDiscovered(["\(project)/Sources/Lib/Uncovered.swift"]),
        ])
    }

    // An xcodebuild project's example app is in no target the tests build, and a local package its app links is in
    // one, which coverage names by its path in the project or in full, as the coverage tools do.
    func test_aProjectWithCoverage_onlyTheFilesTheCoverageNames() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(
            ["App/Model.swift", "App/Untested.swift", "ExampleApp/Example.swift", "Packages/Core/Parser.swift"],
            in: project
        )

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.projectCoverage = Coverage.make(
            filesWithoutCoverage: ["App/Untested.swift"],
            filesInCoverage: ["App/Model.swift", "App/Untested.swift", "\(project)/Packages/Core/Parser.swift"]
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(project)/App/Model.swift",
                "\(project)/Packages/Core/Parser.swift",
            ]),
            .uncoveredSourceFilesDiscovered(["\(project)/App/Untested.swift"]),
        ])
    }

    // describe lists an example executable's files, but no test bundle links it, so its coverage names none of them.
    func test_aSwiftPMProject_withCoverage_onlyTheFilesItsTargetsCompile_thatTheCoverageNames() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["Sources/Lib/Lib.swift", "Sources/Demo/main.swift"], in: project)
        describing(project, as: [
            target("library", path: "Sources/Lib", sources: ["Lib.swift"]),
            target("executable", path: "Sources/Demo", sources: ["main.swift"]),
        ])

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.projectCoverage = Coverage.make(filesInCoverage: ["Sources/Lib/Lib.swift"])

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/Sources/Lib/Lib.swift"])])
    }
}
