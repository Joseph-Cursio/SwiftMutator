import Foundation
import SwiftSyntax

struct DiscoverMutationPoints: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.prepareCode)
    var prepareSourceCode: SourceCodePreparation
    @Dependency(\.readPreparedCode)
    var readPreparedSourceCode: SourceCodePreparation

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        events.send(.mutationsDiscoveryStarted)

        let scope = Scope(
            operators: state.mutationOperatorList,
            configuration: state.muterConfiguration,
            projectRoot: state.mutatedProjectDirectoryURL,
            buildConditions: state.buildConditions,
            namedMutant: NamedMutant(state)
        )
        let found = await discoverMutationPoints(
            in: scope,
            inFilesAt: state.sourceFileCandidates,
            coverage: state.projectCoverage,
            // A run of one mutant compares no survivors, so it needs none of those coverage leaves out.
            uncoveredFiles: state.runOptions.mutant == nil ? state.uncoveredSourceFiles : []
        )
        let all = found.flatMap(\.mappings)
        let dropped = Self.droppedMutants(of: found, selection: state.changeSelection, mutant: state.runOptions.mutant)
        let discovered = state.changeSelection.map {
            Self.mutants(of: all, onLinesChangedIn: $0, under: state.mutatedProjectDirectoryURL)
        } ?? all

        guard discovered.count >= 1 else {
            try refuseNothingDiscovered(in: found, all: all, dropped: dropped, state: state)
        }

        let chosen = try selection(of: discovered.mergeByFilePath(), dropped: dropped, state: state)
        let (mappings, selected) = (chosen.mappings, chosen.changes)
        let (sampleSelection, shardSelection) = (chosen.sample, chosen.shard)
        if sampleSelection == nil, shardSelection == nil {
            events.send(.mutationsDiscoveryFinished(mappings))
        } else {
            events.send(.mutantsSelected(sample: sampleSelection, shard: shardSelection, mutations: mappings))
        }
        events.send(.mutantsDropped(dropped))
        let uncovered = Self.uncoveredMutants(of: found, shard: shardSelection, state: state)
        let unselected = Self.unselectedMutants(of: all, keeping: mappings, state: state)
            + (state.runOptions.baseline == nil ? [] : uncovered.leftOut)

        return selected + (unselected.isEmpty ? [] : [.mutantsNotSelected(unselected)]) + [
            .mutationMappingsDiscovered(mappings),
            // Pass empty dictionary - ApplySchemata will re-parse files on demand
            // This prevents memory exhaustion on large codebases (2000+ files)
            .sourceCodeParsed([:]),
        ] + (dropped.isEmpty ? [] : [.mutantsDropped(dropped)])
            // Even when there are none, so the results record that the run looked; a run of one mutant doesn't.
            + (state.runOptions.mutant == nil ? [.mutantsNotCovered(uncovered.kept)] : [])
    }

    /// The mutants a run tests of those it discovered: `--sample`'s, then those of its `--shard`, with the changes that
    /// say which, and both selections.
    struct MutantSelection {
        var mappings: [SchemataMutationMapping]
        var changes: [MutationTestState.Change] = []
        var sample: SampleSelection?
        var shard: ShardSelection?
    }

    /// The mutants of `mappings`, those discovered, that the run's `--sample` and `--shard` select. A shard with none
    /// of them stops the run, once the mutants it had to drop, `dropped`, are sent.
    private func selection(
        of mappings: [SchemataMutationMapping],
        dropped: [DroppedMutant],
        state: AnyMutationTestState
    ) throws -> MutantSelection {
        var chosen = MutantSelection(mappings: mappings)
        // The sample first, so that the shards of a sampled split share one sample, and each tests its part.
        if let sample = state.runOptions.sample {
            let (kept, selection, leftOut) = chosen.mappings.keepingSample(
                sample, under: state.mutatedProjectDirectoryURL
            )
            chosen.mappings = kept
            chosen.sample = selection
            chosen.changes += [.sampleSelected(selection), .sampleLeftOut(leftOut)]
        }
        if let shard = state.runOptions.shard {
            let (kept, selection) = chosen.mappings.keepingOnly(shard, under: state.mutatedProjectDirectoryURL)
            guard !kept.isEmpty else {
                events.send(.mutantsDropped(dropped))
                throw EmptyShard(
                    shard: shard,
                    mutantsInAllShards: selection.mutantsInAllShards,
                    sample: chosen.sample.flatMap { $0.isPartial ? $0 : nil }
                )
            }
            chosen.mappings = kept
            chosen.shard = selection
            chosen.changes.append(.shardSelected(selection))
        }
        return chosen
    }

    /// Stops a run that discovered no mutant to test, `found` holding `all` of them before `--changed-lines`, with why:
    /// only mutants of code no test ran, a change that touches no mutated code, a `--mutant` that names none, or no
    /// mutant at all. The mutants it had to drop, `dropped`, are sent first.
    private func refuseNothingDiscovered(
        in found: [DiscoveredFile],
        all: [SchemataMutationMapping],
        dropped: [DroppedMutant],
        state: AnyMutationTestState
    ) throws -> Never {
        // The refusal comes next, so this is the end of discovery.
        events.send(.mutantsDropped(dropped))
        if let only = Self.onlyUncoveredMutants(of: found, all: all, state: state) {
            throw only
        }
        // A change can touch only code no operator mutates, as declarations: nothing to mutate, not a failure.
        if let selection = state.changeSelection {
            // Only a file coverage leaves out was left, for `--baseline`, which holds no mutant it compares.
            if state.sourceFileCandidates.isEmpty, !state.uncoveredSourceFiles.isEmpty {
                throw DiscoverSourceFiles.noFileDiscovered(selection, in: state)
            }
            let reason: NothingToMutate.Reason = all.isEmpty
                ? .noMutantInChangedFiles(count: state.sourceFileCandidates.count)
                : .noMutantOnChangedLines
            let operators = state.mutationOperatorList
            throw NothingToMutate(
                reason: reason,
                selection: selection,
                chosenOperators: Set(operators) == Set(MutationOperatorList.allOperators) ? nil : operators
            )
        }
        // The mutant `--mutant` names isn't there, which its refusal says, as for a project that has others.
        if let reference = state.runOptions.mutant {
            throw MutantRefused(reference: reference, reason: .notFound(nearby: [], files: 0))
        }
        // As `DiscoverSourceFiles` would have said, had it not left only such a file to `--baseline`.
        if state.sourceFileCandidates.isEmpty, !state.uncoveredSourceFiles.isEmpty {
            throw state.filesToMutate.isEmpty ? MuterError.noSourceFilesDiscovered : .noSourceFilesOnExclusiveList
        }
        throw MuterError.noMutationPointsDiscovered
    }
}
