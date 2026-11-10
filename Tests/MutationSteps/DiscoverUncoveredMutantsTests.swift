import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

/// The mutants of code no test ran, which a run with coverage makes none of, and `--baseline` counts as survivors
/// (`UncoveredMutant`): those of a region no test ran, and of a file coverage leaves out as a whole, keyed as a run
/// without coverage keys them, and chosen as a run chooses the mutants it tests.
final class DiscoverUncoveredMutantsTests: MuterTestCase {
    private let state = MutationTestState()
    private var project = ""
    private let prepared = PreparedPaths()

    /// Mutants on line 1, in a function the tests never run, and on line 3, in one they do: each `<` or `>` gets
    /// RelationalOperatorReplacement's mutant and RelationalBoundary's.
    private let source = """
    func isNegative(_ value: Int) -> Bool { value < 0 }
    func isPositive(_ value: Int) -> Bool {
        value > 0
    }
    """

    /// Line 2's `<`, line 3's `-` and line 4's `==`, each mutated by every operator that mutates it.
    private let uncoveredFile = """
    func check(index: Int, count: Int) -> Bool {
        guard index < count else { return false }
        let last = count - 1
        return index == last
    }
    """

    override func setUpWithError() throws {
        try super.setUpWithError()

        project = try makeTemporaryDirectory()
        // But ReplaceBooleanValue, whose two mutants of each value would say nothing more: its own tests show code no
        // test ran is judged for it as for the others.
        state.mutationOperatorList = MutationOperatorList.allOperators.filter { $0 != .replaceBooleanValue }
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.projectDirectoryURL = URL(fileURLWithPath: "/project", isDirectory: true)
        prepareCode.sourceCodeToReturn = { [prepared] path in
            prepared.add(path)
            return muterCore.sourceCode(fromFileAt: path).map { (source: $0, changes: .null) }
        }
    }

    // After setUpWithError, which XCTest calls first: MuterTestCase installs its world in both.
    override func setUp() {
        super.setUp()

        current.readPreparedCode = { path in
            muterCore.sourceCode(fromFileAt: path).map { (source: $0, changes: .null) }
        }
    }

    // As a run without coverage would key them, so a mutant keeps its key once a test comes to run its code.
    func test_aMutantOfARegionNoTestRan_isRecorded_withTheKeyARunWithoutCoverageGivesIt() async throws {
        let path = try write(source, to: "Sign.swift")
        state.sourceFileCandidates = [path]
        let everyKey = try await keys(of: DiscoverMutationPoints().run(with: state))

        state.projectCoverage = coverageMissingIsNegative(reportedAt: path)
        let changes = try await DiscoverMutationPoints().run(with: state)

        let uncovered = uncoveredMutants(in: changes)
        XCTAssertEqual(uncovered.map(\.key.line), [1, 1, 1])
        XCTAssertEqual(Set(uncovered.map(\.mutationOperatorId)), [.ror, .relationalBoundary])
        XCTAssertEqual(Set(uncovered.map(\.snapshot.before)), ["<", "value < 0"])
        let tested = try keys(of: changes)
        XCTAssertEqual(tested.map(\.line), [3, 3, 3])
        XCTAssertEqual(Set(tested + uncovered.map(\.key)), Set(everyKey))
    }

    // None is recorded as none, so the results say the run looked: results that don't say so make no baseline file.
    func test_withEveryRegionRun_orWithoutCoverage_noneIsRecorded() async throws {
        let path = try write(source, to: "Sign.swift")
        state.sourceFileCandidates = [path]

        let changes = try await DiscoverMutationPoints().run(with: state)

        XCTAssertEqual(uncoveredMutants(in: changes), [])
        XCTAssertTrue(changes.contains { $0 == .mutantsNotCovered([]) })
    }

