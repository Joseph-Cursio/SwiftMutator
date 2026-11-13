import Foundation
import SwiftSyntax

/// Which of the discovered mutants a run tests, drops, leaves out or counts as not covered.
extension DiscoverMutationPoints {
    /// A file's mutants, those it had to drop, and those of its code no test ran, which a run doesn't make.
    struct DiscoveredFile {
        let mappings: [SchemataMutationMapping]
        let dropped: [DroppedMutant]
        var uncovered: [UncoveredSchema] = []
    }

    /// A mutant of code no test ran, by the key a whole run gives it, and its schema, which changes nothing, for its
    /// lines.
    struct UncoveredSchema {
        let key: MutantKey
        let schema: MutationSchema
    }

    /// The mutants of code no test ran, sorted by key, of the code the run chose, as a run chooses those it tests:
    /// `--changed-lines` keeps those on lines it changed, and `--shard` those its shard holds (`Shard.holds`), so that
    /// merged shards hold each once. A shard that holds no mutant to test writes no results file, so those it would
    /// hold go to the first shard that holds some. A sample keeps all of them, as they cost nothing to test. With
    /// them, those it left out, which a baseline file's entries for them are paired with, as with the mutants it left
    /// out of its tests.
    static func uncoveredMutants(
        of files: [DiscoveredFile],
        shard: ShardSelection?,
        state: AnyMutationTestState
    ) -> (kept: [UncoveredMutant], leftOut: [UnselectedMutant]) {
        let all = files.flatMap(\.uncovered).sorted { $0.key.comesBefore($1.key) }
        let selection = state.changeSelection.flatMap { $0.changedLines ? $0 : nil }
        let isHeld = shard.map { shard in
            let isFirstWithMutants = shard.mutantsPerShard.firstIndex { $0 > 0 } == shard.index - 1
            return { (key: MutantKey) in
                let index = Shard.index(ofPlace: key, among: shard.count)
                return index == shard.index || isFirstWithMutants && shard.mutantsPerShard[index - 1] == 0
            }
        } ?? { _ in true }
        var kept: [UncoveredMutant] = []
        var leftOut: [UnselectedMutant] = []
        for mutant in all {
            let key = mutant.key
            let onChangedLines = selection.map { selection in
                selection.file(at: key.path)?.isChanged(mutant.schema.lines ?? key.line...key.line) ?? false
            } ?? true
            if onChangedLines, isHeld(key) {
                kept.append(UncoveredMutant(key: key, snapshot: mutant.schema.snapshot))
            } else {
                leftOut.append(UnselectedMutant(
                    key: key,
                    snapshot: mutant.schema.snapshot,
                    originalProjectPath: RepoRelativePath.resolve(key.path, under: state.projectDirectoryURL.path)
                ))
            }
        }
        return (kept, leftOut)
    }

    /// With `--baseline`, when the code the run chose holds no mutant to test, but mutants of code no test ran, those
    /// compared with the baseline file, as the run would compare them at its end, with the verdicts on the score and
    /// the kills that `--max-score-drop` and `--max-doubtful-kills` ask for, for the run to end with
    /// (`OnlyUncoveredMutants`); nil otherwise. As no shard holds a mutant to test, the first alone compares them, so
    /// that each is compared once.
    static func onlyUncoveredMutants(
        of files: [DiscoveredFile],
        all: [SchemataMutationMapping],
        state: AnyMutationTestState
    ) -> OnlyUncoveredMutants? {
        guard DiscoverSourceFiles.comparesUncoveredMutants(state),
              let baseline = state.baselineFile,
              (state.runOptions.shard?.index ?? 1) == 1
        else { return nil }
        let uncovered = uncoveredMutants(of: files, shard: nil, state: state)
        guard !uncovered.kept.isEmpty else { return nil }
        var outcome = MutationTestOutcome(
            since: state.changeSelection,
            projectPath: state.projectDirectoryURL.path,
            mutatedProjectPath: state.mutatedProjectDirectoryURL.path,
            sourceDigests: PerformMutationTesting.sourceDigests(of: state)
        )
        outcome.uncoveredMutants = uncovered.kept
        // Those off the changed lines, whose entries are then not tested, never new or fixed.
        outcome.unselectedMutants = unselectedMutants(of: all, keeping: [], state: state) + uncovered.leftOut
        // So the score's verdict says why it isn't compared, as a run's would.
        outcome.filesToMutate = state.filesToMutate
        return OnlyUncoveredMutants(
            selection: state.changeSelection,
            uncovered: uncovered.kept.count,
            check: NewSurvivorsCheck(
                baseline: baseline,
                maxNewSurvivors: state.runOptions.maxNewSurvivors ?? 0,
                judging: outcome,
                version: version
            ),
            // Nothing was tested, so neither can fail: the score isn't compared, and no kill is doubtful.
            scoreDrop: state.runOptions.maxScoreDrop.map {
                ScoreDropCheck(baseline: baseline, maxScoreDrop: $0, judging: outcome)
            },
            doubtfulKills: state.runOptions.maxDoubtfulKills.map {
                DoubtfulKillsCheck(maxDoubtfulKills: $0, judging: outcome)
            }
        )
    }

