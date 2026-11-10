@testable import muterCore
import TestingExtensions
import XCTest

extension DiscoverSourceFilesTests {
    // Skipped, or failed, coverage can't say which files the tests' binaries hold.
    func test_withoutCoverage_noFileIsLeftOut_forBeingOutsideIt() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["App/Model.swift", "ExampleApp/Example.swift"], in: project)

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.projectCoverage = .null

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered(["\(project)/App/Model.swift", "\(project)/ExampleApp/Example.swift"]),
        ])
    }

    // They used to be mutated, and every mutant in a file whose code no test ran survives.
    func test_theFilesToMutate_thatTheCoverageDoesntName_areLeftOut_withAWarning() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["App/Model.swift", "ExampleApp/Example.swift"], in: project)
        let warnings = unmatchedEntries()

        state.filesToMutate = ["ExampleApp/Example.swift", "App"]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.projectCoverage = Coverage.make(filesInCoverage: ["App/Model.swift"])

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/App/Model.swift"])])
        XCTAssertEqual(warnings.entries, [.init(entry: "ExampleApp/Example.swift", reason: .withoutCoverage)])
    }

    // An entry whose files the excludes and the coverage filter share out between them is left to the coverage.
    func test_theFilesToMutate_leftOutByTheExcludesAndTheCoverage_saySo() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["App/Model.swift", "App/Mocks/MockAPI.swift", "App/Example.swift", "Lib/Lib.swift"], in: project)
        let warnings = unmatchedEntries()

        state.filesToMutate = ["App", "Lib", "App/Model.swift"]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.projectCoverage = Coverage.make(
            filesWithoutCoverage: ["\(project)/Lib/Lib.swift"],
            filesInCoverage: ["App/Model.swift", "Lib/Lib.swift"]
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered(["\(project)/App/Model.swift"]),
            .uncoveredSourceFilesDiscovered(["\(project)/Lib/Lib.swift"]),
        ])
        XCTAssertEqual(warnings.entries, [.init(entry: "Lib", reason: .withoutCoverage)])

        state.filesToMutate = ["App/Mocks", "App/Example.swift"]
        _ = try? await sut.run(with: state)
        XCTAssertEqual(warnings.entries, [
            .init(entry: "Lib", reason: .withoutCoverage),
            .init(entry: "App/Mocks", reason: .excluded),
            .init(entry: "App/Example.swift", reason: .withoutCoverage),
        ])
    }

    func test_theFilesToMutate_takeFolders_andGlobsThatMatchFolders() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        let files = [
            "Sources/App/Model.swift", "Sources/App/View/Row.swift", "Sources/App/.hidden/Old.swift",
            "Sources/App/notes.md", "Sources/Lib/Lib.swift", "Other/Other.swift",
        ]
        try makeFiles(files, in: project)

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.projectDirectoryURL = URL(fileURLWithPath: "/Users/me/Project", isDirectory: true)
        let warnings = unmatchedEntries()
        for (entries, expected) in [
            (["Sources/App"], ["Sources/App/Model.swift", "Sources/App/View/Row.swift"]),
            (["Sources/App/"], ["Sources/App/Model.swift", "Sources/App/View/Row.swift"]),
            (["./Sources/Lib", "Other/Other.swift"], ["Other/Other.swift", "Sources/Lib/Lib.swift"]),
            (["Sources/*"], ["Sources/App/Model.swift", "Sources/App/View/Row.swift", "Sources/Lib/Lib.swift"]),
            (["Sources", "Sources/App/Model.swift"], [
                "Sources/App/Model.swift", "Sources/App/View/Row.swift", "Sources/Lib/Lib.swift",
            ]),
            // As an `exclude` glob: `**/` stands for no folder too, and hidden files are left out.
            (["Sources/App/**/*.swift"], ["Sources/App/Model.swift", "Sources/App/View/Row.swift"]),
            (["**/Row.swift", "./Other/*.swift"], ["Other/Other.swift", "Sources/App/View/Row.swift"]),
            // An absolute path in the project, and a file named twice, in another case too.
            (["/Users/me/Project/Sources/Lib/Lib.swift", "/Other/Other.swift"], [
                "Other/Other.swift", "Sources/Lib/Lib.swift",
            ]),
            (["Sources/Lib", "sources/lib/Lib.swift", "Sources/Lib/Lib.swift"], ["Sources/Lib/Lib.swift"]),
        ] {
            state.filesToMutate = entries
            let result = try await sut.run(with: state)
            XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(expected.map { "\(project)/\($0)" })], "\(entries)")
        }
        XCTAssertEqual(warnings.entries, [])
    }

    func test_theFilesToMutate_keepTheExcludes_theDefaultsToo() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        let files = [
            "Sources/App/Model.swift", "Sources/App/Generated/API.swift", "Sources/App/Mocks/MockAPI.swift",
            "Sources/Stubs/Stub.swift",
        ]
        try makeFiles(files, in: project)
        let warnings = unmatchedEntries()

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.muterConfiguration = MuterConfiguration(
            executable: "", arguments: [], excludeList: ["/Generated/", "!Sources/Stubs/**"]
        )
        state.filesToMutate = ["Sources", "Sources/App/Mocks/MockAPI.swift"]

        let result = try await sut.run(with: state)

        let expected = ["\(project)/Sources/App/Model.swift", "\(project)/Sources/Stubs/Stub.swift"]
        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(expected)])
        XCTAssertEqual(warnings.entries, [.init(entry: "Sources/App/Mocks/MockAPI.swift", reason: .excluded)])
    }

    func test_theFilesToMutate_eachEntryThatLeavesNoFile_isSaid() async throws {
        current.fileManager = FileManager.default
        let parent = try makeTemporaryDirectory()
        let project = parent + "/Project"
        try makeFiles(
            ["Package.swift", "Sources/App/Model.swift", "Sources/App/notes.md", "Tests/AppTests/ModelTests.swift"],
            in: project
        )
        try makeFiles(["Elsewhere.swift"], in: parent)
        let warnings = unmatchedEntries()

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.filesToMutate = [
            "Sources/App/Model.swift", "Package.swift", "Sources/Missing.swift", "Sources/App/notes.md", "Docs",
            "Sources/*.swift",
            "Tests", "../Elsewhere.swift",
        ]

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/Sources/App/Model.swift"])])
        XCTAssertEqual(warnings.entries, [
            .init(entry: "Package.swift", reason: .neverMutated),
            .init(entry: "Sources/Missing.swift", reason: .noSwiftFile),
            .init(entry: "Sources/App/notes.md", reason: .noSwiftFile),
            .init(entry: "Docs", reason: .noSwiftFile),
            .init(entry: "Sources/*.swift", reason: .noSwiftFile),
            .init(entry: "Tests", reason: .excluded),
            .init(entry: "../Elsewhere.swift", reason: .outsideTheProject),
        ])
    }

    func test_theFilesToMutate_thatLeaveNoFile_stillFailTheRun() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["Tests/AppTests/ModelTests.swift"], in: project)

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.filesToMutate = ["Tests"]

        try await assertThrowsMuterError(await sut.run(with: state), .noSourceFilesOnExclusiveList)
    }
}