    // A new file no test reaches is the commonest: it is read as it would be prepared, but the copy's file stays as it
    // is, as no mutant of it is made.
    func test_aFileCoverageLeavesOut_isWalked_butNotRewritten_andKeyedAsAWholeRunKeysIt() async throws {
        let covered = try write(source, to: "Sign.swift")
        let left = try write(uncoveredFile, to: "Check.swift")
        state.sourceFileCandidates = [left]
        let wholeRun = try await keys(of: DiscoverMutationPoints().run(with: state))
        prepared.removeAll()

        state.sourceFileCandidates = [covered]
        state.uncoveredSourceFiles = [left]
        let changes = try await DiscoverMutationPoints().run(with: state)

        XCTAssertEqual(uncoveredMutants(in: changes).map(\.key), wholeRun.sorted { $0.comesBefore($1) })
        XCTAssertEqual(Set(uncoveredMutants(in: changes).map(\.path)), ["Check.swift"])
        XCTAssertEqual(prepared.paths, [covered])
        XCTAssertEqual(try keys(of: changes).map(\.path), [
            "Sign.swift", "Sign.swift", "Sign.swift", "Sign.swift", "Sign.swift", "Sign.swift",
        ])
    }

    // One with no place for a switch is dropped with coverage off too, an inactive `#if` leaves its code out of the
    // build, and `muter:disable` out of the run: a run without coverage would make none of them. Nor is any said to be
    // dropped, as the file isn't the run's.
    func test_aFileCoverageLeavesOut_recordsNoMutantARunWithoutCoverageWouldNotMake() async throws {
        let covered = try write(source, to: "Sign.swift")
        let left = try write("""
        import Foundation
        let value = CommandLine.arguments.count
        guard let name = value > 1 ? "name" : nil else { exit(1) }
        func f(_ a: Int, _ b: Int) -> Bool {
            #if os(macOS)
            let first = a > b
            #else
            let first = a < b
            #endif
            return first
        }

        // muter:disable
        func g(_ a: Int) -> Bool {
            a == 1
        }
        """, to: "Top.swift")
        state.sourceFileCandidates = [covered]
        state.uncoveredSourceFiles = [left]
        state.buildConditions = ProjectBuildConditions(everyTarget: BuildConditions(
            platform: .init(system: "macOS", architectures: ["arm64"]),
            customConditions: [["DEBUG"]]
        ))

        let changes = try await DiscoverMutationPoints().run(with: state)

        XCTAssertEqual(Set(uncoveredMutants(in: changes).map(\.key.line)), [6])
        let dropped = changes.compactMap { change -> [DroppedMutant]? in
            guard case let .mutantsDropped(dropped) = change else { return nil }
            return dropped
        }.joined()
        XCTAssertFalse(dropped.contains { $0.path == "Top.swift" }, "\(Array(dropped))")
    }

    // `--changed-lines` keeps those on the lines it changed; with `--baseline`, the others are kept as left out, so a
    // baseline file's entry for one isn't matched with an identical survivor the run tested.
    func test_changedLines_keepThoseOnTheLinesTheyChanged() async throws {
        let covered = try write(source, to: "Sign.swift")
        let left = try write(uncoveredFile, to: "Check.swift")
        state.sourceFileCandidates = [covered]
        state.uncoveredSourceFiles = [left]
        let selection = ChangeSelection.make(
            changedLines: true,
            files: [
                ChangedFile(path: "Sign.swift", lines: [LineRange(first: 3, last: 3)], sha256: ""),
                ChangedFile(path: "Check.swift", lines: [LineRange(first: 4, last: 4)], sha256: ""),
            ]
        )
        state.apply([.changesSelected(selection)])
        state.runOptions = .make(baseline: "muter.baseline.yml")

        let changes = try await DiscoverMutationPoints().run(with: state)

        XCTAssertEqual(Set(uncoveredMutants(in: changes).map(\.key.line)), [4])
        let leftOut = unselectedMutants(in: changes).filter { $0.key.path == "Check.swift" }
        XCTAssertEqual(Set(leftOut.map(\.key.line)), [2, 3])
        XCTAssertEqual(Set(leftOut.map(\.originalProjectPath)), ["/project/Check.swift"])
    }

