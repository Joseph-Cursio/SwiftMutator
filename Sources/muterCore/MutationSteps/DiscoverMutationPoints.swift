import Foundation
import SwiftSyntax

struct DiscoverMutationPoints: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.prepareCode)
    var prepareSourceCode: SourceCodePreparation

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        events.send(.mutationsDiscoveryStarted)

        let found = await discoverMutationPoints(
            forOperators: state.mutationOperatorList,
            inFilesAt: state.sourceFileCandidates,
            configuration: state.muterConfiguration,
            coverage: state.projectCoverage,
            projectRoot: state.mutatedProjectDirectoryURL,
            buildConditions: state.buildConditions,
            namedMutant: NamedMutant(state)
        )
        let all = found.flatMap(\.mappings)
        let dropped = Self.droppedMutants(of: found, selection: state.changeSelection, mutant: state.runOptions.mutant)
        let discovered = state.changeSelection.map {
            Self.mutants(of: all, onLinesChangedIn: $0, under: state.mutatedProjectDirectoryURL)
        } ?? all

        guard discovered.count >= 1 else {
            // The refusal comes next, so this is the end of discovery.
            events.send(.mutantsDropped(dropped))
            // A change can touch only code no operator mutates, as declarations: nothing to mutate, not a failure.
            if let selection = state.changeSelection {
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
            throw MuterError.noMutationPointsDiscovered
        }

        var mappings = discovered.mergeByFilePath()
        var selected: [MutationTestState.Change] = []
        // The sample first, so that the shards of a sampled split share one sample, and each tests its part.
        var sampleSelection: SampleSelection?
        if let sample = state.runOptions.sample {
            let (kept, selection, leftOut) = mappings.keepingSample(sample, under: state.mutatedProjectDirectoryURL)
            mappings = kept
            sampleSelection = selection
            selected += [.sampleSelected(selection), .sampleLeftOut(leftOut)]
        }
        var shardSelection: ShardSelection?
        if let shard = state.runOptions.shard {
            let (kept, selection) = mappings.keepingOnly(shard, under: state.mutatedProjectDirectoryURL)
            guard !kept.isEmpty else {
                events.send(.mutantsDropped(dropped))
                throw EmptyShard(
                    shard: shard,
                    mutantsInAllShards: selection.mutantsInAllShards,
                    sample: sampleSelection.flatMap { $0.isPartial ? $0 : nil }
                )
            }
            mappings = kept
            shardSelection = selection
            selected.append(.shardSelected(selection))
        }
        if sampleSelection == nil, shardSelection == nil {
            events.send(.mutationsDiscoveryFinished(mappings))
        } else {
            events.send(.mutantsSelected(sample: sampleSelection, shard: shardSelection, mutations: mappings))
        }
        events.send(.mutantsDropped(dropped))

        return selected + [
            .mutationMappingsDiscovered(mappings),
            // Pass empty dictionary - ApplySchemata will re-parse files on demand
            // This prevents memory exhaustion on large codebases (2000+ files)
            .sourceCodeParsed([:]),
        ] + (dropped.isEmpty ? [] : [.mutantsDropped(dropped)])
    }
}

private extension DiscoverMutationPoints {
    /// A file's mutants, and those it had to drop.
    struct DiscoveredFile {
        let mappings: [SchemataMutationMapping]
        let dropped: [DroppedMutant]
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

    /// How many files are parsed and walked at once, which bounds the syntax trees held in memory.
    static let maxConcurrency = 8

    /// Each file's mutation points, from a task group that keeps `maxConcurrency` files in flight, in no set order:
    /// `mergeByFilePath()` sorts them.
    func discoverMutationPoints(
        forOperators operators: MutationOperatorList,
        inFilesAt filePaths: [String],
        configuration: MuterConfiguration,
        coverage: Coverage,
        projectRoot: URL,
        buildConditions: ProjectBuildConditions? = nil,
        namedMutant: NamedMutant? = nil
    ) async -> [DiscoveredFile] {
        var swiftFiles = filePaths.filter(pathContainsDotSwift).makeIterator()

        return await withTaskGroup(of: DiscoveredFile.self) { group in
            func discoverNext() {
                guard let path = swiftFiles.next() else { return }
                group.addTask {
                    // What reading the file autoreleased is freed once the file is done, not whenever the thread's
                    // pool drains.
                    autoreleasepool {
                        guard let sourceCode = prepareSourceCode(path) else {
                            return DiscoveredFile(mappings: [], dropped: [])
                        }

                        return discoverNewSchemataMappings(
                            forOperators: operators,
                            inFile: sourceCode,
                            configuration: configuration,
                            coverage: coverage.coverage(ofFile: path),
                            projectRoot: projectRoot,
                            buildConditions: buildConditions,
                            namedMutant: namedMutant
                        )
                    }
                }
            }

            for _ in 0..<Self.maxConcurrency {
                discoverNext()
            }
            var discovered: [DiscoveredFile] = []
            while let file = await group.next() {
                discovered.append(file)
                discoverNext()
            }
            return discovered
        }
    }

