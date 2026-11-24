import Foundation
@testable import muterCore
import TestingExtensions

/// The files the coverage run built that the walk of the project leaves out, which a notice names.
extension DiscoverSourceFilesTests {
    // A source a build step generates, which git ignores, or in a hidden folder: coverage names it, the walk leaves it
    // out, and the notice says so. Not a file the excludes leave out, nor one the coverage names that isn't there.
    func test_coveredFilesTheWalkLeavesOut_areNamed() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(
            ["App/Model.swift", "App/Generated/Strings.swift", "App/.gen/Assets.swift", "App/Mocks/StubMock.swift"],
            in: project
        )
        current.listProjectFiles = { _ in ["App/Model.swift", "App/Mocks/StubMock.swift"] }
        let notice = noticesOfCoveredFilesNotWalked()
        defer { notice.observer.cancel() }

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.projectCoverage = Coverage.make(filesInCoverage: [
            "App/Model.swift", "App/Generated/Strings.swift", "\(project)/App/.gen/Assets.swift",
            "App/Mocks/StubMock.swift", "App/Gone.swift",
        ])

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [.sourceFileCandidatesDiscovered(["\(project)/App/Model.swift"])])
        XCTAssertEqual(notice.files.value, [["App/.gen/Assets.swift", "App/Generated/Strings.swift"]])
    }

    // `-clonedSourcePackagesDirPath` can put the packages' checkouts in the project, ignored by git, and a file the
    // walk kept by another case is the same file on a disk that ignores case, as macOS's does.
    func test_aPackagesCheckout_andAFileTheWalkKeptByAnotherCase_areNotNamed() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["App/Model.swift", "SourcePackages/checkouts/Pkg/Sources/Pkg/Pkg.swift"], in: project)
        current.listProjectFiles = { _ in ["App/Model.swift"] }
        let notice = noticesOfCoveredFilesNotWalked()
        defer { notice.observer.cancel() }
        let ignoresCase = FileManager.default.fileExists(atPath: project + "/app/model.swift")

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.projectCoverage = Coverage.make(filesInCoverage: [
            "App/Model.swift", "SourcePackages/checkouts/Pkg/Sources/Pkg/Pkg.swift",
        ] + (ignoresCase ? ["App/model.swift"] : []))

        _ = try await sut.run(with: state)

        XCTAssertEqual(notice.files.value, [])
    }

    // describe says what the targets compile, ignored or not, and `--files-to-mutate` names its own files.
    func test_withoutTheWalk_noFileIsNamed() async throws {
        current.fileManager = FileManager.default
        let project = try makeTemporaryDirectory()
        try makeFiles(["Sources/Lib/Lib.swift", "Generated/Strings.swift"], in: project)
        describing(project, as: [target("library", path: "Sources/Lib", sources: ["Lib.swift"])])
        current.listProjectFiles = { _ in ["Sources/Lib/Lib.swift"] }
        let notice = noticesOfCoveredFilesNotWalked()
        defer { notice.observer.cancel() }
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.projectCoverage = Coverage.make(filesInCoverage: ["Sources/Lib/Lib.swift", "Generated/Strings.swift"])

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        _ = try await sut.run(with: state)
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.filesToMutate = ["Sources/Lib/Lib.swift"]
        _ = try await sut.run(with: state)

        XCTAssertEqual(notice.files.value, [])
    }

    /// The files each notice of covered files the walk left out names.
    private func noticesOfCoveredFilesNotWalked() -> (files: Locked<[[FilePath]]>, observer: RunEvents.Subscription) {
        let files = Locked<[[FilePath]]>([])
        let observer = runEvents.observe(.coveredFilesNotWalked) { event in
            files.change { $0.append(event.object as? [FilePath] ?? []) }
        }
        return (files, observer)
    }
}
