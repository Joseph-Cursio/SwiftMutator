@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

extension MutationTestHandlerTests {
    func test_allSteps() {
        sut = MutationTestHandler(options: .make())

        XCTAssertEqual(sut.steps.count, 17)

        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], CreateMutatedProjectDirectoryURL.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], LockMutatedProject.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], PreviousRunCleanUp.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], CopyProjectToTempDirectory.self)
        // Right after the copy: discovery rewrites the copy's files within milliseconds of starting.
        XCTAssertTypeEqual(sut.steps[safe: 6], FingerprintProjectTree.self)
        // Once the fingerprint holds the project's files as they are, before the first build.
        XCTAssertTypeEqual(sut.steps[safe: 7], TurnOffSwiftLintPhases.self)
        XCTAssertTypeEqual(sut.steps[safe: 8], DiscoverProjectCoverage.self)
        XCTAssertTypeEqual(sut.steps[safe: 9], DiscoverSourceFiles.self)
        XCTAssertTypeEqual(sut.steps[safe: 10], DiscoverBuildConditions.self)
        XCTAssertTypeEqual(sut.steps[safe: 11], DiscoverMutationPoints.self)
        XCTAssertTypeEqual(sut.steps[safe: 12], PruneLogFolders.self)
        XCTAssertTypeEqual(sut.steps[safe: 13], ApplySchemata.self)
        XCTAssertTypeEqual(sut.steps[safe: 14], CheckMutantSwitches.self)
        XCTAssertTypeEqual(sut.steps[safe: 15], BuildForTesting.self)
        XCTAssertTypeEqual(sut.steps[safe: 16], PerformMutationTesting.self)
    }

    func test_steps_whenResuming() {
        sut = MutationTestHandler(options: .make(resumeURL: URL(fileURLWithPath: "/logs/results.jsonl")))

        XCTAssertEqual(sut.steps.count, 18)

        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], LoadResumeState.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], CreateMutatedProjectDirectoryURL.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], LockMutatedProject.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], PreviousRunCleanUp.self)
        XCTAssertTypeEqual(sut.steps[safe: 6], CopyProjectToTempDirectory.self)
        XCTAssertTypeEqual(sut.steps[safe: 7], FingerprintProjectTree.self)
        XCTAssertTypeEqual(sut.steps[safe: 8], TurnOffSwiftLintPhases.self)
        XCTAssertTypeEqual(sut.steps[safe: 13], PruneLogFolders.self)
        XCTAssertTypeEqual(sut.steps[safe: 17], PerformMutationTesting.self)
    }

    // A reuse loads the earlier run's results file where a resume does, so it's refused as early.
    func test_steps_whenReusing_loadTheEarlierRunsResults_whereAResumeDoes() {
        let reusing = MutationTestHandler(options: .make(reuseURL: URL(fileURLWithPath: "/logs/results.jsonl")))
        let resuming = MutationTestHandler(options: .make(resumeURL: URL(fileURLWithPath: "/logs/results.jsonl")))

        XCTAssertEqual(reusing.steps.map { "\(type(of: $0))" }, resuming.steps.map { "\(type(of: $0))" })
    }

    func test_steps_whenSkipsCoverage() {
        sut = MutationTestHandler(options: .make(skipCoverage: true))

        assertStepsDoesNotContain(sut.steps, DiscoverProjectCoverage.self)
    }

    func test_steps_whenSkipUpdateCheck() {
        sut = MutationTestHandler(options: .make(skipUpdateCheck: true))

        assertStepsDoesNotContain(sut.steps, UpdateCheck.self)
    }

    func test_steps_whenRunWithouMutating() throws {
        fileManager.fileContentsToReturn = MuterTestPlan.make()
            .toData(under: URL(fileURLWithPath: "/path/to/project"))

        sut = MutationTestHandler(
            options: .make(
                testPlanURL: URL(fileURLWithPath: "/path/to/testplan")
            )
        )

        XCTAssertEqual(sut.steps.count, 12)
        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], LoadMuterTestPlan.self)
        // It reads only the project, so a stale plan is refused before another run's copy is waited on.
        XCTAssertTypeEqual(sut.steps[safe: 3], CheckTestPlanSources.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], LockMutatedProject.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], CheckTestPlanCode.self)
        // The plan's code may have been edited by hand since it was made.
        XCTAssertTypeEqual(sut.steps[safe: 6], CheckMutantSwitches.self)
        // After the lock, in the copy as it is tested, which the results file records.
        XCTAssertTypeEqual(sut.steps[safe: 7], FingerprintProjectTree.self)
        // Once the plan's code and copy can no longer refuse the run.
        XCTAssertTypeEqual(sut.steps[safe: 8], PruneLogFolders.self)
        XCTAssertTypeEqual(sut.steps[safe: 9], BuildForTesting.self)
        XCTAssertTypeEqual(sut.steps[safe: 10], ProjectMappings.self)
        XCTAssertTypeEqual(sut.steps[safe: 11], PerformMutationTesting.self)
    }

    func test_steps_whenRunWithoutMutating_resumes() throws {
        sut = MutationTestHandler(
            options: .make(
                testPlanURL: URL(fileURLWithPath: "/path/to/testplan"),
                resumeURL: URL(fileURLWithPath: "/logs/results.jsonl")
            )
        )

        XCTAssertEqual(sut.steps.count, 13)
        XCTAssertTypeEqual(sut.steps[safe: 2], LoadMuterTestPlan.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], CheckTestPlanSources.self)
        // After the plan, which it compares, and before the lock, as in a run's: a results file another session still
        // writes is refused for that alone.
        XCTAssertTypeEqual(sut.steps[safe: 4], LoadResumeState.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], LockMutatedProject.self)
        // Compares the copy with the one the last session tested.
        XCTAssertTypeEqual(sut.steps[safe: 8], FingerprintProjectTree.self)
        // A changed copy refuses the resume, before any folder is removed.
        XCTAssertTypeEqual(sut.steps[safe: 9], PruneLogFolders.self)
        XCTAssertTypeEqual(sut.steps[safe: 12], PerformMutationTesting.self)
    }

    // The copy gets only that mutant's switch, and the rest of the run is a whole run's, but for pruning log folders:
    // a short probe, the run most likely to go alongside another, never removes theirs.
    func test_steps_whenRunningOneMutant() {
        let whole = MutationTestHandler(options: .make(skipCoverage: true)).steps.map { "\(type(of: $0))" }
            .filter { $0 != "PruneLogFolders" }
        sut = MutationTestHandler(options: .make(skipCoverage: true, mutant: MutantReference(path: "B", line: 1)))

        var expected = whole
        expected.insert("SelectMutant", at: whole.firstIndex(of: "ApplySchemata") ?? 0)
        XCTAssertEqual(sut.steps.map { "\(type(of: $0))" }, expected)
        let discovering = whole.firstIndex(of: "DiscoverMutationPoints") ?? 0
        XCTAssertEqual(expected.firstIndex(of: "SelectMutant"), discovering + 1)
    }

    // Right after the plan is read, so its checks look only at the mutant's file, and before the copy is locked: it
    // reads only the plan.
    func test_steps_whenRunWithoutMutating_testsOneMutant() {
        sut = MutationTestHandler(
            options: .make(
                testPlanURL: URL(fileURLWithPath: "/path/to/testplan"),
                mutant: MutantReference(path: "Bar.swift", line: 12)
            )
        )

        XCTAssertEqual(sut.steps.count, 12)
        XCTAssertTypeEqual(sut.steps[safe: 2], LoadMuterTestPlan.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], SelectMutant.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], CheckTestPlanSources.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], LockMutatedProject.self)
        // No pruning: a run of one mutant never removes other runs' log folders.
        XCTAssertTypeEqual(sut.steps[safe: 6], CheckTestPlanCode.self)
        XCTAssertTypeEqual(sut.steps[safe: 11], PerformMutationTesting.self)
    }

    func test_steps_withoutMutant_haveNoSelectMutant() {
        let commands: [Run.Options] = [
            .make(),
            .make(createTestPlan: true),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan")),
        ]
        for options in commands {
            assertStepsDoesNotContain(MutationTestHandler(options: options).steps, SelectMutant.self)
        }
    }

    func test_steps_whenMutateWithoutRunning() {
        sut = MutationTestHandler(
            options: .make(
                createTestPlan: true
            )
        )

        XCTAssertEqual(sut.steps.count, 16)
        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], CreateMutatedProjectDirectoryURL.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], LockMutatedProject.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], PreviousRunCleanUp.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], CopyProjectToTempDirectory.self)
        // Before anything is rewritten: the plan records the project's files as they were.
        XCTAssertTypeEqual(sut.steps[safe: 6], FingerprintProjectTree.self)
        // In the copy the plan's runs build, which keeps it.
        XCTAssertTypeEqual(sut.steps[safe: 7], TurnOffSwiftLintPhases.self)
        XCTAssertTypeEqual(sut.steps[safe: 8], DiscoverProjectCoverage.self)
        XCTAssertTypeEqual(sut.steps[safe: 9], DiscoverSourceFiles.self)
        XCTAssertTypeEqual(sut.steps[safe: 10], DiscoverBuildConditions.self)
        XCTAssertTypeEqual(sut.steps[safe: 11], DiscoverMutationPoints.self)
        XCTAssertTypeEqual(sut.steps[safe: 12], PruneLogFolders.self)
        XCTAssertTypeEqual(sut.steps[safe: 13], ApplySchemata.self)
        // No plan is made whose code lacks a mutant's switch.
        XCTAssertTypeEqual(sut.steps[safe: 14], CheckMutantSwitches.self)
        XCTAssertTypeEqual(sut.steps[safe: 15], CreateMuterTestPlan.self)
    }

    func assertStepsDoesNotContain(
        _ steps: [MutationStep],
        _ step: MutationStep.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            steps.contains { type(of: $0) == step },
            file: file,
            line: line
        )
    }
}
