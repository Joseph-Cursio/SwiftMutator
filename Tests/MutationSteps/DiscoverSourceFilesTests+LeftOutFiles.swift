@testable import muterCore
import TestingExtensions
import XCTest

extension DiscoverSourceFilesTests {
    func test_versionedPackageManifestsAreExcluded() async throws {
        current.fileManager = FileManager.default

        // Every `swift test` run in a worker folder has one environment, so SwiftPM reuses the baseline's
        // cached manifest and a mutant in any manifest, versioned or not, never switches on.
        let project = try makeTemporaryDirectory()
        try makeFiles(
            [
                "Package.swift",
                "Package@swift-5.9.swift",
                "Package@swift-6.0.swift",
                "LocalPackages/Dependency/Package.swift",
                "LocalPackages/Dependency/Package@swift-6.0.swift",
                "Sources/Library/Library.swift",
            ],
            in: project
        )

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered(["\(project)/Sources/Library/Library.swift"]),
        ])
    }

    // A tool's files in a hidden folder, as SwiftProjectLint's `.swiftinfer` holds, and a hidden file, are in no
    // target.
    func test_hiddenFoldersAndFiles_areLeftOut() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(
            ["Sources/App.swift", ".swiftinfer/Inferred.swift", "Sources/.cache/Cached.swift", "Sources/.Hidden.swift"],
            in: project
        )

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/Sources/App.swift"])])
        XCTAssertEqual(process.commandsRun, [])
    }

    // Describe is asked for only when the build system is swift, by the executable's name or by `buildSystem:`, so not
    // even `swift` is asked when `buildSystem:` says otherwise. For any other build system the walk is no fallback, and
    // nothing is said.
    func test_aProjectNotTestedWithSwift_isWalked_withoutAWarning() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["Sources/App.swift"], in: project)
        var warnings: [String] = []
        let observer = runEvents.observe(.packageSourceFilesUnavailable) { warnings.append($0.object as? String ?? "") }
        defer { observer.cancel() }
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        for configuration in [
            MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"]),
            MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], buildSystem: .xcodebuild),
        ] {
            state.muterConfiguration = configuration

            let result = try await sut.run(with: state)

            XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/Sources/App.swift"])])
        }
        XCTAssertEqual(process.commandsRun, [])
        XCTAssertEqual(warnings, [])
    }

    // On a disk that tells case apart, as Linux's does, an ignored file isn't kept for having a listed file's path in
    // another case.
    func test_filesGitIgnores_areLeftOut_thoughAListedPathDiffersOnlyInCase() async throws {
        fileManager.subpathsToReturn = ["Sources/Gen/Strings.swift", "Sources/gen/Strings.swift"]
        // Both are there.
        fileManager.fileExistsToReturn = [true, true]
        current.listProjectFiles = { _ in ["Sources/Gen/Strings.swift"] }

        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/copy", isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["/copy/Sources/Gen/Strings.swift"])])
    }

    // Stopping the run kills describe, which then reads as failed: no warning is due, and the project isn't walked.
    func test_aDescribeTheStopKilled_throwsCancellation() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["Sources/Lib/Lib.swift"], in: project)
        process.commandResult = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return CommandResult(status: 9, endedBySignal: true, output: "", errors: "")
        }
        var warnings: [String] = []
        let observer = runEvents.observe(.packageSourceFilesUnavailable) { warnings.append($0.object as? String ?? "") }
        defer { observer.cancel() }
        let listed = Locked(false)
        current.listProjectFiles = { _ in
            listed.change { $0 = true }
            return nil
        }

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(warnings, [])
        XCTAssertFalse(listed.value)
    }

    // Derived data in the project, which holds the packages it depends on, is usually ignored. The project's own
    // listing is asked for, not its copy's: a repository that ignores SwiftMutator's copies lists nothing there. A
    // hidden file is left out though git lists it, and a file renamed only in case, which macOS's git lists by its old
    // name, is kept.
    func test_filesGitIgnores_areLeftOut() async throws {
        current.fileManager = FileManager.default
        let copy = try makeTemporaryDirectory()
        try makeFiles(
            [
                "Sources/App.swift",
                "Sources/Model.swift",
                "Sources/Untracked.swift",
                ".swiftinfer/Inferred.swift",
                "DerivedData/SourcePackages/checkouts/Dependency.swift",
            ],
            in: copy
        )
        let listed = Locked<[URL]>([])
        current.listProjectFiles = { url in
            listed.change { $0.append(url) }
            return [
                "Sources/App.swift",
                "Sources/model.swift",
                "Sources/Untracked.swift",
                "Sources/Deleted.swift",
                ".swiftinfer/Inferred.swift",
                "muter.conf.yml",
            ]
        }

        state.projectDirectoryURL = URL(fileURLWithPath: "/project", isDirectory: true)
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: copy, isDirectory: true)

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [
            .sourceFileCandidatesDiscovered([
                "\(copy)/Sources/App.swift",
                "\(copy)/Sources/Model.swift",
                "\(copy)/Sources/Untracked.swift",
            ]),
        ])
        XCTAssertEqual(listed.value, [URL(fileURLWithPath: "/project", isDirectory: true)])
    }
}
