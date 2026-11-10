@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingParallelTests {
    func test_withThreeWorkers_everyCloneIsBuilt() async throws {
        let clones = (1...2).map { URL(fileURLWithPath: "/project_mutated_worker\($0)") }
        let testing = PerformMutationTesting(
            makeWorkerDirectories: { _, _ in clones }, removeWorkerDirectories: { _ in }
        )
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 3
        )
        state.mutationMapping = try (1...3).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed, .failed, .failed, .failed]

        _ = try await testing.run(with: state)

        XCTAssertEqual(Set(ioDelegate.builtWorkerDirectories), Set(clones))
        XCTAssertEqual(ioDelegate.builtWorkerDirectories.count, 2)
    }

    // Both clone builds fail, in whichever order they finish; the report names the same worker each time.
    func test_whenWorkerClonesFail_theLowestNumberedWorkerIsNamed() async throws {
        let clones = (1...2).map { URL(fileURLWithPath: "/project_mutated_worker\($0)") }
        let testing = PerformMutationTesting(
            makeWorkerDirectories: { _, _ in clones }, removeWorkerDirectories: { _ in }
        )
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 3
        )
        state.mutationMapping = try (1...3).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .buildError, .failed]

        await assertThrowsMuterError(
            try await testing.run(with: state),
            .mutationTestingAborted(
                reason: .workerBaselineTestFailed(worker: 1, directory: clones[0].path, log: "testLog")
            )
        )
    }

    // Clang module caches record the path they were built under, so the clone's own build would fail
    // on the ones copied from the mutated project.
    func test_cloningTheMutatedProject_discardsItsModuleCaches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project_mutated.noindex")
        let files = [
            "Sources/File.swift",
            ".build/debug/kept.o",
            ".build/debug/ModuleCache/Swift.pcm",
            ".build/out/Intermediates.noindex/ModuleCache.noindex/Swift.pcm",
        ]
        for file in files {
            let url = project.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }

        let clones = try await PerformMutationTesting.cloneMutatedProject(project, count: 1)

        XCTAssertEqual(clones.map(\.path), [root.appendingPathComponent("project_mutated_worker1.noindex").path])
        let clone = try XCTUnwrap(clones.first)
        let exists = { (directory: URL, path: String) in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path)
        }
        XCTAssertTrue(exists(clone, "Sources/File.swift"))
        XCTAssertTrue(exists(clone, ".build/debug/kept.o"))
        XCTAssertFalse(exists(clone, ".build/debug/ModuleCache"))
        XCTAssertFalse(exists(clone, ".build/out/Intermediates.noindex/ModuleCache.noindex"))
        XCTAssertTrue(files.allSatisfy { exists(project, $0) }, "the mutated project keeps its caches")
    }

    // Nothing else would remove them until a later parallel run replaced them.
    func test_whenCloningTheSecondWorkerFails_theFirstCloneAndTheSecondsPartialCopyAreRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project_mutated.noindex")
        let source = project.appendingPathComponent("Sources/File.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("let answer = 42".utf8).write(to: source)
        let failingClone = root.appendingPathComponent("project_mutated_worker2.noindex")

        do {
            _ = try await PerformMutationTesting.cloneMutatedProject(project, count: 3) { project, clone in
                guard clone.path == failingClone.path else {
                    return try FileManager.default.copyItem(at: project, to: clone)
                }
                // A copy that fails partway through leaves what it had copied.
                try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
                try Data().write(to: clone.appendingPathComponent("partial.o"))
                throw PerformMutationTesting.WorkerDirectoryError(clone: clone, status: 1)
            }
            XCTFail("the clones were made")
        } catch {
            XCTAssertEqual((error as? PerformMutationTesting.WorkerDirectoryError)?.clone.path, failingClone.path)
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["project_mutated.noindex"])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "let answer = 42", "the project is intact")
    }

    // cp's own message says why, such as a full disk, which its exit status alone doesn't.
    func test_whenCpFails_theCloneFailureSaysWhatCpSaid() async throws {
        #if os(macOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let missingProject = root.appendingPathComponent("project_mutated.noindex")

        do {
            _ = try await PerformMutationTesting.cloneMutatedProject(missingProject, count: 1)
            XCTFail("a project that doesn't exist was cloned")
        } catch let error as PerformMutationTesting.WorkerDirectoryError {
            XCTAssertEqual(error.status, 1)
            XCTAssertEqual(error.error, "cp: \(missingProject.path): No such file or directory")
            XCTAssertTrue(
                error.description.hasSuffix("(cp exited 1): cp: \(missingProject.path): No such file or directory.")
            )
        }
        #endif
    }

    // Each clone's file and link are named after it without `.noindex`, as SwiftMutators from before `.noindex` named
    // them.
    func test_removeClones_removesEveryCloneGiven_andTheActiveMutantFileBesideIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project_mutated.noindex")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("project_mutated.active-mutant"))
        let clones = try (1...3).map { index in
            let clone = root.appendingPathComponent("project_mutated_worker\(index).noindex")
            let object = clone.appendingPathComponent(".build/debug/File.o")
            try FileManager.default.createDirectory(
                at: object.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("object \(index)".utf8).write(to: object)
            try Data().write(to: root.appendingPathComponent("project_mutated_worker\(index).active-mutant"))
            try FileManager.default.createSymbolicLink(
                at: DirectTestRun.helperLink(forWorkerIn: clone), withDestinationURL: URL(fileURLWithPath: "/bin/sh")
            )
            return clone
        }

        PerformMutationTesting.removeClones(clones)

        // The mutated project's own file goes at the end of the run. The links go, not what they lead to.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            ["project_mutated.active-mutant", "project_mutated.noindex"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/bin/sh"))
    }

    // The mutated project is kept after the run, for a look, but not the active-mutant file beside it.
    func test_aSwiftPMRun_removesTheActiveMutantFileBesideTheMutatedProject() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 42
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.paths, ["/project_mutated.Activation.noindex", "/project_mutated.active-mutant"])
    }

    func test_aStoppedSwiftPMRun_removesTheActiveMutantFileBesideTheMutatedProject() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        _ = cancelMutationTesting(whenSent: .newMutationTestOutcomeAvailable)

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(fileManager.paths, ["/project_mutated.Activation.noindex", "/project_mutated.active-mutant"])
        XCTAssertEqual(removedClones, [[workerClone]])
    }

    // Only a `swift test` run names its mutant in a file. An xcodebuild run removes its mutants' derived data instead.
    func test_anXcodebuildRun_removesNoActiveMutantFile() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            fileManager.paths,
            ["/project_mutated.Activation.noindex", "/project_mutated.DerivedData.noindex"]
        )
    }
}
