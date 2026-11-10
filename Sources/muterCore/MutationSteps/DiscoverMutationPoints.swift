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

        let found = await discoverMutationPoints(
            forOperators: state.mutationOperatorList,
            inFilesAt: state.sourceFileCandidates,
            // A run of one mutant compares no survivors, so it needs none of those coverage leaves out.
            uncoveredFiles: state.runOptions.mutant == nil ? state.uncoveredSourceFiles : [],
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
}

private extension DiscoverMutationPoints {
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

    /// How many files are parsed and walked at once, which bounds the syntax trees held in memory.
    static let maxConcurrency = 8

    /// Each file's mutation points, from a task group that keeps `maxConcurrency` files in flight, in no set order:
    /// `mergeByFilePath()` sorts them.
    ///
    /// The files in `uncoveredFiles`, which coverage leaves out as a whole, are read as they would be prepared, but not
    /// rewritten, and their mutants are all of `DiscoveredFile.uncovered`.
    func discoverMutationPoints(
        forOperators operators: MutationOperatorList,
        inFilesAt filePaths: [String],
        uncoveredFiles: [String] = [],
        configuration: MuterConfiguration,
        coverage: Coverage,
        projectRoot: URL,
        buildConditions: ProjectBuildConditions? = nil,
        namedMutant: NamedMutant? = nil
    ) async -> [DiscoveredFile] {
        var swiftFiles = (filePaths.filter(pathContainsDotSwift).map { (path: $0, isUncovered: false) }
            + uncoveredFiles.filter(pathContainsDotSwift).map { (path: $0, isUncovered: true) })
            .makeIterator()

        return await withTaskGroup(of: DiscoveredFile.self) { group in
            func discoverNext() {
                guard let (path, isUncovered) = swiftFiles.next() else { return }
                group.addTask {
                    // What reading the file autoreleased is freed once the file is done, not whenever the thread's
                    // pool drains.
                    autoreleasepool {
                        let prepare = isUncovered ? readPreparedSourceCode : prepareSourceCode
                        guard let sourceCode = prepare(path) else {
                            return DiscoveredFile(mappings: [], dropped: [])
                        }

                        return discoverNewSchemataMappings(
                            forOperators: operators,
                            inFile: sourceCode,
                            isUncovered: isUncovered,
                            configuration: configuration,
                            coverage: isUncovered ? .empty : coverage.coverage(ofFile: path),
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

    /// The mutants of `sourceCode`, a file the run mutates, unless `isUncovered`, as coverage leaves it out as a whole.
    /// Each visitor's mutants of code no test ran come back too, but for `--mutant`'s run, which compares no survivors.
    func discoverNewSchemataMappings(
        forOperators operators: MutationOperatorList,
        inFile sourceCode: PreparedSourceCode,
        isUncovered: Bool = false,
        configuration: MuterConfiguration,
        coverage: FileCoverage,
        projectRoot: URL,
        buildConditions: ProjectBuildConditions? = nil,
        namedMutant: NamedMutant? = nil
    ) -> DiscoveredFile {
        let source = sourceCode.source.code
        let path = RepoRelativePath.of(sourceCode.source.path, under: projectRoot)
        var droppedByVisitors: [DroppedMutant] = []
        var uncoveredByVisitors: [SchemataMutationMapping] = []
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
                visitor.isUncovered = isUncovered
                // RelationalOperatorReplacement's constants stand for these operators' mutants of a comparison.
                let leavesComparisonsAlone = operators.contains(.ror) && namedMutant == nil
                (visitor as? NegateConditionalOperator.Visitor)?.leavesComparisonsAlone = leavesComparisonsAlone
                (visitor as? ReplaceBooleanValueOperator.Visitor)?.leavesComparisonsAlone = leavesComparisonsAlone

                visitor.walk(source)
                droppedByVisitors += visitor.droppedMutants
                if !visitor.uncoveredMappings.isEmpty {
                    uncoveredByVisitors.append(visitor.uncoveredMappings)
                }

                let schemataMapping = visitor.schemataMappings

                if !schemataMapping.isEmpty {
                    return newSchemataMappings + [schemataMapping]
                }
                return newSchemataMappings
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
        guard !isUncovered else {
            // The run doesn't mutate the file: none of its mutants is made, nor said to be dropped.
            return DiscoveredFile(
                mappings: [],
                dropped: [],
                uncovered: Self.uncovered(uncoveredByVisitors, besides: [], of: source, under: projectRoot)
            )
        }
        var every = pruned(mappings)
        guard let namedMutant,
              let configuredOperators = namedMutant.configuredOperators,
              !namedMutant.isHeld(by: every.mappings, under: projectRoot)
        else {
            if namedMutant == nil {
                every.uncovered = Self.uncovered(uncoveredByVisitors, besides: mappings, of: source, under: projectRoot)
            }
            return every
        }
        let fewer = pruned(mappings.compactMap { mapping in
            var kept = mapping
            kept.keepOnly { configuredOperators.contains($0.mutationOperatorId) }
            return kept.isEmpty ? nil : kept
        })
        return namedMutant.isHeld(by: fewer.mappings, under: projectRoot) ? fewer : every
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
