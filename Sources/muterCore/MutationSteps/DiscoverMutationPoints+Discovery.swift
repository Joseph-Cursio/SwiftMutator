import Foundation
import SwiftSyntax

/// How each file's mutants are found: parsed and walked by every operator's visitor, a few files at once.
extension DiscoverMutationPoints {
    /// What discovery looks for in every file: the mutants of `operators`, as `configuration` has them, keyed under
    /// `projectRoot`, outside the code `buildConditions` leaves out of the build, and, for `--mutant`'s run,
    /// `namedMutant`.
    struct Scope: Sendable {
        let operators: MutationOperatorList
        let configuration: MuterConfiguration
        let projectRoot: URL
        var buildConditions: ProjectBuildConditions?
        var namedMutant: NamedMutant?
    }

    /// What every operator's visitor found in a file: its mutants, by operator, those it had to drop, and those of
    /// code no test ran.
    struct VisitorFindings {
        var mappings: [SchemataMutationMapping] = []
        var dropped: [DroppedMutant] = []
        var uncovered: [SchemataMutationMapping] = []
    }

    /// How many files are parsed and walked at once, which bounds the syntax trees held in memory.
    static let maxConcurrency = 8

    /// Each file's mutation points in `scope`, from a task group that keeps `maxConcurrency` files in flight, in no
    /// set order: `mergeByFilePath()` sorts them.
    ///
    /// The files in `uncoveredFiles`, which coverage leaves out as a whole, are read as they would be prepared, but not
    /// rewritten, and their mutants are all of `DiscoveredFile.uncovered`.
    func discoverMutationPoints(
        in scope: Scope,
        inFilesAt filePaths: [String],
        coverage: Coverage,
        uncoveredFiles: [String] = []
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
                            in: scope,
                            inFile: sourceCode,
                            coverage: isUncovered ? .empty : coverage.coverage(ofFile: path),
                            isUncovered: isUncovered
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

    /// The mutants of `sourceCode` in `scope`, a file the run mutates, unless `isUncovered`, as coverage leaves it out
    /// as a whole. Each visitor's mutants of code no test ran come back too, but for `--mutant`'s run, which compares
    /// no survivors.
    func discoverNewSchemataMappings(
        in scope: Scope,
        inFile sourceCode: PreparedSourceCode,
        coverage: FileCoverage,
        isUncovered: Bool = false
    ) -> DiscoveredFile {
        let source = sourceCode.source.code
        let path = RepoRelativePath.of(sourceCode.source.path, under: scope.projectRoot)
        let found = Self.findings(of: sourceCode, in: scope, coverage: coverage, isUncovered: isUncovered)
        let (mappings, projectRoot, namedMutant) = (found.mappings, scope.projectRoot, scope.namedMutant)

        // Pruning has to see every operator's mutants for the file at once: an outer mutant from
        // one operator conflicts with a nested one from another.
        func pruned(_ mappings: [SchemataMutationMapping]) -> DiscoveredFile {
            var merged = mappings.mergeByFilePath()
            var dropped = found.dropped
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
                uncovered: Self.uncovered(found.uncovered, besides: [], of: source, under: projectRoot)
            )
        }
        var every = pruned(mappings)
        guard let namedMutant,
              let configuredOperators = namedMutant.configuredOperators,
              !namedMutant.isHeld(by: every.mappings, under: projectRoot)
        else {
            if namedMutant == nil {
                every.uncovered = Self.uncovered(found.uncovered, besides: mappings, of: source, under: projectRoot)
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

    /// What each of `scope`'s operators' visitors finds in `sourceCode`, walked with the file's `coverage`, as a file
    /// coverage leaves out as a whole if `isUncovered`.
    static func findings(
        of sourceCode: PreparedSourceCode,
        in scope: Scope,
        coverage: FileCoverage,
        isUncovered: Bool
    ) -> VisitorFindings {
        let source = sourceCode.source.code
        let path = RepoRelativePath.of(sourceCode.source.path, under: scope.projectRoot)
        // Worked out once, for all the operators: the walk evaluates each `#if` in the file.
        let inactiveRegions = scope.buildConditions?.conditions(ofFile: path).inactiveRegions(in: source) ?? []
        // RelationalOperatorReplacement's constants stand for these operators' mutants of a comparison.
        let leavesComparisonsAlone = scope.operators.contains(.ror) && scope.namedMutant == nil

        var found = VisitorFindings()
        for mutationOperatorId in scope.operators {
            let visitor = mutationOperatorId.visitor(
                scope.configuration,
                sourceCode.source,
                coverage
            )

            visitor.sourceCodePreparationChange = sourceCode.changes
            visitor.projectRoot = scope.projectRoot
            visitor.inactiveRegions = inactiveRegions
            visitor.isUncovered = isUncovered
            (visitor as? NegateConditionalOperator.Visitor)?.leavesComparisonsAlone = leavesComparisonsAlone
            (visitor as? ReplaceBooleanValueOperator.Visitor)?.leavesComparisonsAlone = leavesComparisonsAlone

            visitor.walk(source)
            found.dropped += visitor.droppedMutants
            if !visitor.uncoveredMappings.isEmpty {
                found.uncovered.append(visitor.uncoveredMappings)
            }

            let schemataMapping = visitor.schemataMappings
            if !schemataMapping.isEmpty {
                found.mappings.append(schemataMapping)
            }
        }
        return found
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