    /// The mutants discovery dropped, of the code a run looks at. A `--mutant` run tests one mutant, and how many
    /// others were dropped says nothing about it.
    static func droppedMutants(
        of files: [DiscoveredFile],
        selection: ChangeSelection?,
        mutant: MutantReference?
    ) -> [DroppedMutant] {
        guard mutant == nil else { return [] }
        return files.flatMap(\.dropped)
            .filter { dropped in
                guard let selection, selection.changedLines else { return true }
                return selection.file(at: dropped.path)?.isChanged(
                    dropped.lines ?? dropped.position.line...dropped.position.line
                ) ?? false
            }
            .sorted { ($0.path, $0.position.utf8Offset) < ($1.path, $1.position.utf8Offset) }
    }

    /// With `--baseline`, the mutants of `all` that `--changed-lines`, `--sample` and `--shard` left out of `kept`,
    /// with their keys among all of them: each takes its place's repeats with it, so these are the keys a whole run
    /// gives them. Empty without `--baseline`, which alone compares them, and for a run of one mutant, which compares
    /// none.
    static func unselectedMutants(
        of all: [SchemataMutationMapping],
        keeping kept: [SchemataMutationMapping],
        state: AnyMutationTestState
    ) -> [UnselectedMutant] {
        let options = state.runOptions
        let leavesSomeOut = options.sample != nil || options.shard != nil || state.changeSelection?.changedLines == true
        guard options.baseline != nil, options.mutant == nil, leavesSomeOut else { return [] }
        let root = state.mutatedProjectDirectoryURL
        let keptKeys = Set(MutantKey.keys(for: kept.flatMap(\.mutationSchemata), under: root))
        let schemata = all.mergeByFilePath().flatMap(\.mutationSchemata)
        return zip(MutantKey.keys(for: schemata, under: root), schemata).compactMap { key, schema in
            keptKeys.contains(key) ? nil : UnselectedMutant(
                key: key,
                snapshot: schema.snapshot,
                originalProjectPath: RepoRelativePath.resolve(key.path, under: state.projectDirectoryURL.path)
            )
        }
    }

    /// Of a file's mutants of code no test ran, `uncovered`, those a run without coverage would make, pruned as that
    /// run would prune them, beside the file's other mutants, `covered`, before their pruning (`DroppedMutant.Reason
    /// .nestedInAnOpaqueBody`), and keyed as it would key them, among all of them. Of a place and operator that both
    /// hold, the covered come first, as a run of the covered keys them: the uncovered are the last of their repeats.
    static func uncovered(
        _ uncovered: [SchemataMutationMapping],
        besides covered: [SchemataMutationMapping],
        of source: SourceFileSyntax,
        under projectRoot: URL
    ) -> [UncoveredSchema] {
        guard !uncovered.isEmpty else { return [] }
        var uncoveredCount: [String: Int] = [:]
        for schema in uncovered.flatMap(\.mutationSchemata) {
            uncoveredCount[schema.id, default: 0] += 1
        }
        var all = (covered.mergeByFilePath() + uncovered.mergeByFilePath()).mergeByFilePath()
        for index in all.indices {
            all[index].dropNestedSchemataInOpaqueBodies(of: source)
        }
        let schemata = all.flatMap(\.mutationSchemata)
        var total: [String: Int] = [:]
        for schema in schemata {
            total[schema.id, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        return zip(MutantKey.keys(for: schemata, under: projectRoot), schemata).compactMap { key, schema in
            let index = seen[schema.id, default: 0]
            seen[schema.id] = index + 1
            let firstUncovered = (total[schema.id] ?? 0) - (uncoveredCount[schema.id] ?? 0)
            return index >= firstUncovered ? UncoveredSchema(key: key, schema: schema) : nil
        }
    }

    /// With `--changed-lines`, of each file's mutants, those on lines `selection` says changed; without, all of them.
    /// After the pruning, so a full run's mutants are kept, never ones a full run would have pruned.
    static func mutants(
        of mappings: [SchemataMutationMapping],
        onLinesChangedIn selection: ChangeSelection,
        under projectRoot: URL
    ) -> [SchemataMutationMapping] {
        guard selection.changedLines else { return mappings }
        return mappings.compactMap { mapping in
            let file = selection.file(at: RepoRelativePath.of(mapping.filePath, under: projectRoot))
            var kept = mapping
            kept.keepOnly { file?.isChanged($0.lines ?? $0.position.line...$0.position.line) ?? false }
            return kept.isEmpty ? nil : kept
        }
    }
}