    func discoverNewSchemataMappings(
        forOperators operators: MutationOperatorList,
        inFile sourceCode: PreparedSourceCode,
        configuration: MuterConfiguration,
        coverage: FileCoverage,
        projectRoot: URL,
        buildConditions: ProjectBuildConditions? = nil,
        namedMutant: NamedMutant? = nil
    ) -> DiscoveredFile {
        let source = sourceCode.source.code
        let path = RepoRelativePath.of(sourceCode.source.path, under: projectRoot)
        var droppedByVisitors: [DroppedMutant] = []
        // Worked out once, for all the operators: the walk evaluates each `#if` in the file.
        let inactiveRegions = buildConditions?.conditions(ofFile: path).inactiveRegions(in: source) ?? []

        let mappings: [SchemataMutationMapping] = operators
            .accumulate(into: []) { newSchemataMappings, mutationOperatorId in
                let visitor = mutationOperatorId.visitor(
                    configuration,
                    sourceCode.source,
                    coverage
                )

                visitor.sourceCodePreparationChange = sourceCode.changes
                visitor.projectRoot = projectRoot
                visitor.inactiveRegions = inactiveRegions
                (visitor as? NegateConditionalOperator.Visitor)?.leavesEqualityChecksAlone =
                    operators.contains(.ror) && namedMutant == nil

                visitor.walk(source)
                droppedByVisitors += visitor.droppedMutants

                let schemataMapping = visitor.schemataMappings

                if !schemataMapping.isEmpty {
                    return newSchemataMappings + [schemataMapping]
                } else {
                    return newSchemataMappings
                }
            }

        // Pruning has to see every operator's mutants for the file at once: an outer mutant from
        // one operator conflicts with a nested one from another.
        func pruned(_ mappings: [SchemataMutationMapping]) -> DiscoveredFile {
            var merged = mappings.mergeByFilePath()
            var dropped = droppedByVisitors
            for index in merged.indices {
                dropped += merged[index].dropNestedSchemataInOpaqueBodies(of: source)
                    .map { DroppedMutant($0, path: path, reason: .nestedInAnOpaqueBody) }
            }
            return DiscoveredFile(mappings: merged.filter { !$0.isEmpty }, dropped: dropped)
        }
        let every = pruned(mappings)
        guard let namedMutant,
              let configuredOperators = namedMutant.configuredOperators,
              !namedMutant.isHeld(by: every.mappings, under: projectRoot)
        else { return every }
        let fewer = pruned(mappings.compactMap { mapping in
            var kept = mapping
            kept.keepOnly { configuredOperators.contains($0.mutationOperatorId) }
            return kept.isEmpty ? nil : kept
        })
        return namedMutant.isHeld(by: fewer.mappings, under: projectRoot) ? fewer : every
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

    func pathContainsDotSwift(_ filePath: String) -> Bool {
        let url = URL(fileURLWithPath: filePath)
        return url.lastPathComponent.contains(".swift")
    }
}

#if !canImport(ObjectiveC)
/// Without the Objective-C runtime nothing is autoreleased, so there is no pool to drain.
private func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

/// The mutant `--mutant` names, for a file whose mutants lack it. `--mutant` discovers every operator, but a mutant
/// nested in an opaque body is pruned when an operator it doesn't use mutates the body's own statements. So a run under
/// `operators` or `skipOperators` can test and report a mutant that every operator's discovery prunes. Only the keys'
/// operators keep it then, and as it alone gets tested, it conflicts with nothing.
struct NamedMutant: Sendable {
    let reference: MutantReference
    /// What the configuration's keys leave; nil when they say nothing, or leave no operators.
    let configuredOperators: MutationOperatorList?

    /// nil unless `--mutant` is given.
    init?(_ state: AnyMutationTestState) {
        guard let reference = state.runOptions.mutant else { return nil }
        self.reference = reference.relative(toFirstOf: [state.projectDirectoryURL, state.mutatedProjectDirectoryURL])
        configuredOperators = try? state.runOptions.operatorsFromTheKeys(of: state.muterConfiguration)
    }

    func isHeld(by mappings: [SchemataMutationMapping], under root: URL) -> Bool {
        MutantKey.keys(for: mappings.flatMap(\.mutationSchemata), under: root).contains(where: reference.matches)
    }
}