    // By the rule a shard's mutants are chosen by, so merged shards hold each once; a sample keeps them all, as they
    // cost nothing to test.
    func test_aShard_holdsThoseItsRuleGivesIt_andASampleKeepsAll() async throws {
        let covered = try write(source, to: "Sign.swift")
        let left = try write(uncoveredFile, to: "Check.swift")
        state.sourceFileCandidates = [covered]
        state.uncoveredSourceFiles = [left]
        let all = try await uncoveredMutants(in: DiscoverMutationPoints().run(with: state))
        XCTAssertGreaterThan(all.count, 3)

        var held: [UncoveredMutant] = []
        for index in 1...3 {
            let shard = Shard(index: index, count: 3)
            state.runOptions = .make(shard: shard)
            let changes = (try? await DiscoverMutationPoints().run(with: state)) ?? []
            let kept = uncoveredMutants(in: changes)
            if !changes.isEmpty {
                XCTAssertEqual(kept.filter { shard.holds($0.key) }, all.filter { shard.holds($0.key) }, "\(shard)")
            }
            held += kept
        }
        XCTAssertEqual(held.sorted { $0.key.comesBefore($1.key) }, all)

        state.runOptions = .make(sample: Sample(size: 1, seed: 7, seedIsChosen: false))
        let sampled = try await DiscoverMutationPoints().run(with: state)
        XCTAssertEqual(uncoveredMutants(in: sampled), all)
    }

    // A run of one mutant compares no survivors.
    func test_aRunOfOneMutant_recordsNone() async throws {
        let path = try write(source, to: "Sign.swift")
        let left = try write(uncoveredFile, to: "Check.swift")
        state.sourceFileCandidates = [path]
        state.uncoveredSourceFiles = [left]
        state.projectCoverage = coverageMissingIsNegative(reportedAt: path)
        state.runOptions = .make(mutant: MutantReference(path: path, line: 3, column: nil))

        let changes = try await DiscoverMutationPoints().run(with: state)

        XCTAssertEqual(uncoveredMutants(in: changes), [])
        XCTAssertFalse(changes.contains { if case .mutantsNotCovered = $0 { true } else { false } })
    }

