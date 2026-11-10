import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

extension DiscoverUncoveredMutantsTests {
    // A change whose only mutants are in code no test ran, as a function no test calls, has no mutant to test, but
    // with `--baseline` they are new survivors: the run ends comparing them, and fails, rather than with nothing to
    // mutate, which passes. The tested mutants off the changed lines are left out, so an entry for one is not tested.
    func test_changedLines_withOnlyMutantsOfCodeNoTestRan_compareThem_withTheBaselineFile() async throws {
        let path = try write(source, to: "Sign.swift")
        state.sourceFileCandidates = [path]
        state.projectCoverage = coverageMissingIsNegative(reportedAt: path)
        let selection = ChangeSelection.make(
            changedLines: true,
            files: [ChangedFile(path: "Sign.swift", sha256: "", lines: [LineRange(first: 1, last: 1)])]
        )
        state.apply([.changesSelected(selection)])

        let nothing = await error { try await DiscoverMutationPoints().run(with: state) }
        XCTAssertEqual((nothing as? NothingToMutate)?.reason, .noMutantOnChangedLines)

        state.runOptions = .make(baseline: "muter.baseline.yml")
        let tested = MutantKey(
            path: "Sign.swift",
            mutationOperatorId: .relationalBoundary,
            line: 3,
            column: 11,
            occurrence: 0
        )
        state.apply([.baselineFileLoaded(baselineFile(recording: [tested]))])
        let only = try await onlyUncoveredMutants(of: state)

        XCTAssertEqual(only.selection, selection)
        XCTAssertEqual(only.uncovered, 3)
        XCTAssertFalse(only.check.passed)
        guard case let .checked(comparison) = only.check.verdict else {
            XCTFail("\(only.check)")
            return
        }
        XCTAssertEqual(comparison.newSurvivors.map(\.mutant), [
            "Sign.swift:1:47 RelationalBoundary", "Sign.swift:1:47 RelationalOperatorReplacement",
            "Sign.swift:1:50 RelationalOperatorReplacement",
        ].sorted())
        XCTAssertTrue(comparison.newSurvivors.allSatisfy(\.notCovered))
        XCTAssertEqual(comparison.notTested, 1)
        XCTAssertEqual(comparison.fixed, 0)
        XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: only), .scoreBelowThreshold)
        XCTAssertTrue(Run.message(showing: only).hasPrefix(
            "ℹ️ No mutant is left to test in the code --since chose, since the merge base of main and HEAD "
                + "(ba5e000), but it holds 3 mutants of code no test ran, compared with the baseline file "
                + "muter.baseline.yml.\n❌ 3 new survivors against the baseline file muter.baseline.yml"
        ), Run.message(showing: only))

        // Allowed, they pass, and the run exits 0.
        state.runOptions = .make(baseline: "muter.baseline.yml", maxNewSurvivors: 3)
        let allowed = try await onlyUncoveredMutants(of: state)
        XCTAssertTrue(allowed.check.passed)
        XCTAssertNil(ExitCode.exitStatus(afterRunFailedWith: allowed))
        XCTAssertNil(allowed.scoreDrop)
        XCTAssertNil(allowed.doubtfulKills)

        try await assertTheScoreAndKillsVerdicts_followTheSurvivors()
    }

    /// With the score and the kills checked too, the run says their verdicts after the survivors', and too many new
    /// survivors still fail it.
    func assertTheScoreAndKillsVerdicts_followTheSurvivors() async throws {
        // As a run does: the score of the code --since chose isn't compared, and no kill is doubtful, as none was
        // tested.
        state.runOptions = .make(
            baseline: "muter.baseline.yml",
            maxNewSurvivors: 3,
            maxScoreDrop: 2,
            maxDoubtfulKills: 0
        )
        let checked = try await onlyUncoveredMutants(of: state)
        XCTAssertEqual(checked.scoreDrop?.verdict, .notChecked(.since))
        XCTAssertEqual(checked.doubtfulKills?.verdict, .checked([]))
        XCTAssertNil(ExitCode.exitStatus(afterRunFailedWith: checked))
        XCTAssertTrue(Run.message(showing: checked).hasSuffix(
            "\n⚠️ The score isn't compared with the baseline file muter.baseline.yml's: the score of the code --since "
                + "chose isn't the whole project's.\n✅ No doubtful kills."
        ), Run.message(showing: checked))
        // Too many new survivors still fail it.
        state.runOptions = .make(baseline: "muter.baseline.yml", maxScoreDrop: 2, maxDoubtfulKills: 0)
        let failed = try await onlyUncoveredMutants(of: state)
        XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: failed), .scoreBelowThreshold)
    }

    // A change that adds only a file no test reaches leaves no file to mutate, but the file coverage leaves out: with
    // `--baseline` it goes on to discovery, which compares its mutants; without, there is nothing to mutate. So for a
    // whole run, which would otherwise have found no file to mutate.
    func test_aChangeOfOnlyAFileCoverageLeavesOut_comparesItsMutants_withTheBaselineFile() async throws {
        current.fileManager = FileManager.default
        let left = try write(uncoveredFile, to: "Check.swift")
        state.muterConfiguration = MuterConfiguration(executable: "", arguments: [])
        state.apply([.candidatePathsListed(["Check.swift"])])
        state.projectCoverage = Coverage.make(filesWithoutCoverage: [left])
        let selection = ChangeSelection.make(files: [ChangedFile(path: "Check.swift", sha256: "", lines: [])])
        state.apply([.changesSelected(selection)])

        let nothing = await error { try await DiscoverSourceFiles().run(with: state) }
        XCTAssertEqual(
            nothing as? NothingToMutate,
            NothingToMutate(reason: .noFileDiscovered(count: 1), selection: selection)
        )

        state.runOptions = .make(baseline: "muter.baseline.yml")
        state.apply([.baselineFileLoaded(baselineFile(recording: []))])
        let changes = try await DiscoverSourceFiles().run(with: state)
        XCTAssertEqual(changes, [.sourceFileCandidatesDiscovered([]), .uncoveredSourceFilesDiscovered([left])])
        state.apply(changes)

        let only = try await onlyUncoveredMutants(of: state)
        XCTAssertEqual(only.selection, selection)
        XCTAssertGreaterThan(only.uncovered, 3)
        XCTAssertFalse(only.check.passed)

        let whole = MutationTestState()
        whole.mutationOperatorList = state.mutationOperatorList
        whole.mutatedProjectDirectoryURL = state.mutatedProjectDirectoryURL
        whole.projectDirectoryURL = state.projectDirectoryURL
        whole.muterConfiguration = state.muterConfiguration
        whole.apply([.candidatePathsListed(["Check.swift"])])
        whole.projectCoverage = state.projectCoverage
        let noFile = await error { try await DiscoverSourceFiles().run(with: whole) }
        XCTAssertEqual(noFile as? MuterError, .noSourceFilesDiscovered)
        whole.runOptions = .make(baseline: "muter.baseline.yml", maxScoreDrop: 2)
        whole.apply([.baselineFileLoaded(baselineFile(recording: []))])
        whole.apply(try await DiscoverSourceFiles().run(with: whole))
        let wholeOnly = try await onlyUncoveredMutants(of: whole)
        XCTAssertNil(wholeOnly.selection)
        XCTAssertEqual(wholeOnly.uncovered, only.uncovered)
        // A whole run that tested nothing scored nothing, so its score isn't compared either, and it says so.
        XCTAssertEqual(wholeOnly.scoreDrop?.verdict, .notChecked(.nothingScored))
        XCTAssertTrue(
            Run.message(showing: wholeOnly).hasSuffix(
                "\n⚠️ The score isn't compared with the baseline file muter.baseline.yml's: no mutant was scored."
            ),
            Run.message(showing: wholeOnly)
        )
    }

    // A file coverage leaves out whose changed code holds no mutant leaves nothing to mutate, said as discovery would
    // have said it of the file.
    func test_aChangeOfOnlyAFileCoverageLeavesOut_withNoMutant_hasNothingToMutate() async throws {
        let left = try write("struct Empty {}\n", to: "Empty.swift")
        state.sourceFileCandidates = []
        state.uncoveredSourceFiles = [left]
        let selection = ChangeSelection.make(files: [ChangedFile(path: "Empty.swift", sha256: "", lines: [])])
        state.apply([.changesSelected(selection)])
        state.runOptions = .make(baseline: "muter.baseline.yml")
        state.apply([.baselineFileLoaded(baselineFile(recording: []))])

        let nothing = await error { try await DiscoverMutationPoints().run(with: state) }
        XCTAssertEqual(
            nothing as? NothingToMutate,
            NothingToMutate(reason: .noFileDiscovered(count: 1), selection: selection)
        )
    }
}
