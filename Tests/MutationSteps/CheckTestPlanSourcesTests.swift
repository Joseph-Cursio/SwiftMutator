import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

/// Real folders for the project and its copy, and an injected listing in place of git.
final class CheckTestPlanSourcesTests: MuterTestCase {
    let state = MutationTestState()
    let sut = CheckTestPlanSources()
    var project = ""
    var copyPath = ""
    var planPath = ""
    let listed = Locked<[URL]>([])
    let said = Locked<[RunEvent]>([])

    /// The project's files when the plan was made.
    let recorded = [
        "Package.swift": "// swift-tools-version:5.9",
        "Sources/Max.swift": "let max = 2",
        "Sources/Sum.swift": "let sum = 1",
        "Tests/SumTests.swift": "import XCTest",
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = try makeTemporaryDirectory()
        project = "\(root)/project"
        copyPath = "\(root)/project_mutated"
        planPath = "\(project)/muter-mappings.json"
        state.projectDirectoryURL = URL(fileURLWithPath: project)
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: copyPath)
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: planPath))
        let subscription = runEvents.observe { [said] event in
            switch event.name {
            case .testPlanSourcesUnchecked, .testPlanSourcesDiffer, .testPlanUntestedFilesChanged,
                 .testPlanChangesWaived:
                said.change { $0.append(event) }

            default:
                break
            }
        }
        addTeardownBlock { subscription.cancel() }
    }

    // XCTest calls it after `setUpWithError()`, and `MuterTestCase` sets up the dependencies afresh in both. A listing
    // of every file in place of git's.
    override func setUp() {
        super.setUp()
        current.listProjectFiles = { [listed] directory in
            listed.change { $0.append(directory) }
            return (try? FileManager.default.subpathsOfDirectory(atPath: directory.path))?
                .filter { !Self.isFolder("\(directory.path)/\($0)") }
        }
    }

    func test_unchangedSources_pass_withNothingSaid() async throws {
        try write(recorded, in: project)
        plan(mutating: ["Sources/Sum.swift", "Sources/Max.swift"])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes, [])
        XCTAssertEqual(said.value.map(\.name), [])
        XCTAssertEqual(listed.value.map(\.path), [project])
    }

    // The copy holds the files as they were, so its mutants' places describe code that isn't there any more. Each
    // file is named with the flag that lets its change through.
    func test_aChangedFileThePlanMutates_isRefused_namingItsGlob() async throws {
        var now = recorded.merging(["Sources/Sum.swift": "let sum = 1 + 1"]) { $1 }
        now["Sources/Max.swift"] = nil
        try write(now, in: project)
        plan(mutating: ["Sources/Sum.swift", "Sources/Max.swift"])

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? TestPlanRefused,
                TestPlanRefused(
                    path: self.planPath,
                    reason: .sourcesChanged([
                        .init(path: "Sources/Max.swift", kind: .removed),
                        .init(path: "Sources/Sum.swift", kind: .changed),
                    ])
                )
            )
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .testPlanRefused)
            XCTAssertEqual(
                "\(error)",
                """
                SwiftMutator won't test the plan \(Logger.shellQuoted(self.planPath)): 2 files it mutates changed \
                since `swift-mutator mutate-without-running` made it:
                  - Sources/Max.swift was removed
                  - Sources/Sum.swift changed
                The plan's copy holds them as they were, so its mutants' places, and the report's lines in these \
                files, would describe code you no longer have. Make the plan again, or test the copy as it is with:
                  --plan-ignoring 'Sources/Max.swift' --plan-ignoring 'Sources/Sum.swift'
                Nothing was tested.
                """
            )
        }
        XCTAssertEqual(said.value.map(\.name), [])
    }

    // Ten are named, each with its flag, and the rest counted.
    func test_manyChangedFilesThePlanMutates_nameTen_andCountTheRest() async throws {
        let paths = (1 ... 12).map { "Sources/File\($0).swift" }
        let before = Dictionary(uniqueKeysWithValues: paths.map { ($0, "old") })
        try write(before.mapValues { _ in "new" }, in: project)
        plan(mutating: paths, recorded: before)

        await AssertThrowsError(try await sut.run(with: state)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains(": 12 files it mutates changed since"), message)
            XCTAssertEqual(message.components(separatedBy: "\n  - Sources/").count - 1, 10, message)
            XCTAssertTrue(message.contains("\n  - and 2 more\n"), message)
            XCTAssertTrue(message.contains(", plus globs for the other 2\nNothing was tested."), message)
        }
    }

    // The copy is tested as it is, with the files as they were, which may be what was meant: only said.
    func test_aChangedTestFile_orAnAddedPackageResolved_isOnlySaid() async throws {
        let now = recorded.merging(["Tests/SumTests.swift": "import Testing", "Package.resolved": "{}"]) { $1 }
        try write(now, in: project)
        plan(mutating: ["Sources/Sum.swift"])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes, [])
        XCTAssertEqual(said.value.map(\.name), [.testPlanSourcesDiffer])
        XCTAssertEqual(
            said.value.first?.object as? [ProjectTree.FileChange],
            [.init(path: "Package.resolved", kind: .added), .init(path: "Tests/SumTests.swift", kind: .changed)]
        )
    }

    func test_aChangeThatPlanIgnoringMatches_passes_andIsSaid() async throws {
        let now = recorded.merging(["Sources/Sum.swift": "let sum = 1 + 1", "Tests/SumTests.swift": "import Testing"]) {
            $1
        }
        try write(now, in: project)
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: planPath), planIgnoring: ["./Sources/*", "Tests/*"])
        plan(mutating: ["Sources/Sum.swift"])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes, [])
        XCTAssertEqual(said.value.map(\.name), [.testPlanSourcesDiffer, .testPlanChangesWaived])
        // A file the plan doesn't mutate is said either way: the copy holds it as it was.
        XCTAssertEqual(
            said.value.first?.object as? [ProjectTree.FileChange],
            [.init(path: "Tests/SumTests.swift", kind: .changed)]
        )
        XCTAssertEqual(said.value.last?.object as? [String], ["Sources/Sum.swift"])
    }

    // Run from another folder, the plan names a copy beside that folder, which may be another project's. The project
    // isn't fingerprinted, which in such a folder could list a great many files. A file at the top, as `Package.swift`,
    // is in most projects, so it doesn't tell.
    func test_inAFolderWithNoneOfTheFilesItMutates_isRefused() async throws {
        try write(["README.md": "another project", "Package.swift": "// swift-tools-version:5.9"], in: project)
        plan(mutating: ["Sources/Sum.swift", "Sources/Max.swift"])

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? TestPlanRefused,
                TestPlanRefused(
                    path: self.planPath,
                    reason: .notThisProject(folder: self.project, files: 2, mutatedProject: "../project_mutated")
                )
            )
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .testPlanRefused)
            XCTAssertEqual(
                "\(error)",
                "SwiftMutator won't test the plan \(Logger.shellQuoted(self.planPath)): none of the 2 files it "
                    + "mutates is in \(self.project). Run `swift-mutator run-without-mutating` in the folder of the "
                    + "project the plan was made from: the plan finds its copy, ../project_mutated, from there. "
                    + "Nothing was tested."
            )
        }
        XCTAssertEqual(listed.value, [])
    }

    func test_inAFolderWithoutTheOneFileItMutates_isRefused() async throws {
        try write(["README.md": "another project"], in: project)
        plan(mutating: ["Sources/Sum.swift"])

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertTrue("\(error)".contains(": the file it mutates isn't in \(self.project). Run "), "\(error)")
        }
    }

    // A plan in format 0, from before plans recorded the project's files.
    func test_aPlanThatDoesntRecordTheProjectsFiles_isOnlySaid() async throws {
        plan(mutating: ["Sources/Sum.swift"], recorded: nil)

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes, [])
        XCTAssertEqual(said.value.map(\.name), [.testPlanSourcesUnchecked])
        XCTAssertEqual(listed.value, [])
    }

    // With some of the plan's mutants to be tested, as `--mutant` chooses one, a change to another of its files
    // describes no mutant tested. It is said as a file with the plan's other mutants, not as one the plan doesn't
    // mutate.
    func test_onlyTheFilesOfTheMutantsToBeTested_canRefuse() async throws {
        try write(recorded.merging(["Sources/Max.swift": "let max = 3", "Package.resolved": "{}"]) { $1 }, in: project)
        plan(mutating: ["Sources/Sum.swift", "Sources/Max.swift"], recorded: recorded, tested: ["Sources/Sum.swift"])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes, [])
        XCTAssertEqual(said.value.map(\.name), [.testPlanSourcesDiffer, .testPlanUntestedFilesChanged])
        XCTAssertEqual(
            said.value.first?.object as? [ProjectTree.FileChange],
            [.init(path: "Package.resolved", kind: .added)]
        )
        XCTAssertEqual(
            said.value.last?.object as? [ProjectTree.FileChange],
            [.init(path: "Sources/Max.swift", kind: .changed)]
        )
    }

    // A file with mutants that is a symbolic link, here to a file outside the project, is recorded by where it
    // points, which didn't change, and by what its file held, which did.
    func test_aLinkedFileItMutates_whoseFileChanged_isRefused() async throws {
        try write(recorded, in: project)
        let shared = "\(project)/../Shared/Shared.swift"
        try write(["Shared.swift": "let shared = 1"], in: "\(project)/../Shared")
        try FileManager.default.createSymbolicLink(
            atPath: "\(project)/Sources/Shared.swift",
            withDestinationPath: "../../Shared/Shared.swift"
        )
        plan(
            mutating: ["Sources/Shared.swift"],
            recorded: recorded,
            links: ["Sources/Shared.swift": ("../../Shared/Shared.swift", "let shared = 1")]
        )
        let unchanged = try await sut.run(with: state)
        XCTAssertEqual(unchanged, [])
        XCTAssertEqual(said.value.map(\.name), [])

        try Data("let shared = 2".utf8).write(to: URL(fileURLWithPath: shared))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? TestPlanRefused,
                TestPlanRefused(
                    path: self.planPath,
                    reason: .sourcesChanged([.init(path: "Sources/Shared.swift", kind: .changed)])
                )
            )
        }
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: planPath), planIgnoring: ["Sources/Shared.swift"])
        _ = try await sut.run(with: state)
        XCTAssertEqual(said.value.map(\.name), [.testPlanChangesWaived])
    }

    // The copy may have been fixed by hand, on purpose, and another run of the project may be rewriting it until it is
    // locked.
    func test_nothingInTheCopyIsRead_althoughItWasEdited() async throws {
        try write(recorded, in: project)
        try write(recorded.merging(["Sources/Sum.swift": "fixed by hand", "Notes.txt": "new"]) { $1 }, in: copyPath)
        plan(mutating: ["Sources/Sum.swift"])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes, [])
        XCTAssertEqual(said.value.map(\.name), [])
        XCTAssertEqual(listed.value.map(\.path), [project])
    }

    // A plan kept somewhere in the project, under another name, is no change of the project's.
    func test_thePlanItself_isntAChange() async throws {
        planPath = "\(project)/plans/before-the-fix.json"
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: planPath))
        try write(recorded.merging(["plans/before-the-fix.json": "{}"]) { $1 }, in: project)
        plan(mutating: ["Sources/Sum.swift"])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes, [])
        XCTAssertEqual(said.value.map(\.name), [])
    }
}