    // A change whose only mutants are in code no test ran, as a function no test calls, has no mutant to test, but
    // with `--baseline` they are new survivors: the run ends comparing them, and fails, rather than with nothing to
    // mutate, which passes. The tested mutants off the changed lines are left out, so an entry for one is not tested.
    func test_changedLines_withOnlyMutantsOfCodeNoTestRan_compareThem_withTheBaselineFile() async throws {
        let path = try write(source, to: "Sign.swift")
        state.sourceFileCandidates = [path]
        state.projectCoverage = coverageMissingIsNegative(reportedAt: path)
        let selection = ChangeSelection.make(
            changedLines: true,
            files: [ChangedFile(path: "Sign.swift", lines: [LineRange(first: 1, last: 1)], sha256: "")]
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

        // With the score and the kills checked too, it says their verdicts after the survivors', as a run does: the
        // score of the code --since chose isn't compared, and no kill is doubtful, as none was tested.
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
        let selection = ChangeSelection.make(files: [ChangedFile(path: "Check.swift", lines: [], sha256: "")])
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
        let selection = ChangeSelection.make(files: [ChangedFile(path: "Empty.swift", lines: [], sha256: "")])
        state.apply([.changesSelected(selection)])
        state.runOptions = .make(baseline: "muter.baseline.yml")
        state.apply([.baselineFileLoaded(baselineFile(recording: []))])

        let nothing = await error { try await DiscoverMutationPoints().run(with: state) }
        XCTAssertEqual(
            nothing as? NothingToMutate,
            NothingToMutate(reason: .noFileDiscovered(count: 1), selection: selection)
        )
    }

    // A file without coverage, which discovery leaves out, is handed on to be walked for them; with no coverage, as
    // with `--skip-coverage`, none is.
    func test_theFilesCoverageLeavesOut_areHandedOn() async throws {
        current.fileManager = FileManager.default
        let covered = try write(source, to: "Sign.swift")
        let left = try write(uncoveredFile, to: "Check.swift")
        state.muterConfiguration = MuterConfiguration(executable: "", arguments: [])
        state.apply([.candidatePathsListed(["Sign.swift", "Check.swift"])])
        state.projectCoverage = Coverage.make(filesWithoutCoverage: [left])

        let changes = try await DiscoverSourceFiles().run(with: state)

        XCTAssertEqual(changes, [.sourceFileCandidatesDiscovered([covered]), .uncoveredSourceFilesDiscovered([left])])

        state.projectCoverage = .null
        let withoutCoverage = try await DiscoverSourceFiles().run(with: state)
        XCTAssertEqual(withoutCoverage, [.sourceFileCandidatesDiscovered([left, covered].sorted())])
    }
}

private extension DiscoverUncoveredMutantsTests {
    func write(_ contents: String, to name: String) throws -> String {
        let path = "\(project)/\(name)"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Coverage in which only `isNegative`'s body never ran, reported for the file at `path`.
    func coverageMissingIsNegative(reportedAt path: String) -> Coverage {
        Coverage.make(
            functionsCoverage: FunctionsCoverage(
                from: LLVMCoverage(data: [
                    .init(functions: [
                        Function(
                            filenames: [path],
                            regions: [.make(lineStart: 1, columnStart: 39, lineEnd: 1, columnEnd: 52)]
                        ),
                    ]),
                ])
            )
        )
    }

    func keys(of changes: [MutationTestState.Change]) throws -> [MutantKey] {
        let mappings = try XCTUnwrap(changes.lazy.compactMap { change -> [SchemataMutationMapping]? in
            guard case let .mutationMappingsDiscovered(mappings) = change else { return nil }
            return mappings
        }.first)
        return MutantKey.keys(for: mappings.flatMap(\.mutationSchemata), under: state.mutatedProjectDirectoryURL)
    }

    /// A baseline file of `survivors`, each a `<` made `<=`, by the SwiftMutator under test.
    func baselineFile(recording survivors: [MutantKey]) -> BaselineFile {
        BaselineFile(
            path: "muter.baseline.yml",
            swiftMutator: muterCore.version,
            score: .init(killed: 1, scored: 2),
            scope: BaselineScope(operators: [], skipCoverage: false, configuration: .init()),
            survivors: survivors.map { BaselineSurvivor(mutant: $0, outcome: .survived, before: ">", after: ">=") }
        )
    }

    /// What `body` throws; nil when it throws nothing.
    func error(_ body: () async throws -> [MutationTestState.Change]) async -> Error? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error
        }
    }

    /// What discovery ends the run with, when it has only mutants of code no test ran.
    func onlyUncoveredMutants(of state: MutationTestState) async throws -> OnlyUncoveredMutants {
        do {
            let changes = try await DiscoverMutationPoints().run(with: state)
            XCTFail("Discovery found mutants to test: \(changes)")
        } catch let only as OnlyUncoveredMutants {
            return only
        }
        throw MuterError.noMutationPointsDiscovered
    }

    func uncoveredMutants(in changes: [MutationTestState.Change]) -> [UncoveredMutant] {
        changes.lazy.compactMap { change -> [UncoveredMutant]? in
            guard case let .mutantsNotCovered(mutants) = change else { return nil }
            return mutants
        }.first ?? []
    }

    func unselectedMutants(in changes: [MutationTestState.Change]) -> [UnselectedMutant] {
        changes.lazy.compactMap { change -> [UnselectedMutant]? in
            guard case let .mutantsNotSelected(mutants) = change else { return nil }
            return mutants
        }.first ?? []
    }
}

/// The paths the run's own preparation, which rewrites a file, was asked for.
private final class PreparedPaths: @unchecked Sendable { // `stored` is behind `lock`
    private let lock = NSLock()
    private var stored: [String] = []

    var paths: [String] { lock.withLock { stored } }

    func add(_ path: String) {
        lock.withLock { stored.append(path) }
    }

    func removeAll() {
        lock.withLock { stored.removeAll() }
    }
}
