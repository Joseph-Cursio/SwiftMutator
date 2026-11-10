@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

extension MutationTestHandlerTests {
    // A run still writing the results file tests in the copy that cleaning up removes, and a refused resume should
    // leave everything as it was.
    func test_loadResumeState_comesBeforeCleanUpAndCopy() throws {
        sut = MutationTestHandler(
            options: .make(skipCoverage: true, skipUpdateCheck: true, resumeURL: URL(fileURLWithPath: "/logs"))
        )
        let index = { (step: MutationStep.Type) in self.sut.steps.firstIndex { type(of: $0) == step } }

        let loading = try XCTUnwrap(index(LoadResumeState.self))
        XCTAssertLessThan(try XCTUnwrap(index(LoadConfiguration.self)), loading, "it compares the configuration")
        XCTAssertLessThan(loading, try XCTUnwrap(index(PreviousRunCleanUp.self)))
        XCTAssertLessThan(loading, try XCTUnwrap(index(CopyProjectToTempDirectory.self)))
    }

    // Every command that uses the mutated project locks it once it knows where it is, and before it reads, removes,
    // copies, builds or tests anything there: a run, a resumed run, mutate-without-running and run-without-mutating.
    func test_lockMutatedProject_comesBeforeAnythingIsReadRemovedCopiedOrTested() throws {
        let commands: [Run.Options] = [
            .make(),
            .make(resumeURL: URL(fileURLWithPath: "/logs")),
            .make(createTestPlan: true),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan")),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan"), resumeURL: URL(fileURLWithPath: "/logs")),
            .make(mutant: MutantReference(path: "Bar.swift", line: 12)),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan"), mutant: MutantReference(path: "B", line: 1)),
        ]
        let users: [MutationStep.Type] = [
            CheckTestPlanCode.self,
            CheckMutantSwitches.self,
            PreviousRunCleanUp.self,
            CopyProjectToTempDirectory.self,
            FingerprintProjectTree.self,
            TurnOffSwiftLintPhases.self,
            BuildForTesting.self,
            PerformMutationTesting.self,
        ]

        for options in commands {
            let steps = MutationTestHandler(options: options).steps
            let index = { (step: MutationStep.Type) in steps.firstIndex { type(of: $0) == step } }
            let locking = try XCTUnwrap(index(LockMutatedProject.self), "\(options)")
            let naming = try XCTUnwrap(
                index(CreateMutatedProjectDirectoryURL.self) ?? index(LoadMuterTestPlan.self),
                "\(options)"
            )
            XCTAssertLessThan(naming, locking, "it locks the folder the run uses")
            for user in users {
                guard let using = index(user) else { continue }
                XCTAssertLessThan(locking, using, "\(user)")
            }
        }
    }

    // A run started while another of the same project is testing is refused before it removes the other's copy or
    // clones, and the first keeps its lock until its work has ended.
    func test_aSecondRunOfAProject_isRefusedBeforeItRemovesAnything() async throws {
        current.mutatedProjectLocker = MutatedProjectLock.Locker()
        let project = URL(fileURLWithPath: try makeTemporaryDirectory()).appendingPathComponent("x")
        let steps: () -> [MutationStep] = {
            [CreateMutatedProjectDirectoryURL(), LockMutatedProject(), PreviousRunCleanUp()]
        }
        let givenState = { () -> MutationTestState in
            let made = MutationTestState()
            made.projectDirectoryURL = project
            return made
        }
        let first = givenState()
        try await MutationTestHandler(steps: steps(), state: first).run()
        // As if the first run had copied the project.
        fileManager.fileExistsToReturn = [true]
        let firstRunsCalls = fileManager.methodCalls.count
        let firstRunsPaths = fileManager.paths.count
        let firstRunsListings = fileManager.contentsOfDirectoryAtPath.count
        let second = givenState()

        await AssertThrowsError(try await MutationTestHandler(steps: steps(), state: second).run()) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: project.path + "_mutated.noindex", process: getpid())
            )
        }
        let secondRunsCalls = fileManager.methodCalls.dropFirst(firstRunsCalls)
        XCTAssertFalse(secondRunsCalls.contains("fileExists(atPath:)"), "\(secondRunsCalls)")
        // The refused run lists and removes only its own log folder, which it kept nothing in.
        XCTAssertEqual(
            Array(fileManager.contentsOfDirectoryAtPath.dropFirst(firstRunsListings)),
            [second.loggingDirectory]
        )
        let secondRunsPaths = fileManager.paths.dropFirst(firstRunsPaths)
        let logsRoot = second.loggingDirectory.deletingLastPathComponent
        XCTAssertTrue(
            secondRunsPaths.allSatisfy { $0 == second.loggingDirectory || $0 == logsRoot },
            "\(secondRunsPaths)"
        )

        first.mutatedProjectLock?.release()
        try await MutationTestHandler(steps: steps(), state: givenState()).run()
        XCTAssertTrue(fileManager.paths.contains(project.path + "_mutated.noindex"), "\(fileManager.paths)")
    }

    // A test plan's run is refused before it reads anything under the mutated project's path, which another run may
    // be rewriting. Checking the plan against the project reads only the project, although the copy was edited.
    func test_aRunOfATestPlan_whileAnotherRunUsesItsMutatedProject_readsNothingThere() async throws {
        current.mutatedProjectLocker = MutatedProjectLock.Locker()
        let root = URL(fileURLWithPath: try makeTemporaryDirectory())
        let mutatedProject = root.appendingPathComponent("x_mutated")
        let project = root.appendingPathComponent("x")
        let source = "func check(_ value: Int) -> Bool {\n    return value > 1\n}\n"
        try write(source, to: project.appendingPathComponent("Sources/Check.swift"))
        try write("edited by hand", to: mutatedProject.appendingPathComponent("Sources/Check.swift"))
        let other = try MutatedProjectLock.Locker().lock(mutatedProject)
        let mapping = try XCTUnwrap(
            generateSchemataMappings(
                for: SourceCodeInfo(
                    path: mutatedProject.path + "/Sources/Check.swift",
                    code: Parser.parse(source: source)
                )
            ).first
        )
        let files = ["Sources/Check.swift": FileDigest.sha256(of: Data(source.utf8))]
        let sources = ProjectTree(
            listedBy: .git,
            files: files,
            excluded: [],
            treeSHA256: ProjectTree.treeHash(of: files)
        )
        let plan = MuterTestPlan.make(
            mutatedProjectPath: mutatedProject.path,
            sources: sources,
            mappings: [mapping]
        )
        fileManager.fileContentsToReturn = plan.toData(under: project)
        let listed = Locked<[URL]>([])
        current.listProjectFiles = { directory in
            listed.change { $0.append(directory) }
            return ["Sources/Check.swift"]
        }
        let givenState = MutationTestState()
        givenState.projectDirectoryURL = project
        givenState.runOptions = .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json"))
        givenState.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let steps: [MutationStep] = [
            LoadMuterTestPlan(), CheckTestPlanSources(), LockMutatedProject(), CheckTestPlanCode(),
        ]

        await AssertThrowsError(try await MutationTestHandler(steps: steps, state: givenState).run()) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: mutatedProject.path, process: getpid())
            )
        }
        XCTAssertEqual(fileManager.contentsAtPath, ["/project/muter-mappings.json"])
        XCTAssertEqual(listed.value, [project])
        withExtendedLifetime(other) {}
    }

    func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    // After every step that can refuse the run or find nothing to test, so a run that ends that way removes nothing
    // and never counts as one of the runs kept, and before the build and the test runs, so the space is freed before
    // most logs are written. A run of one mutant has no pruning at all.
    func test_pruneLogFolders_comesOnceNothingCanRefuseTheRun_andBeforeAnythingIsBuilt() throws {
        let commands: [Run.Options] = [
            .make(),
            .make(since: "main"),
            .make(skipCoverage: true),
            .make(shard: Shard(index: 2, count: 4)),
            .make(resumeURL: URL(fileURLWithPath: "/logs")),
            .make(reuseURL: URL(fileURLWithPath: "/logs")),
            .make(createTestPlan: true),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan")),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan"), resumeURL: URL(fileURLWithPath: "/logs")),
        ]
        // Each can refuse the run (`ResumeRefused`, `TestPlanRefused`, a lock in use), or find nothing to test
        // (`NothingToMutate`, `EmptyShard`).
        let before: [MutationStep.Type] = [
            LoadConfiguration.self, SelectChangedCode.self, LoadResumeState.self, LoadMuterTestPlan.self,
            CheckTestPlanSources.self, LockMutatedProject.self, CheckTestPlanCode.self, FingerprintProjectTree.self,
            ListChangedSources.self, DiscoverSourceFiles.self, DiscoverMutationPoints.self,
        ]
        let after: [MutationStep.Type] = [
            ApplySchemata.self, BuildForTesting.self, PerformMutationTesting.self, CreateMuterTestPlan.self,
        ]

        for options in commands {
            let steps = MutationTestHandler(options: options).steps
            let index = { (step: MutationStep.Type) in steps.firstIndex { type(of: $0) == step } }
            let pruning = try XCTUnwrap(index(PruneLogFolders.self), "\(options)")
            for step in before {
                guard let earlier = index(step) else { continue }
                XCTAssertLessThan(earlier, pruning, "\(step), \(options)")
            }
            for step in after {
                guard let later = index(step) else { continue }
                XCTAssertLessThan(pruning, later, "\(step), \(options)")
            }
        }
        for options: Run.Options in [
            .make(mutant: MutantReference(path: "Bar.swift", line: 12)),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan"), mutant: MutantReference(path: "B", line: 1)),
        ] {
            assertStepsDoesNotContain(MutationTestHandler(options: options).steps, PruneLogFolders.self)
        }
    }
}
