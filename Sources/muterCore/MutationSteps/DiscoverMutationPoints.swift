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

        let discovered = await discoverMutationPoints(
            forOperators: state.mutationOperatorList,
            inFilesAt: state.sourceFileCandidates,
            configuration: state.muterConfiguration,
            coverage: state.projectCoverage,
            projectRoot: state.mutatedProjectDirectoryURL
        )

        guard discovered.count >= 1 else {
            throw MuterError.noMutationPointsDiscovered
        }

        let mappings = discovered.mergeByFilePath()

        events.send(.mutationsDiscoveryFinished(mappings))

        return [
            .mutationMappingsDiscovered(mappings),
            // Pass empty dictionary - ApplySchemata will re-parse files on demand
            // This prevents memory exhaustion on large codebases (2000+ files)
            .sourceCodeParsed([:]),
        ]
    }
}

private extension DiscoverMutationPoints {
    /// How many files are parsed and walked at once, which bounds the syntax trees held in memory.
    static let maxConcurrency = 8

    /// Each file's mutation points, from a task group that keeps `maxConcurrency` files in flight, in no set order:
    /// `mergeByFilePath()` sorts them.
    func discoverMutationPoints(
        forOperators operators: MutationOperatorList,
        inFilesAt filePaths: [String],
        configuration: MuterConfiguration,
        coverage: Coverage,
        projectRoot: URL
    ) async -> [SchemataMutationMapping] {
        var swiftFiles = filePaths.filter(pathContainsDotSwift).makeIterator()

        return await withTaskGroup(of: [SchemataMutationMapping].self) { group in
            func discoverNext() {
                guard let path = swiftFiles.next() else { return }
                group.addTask {
                    // What reading the file autoreleased is freed once the file is done, not whenever the thread's
                    // pool drains.
                    autoreleasepool {
                        guard let sourceCode = prepareSourceCode(path) else {
                            return []
                        }

                        return discoverNewSchemataMappings(
                            forOperators: operators,
                            inFile: sourceCode,
                            configuration: configuration,
                            coverage: coverage.coverage(ofFile: path),
                            projectRoot: projectRoot
                        )
                    }
                }
            }

            for _ in 0..<Self.maxConcurrency {
                discoverNext()
            }
            var discovered: [SchemataMutationMapping] = []
            while let mappings = await group.next() {
                discovered += mappings
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
        projectRoot: URL
    ) -> [SchemataMutationMapping] {
        let source = sourceCode.source.code

        let mappings: [SchemataMutationMapping] = operators.accumulate(into: []) { newSchemataMappings, mutationOperatorId in
            let visitor = mutationOperatorId.visitor(
                configuration,
                sourceCode.source,
                coverage
            )

            visitor.sourceCodePreparationChange = sourceCode.changes
            visitor.projectRoot = projectRoot

            visitor.walk(source)

            let schemataMapping = visitor.schemataMappings

            if !schemataMapping.isEmpty {
                return newSchemataMappings + [schemataMapping]
            } else {
                return newSchemataMappings
            }
        }

        // Pruning has to see every operator's mutants for the file at once: an outer mutant from
        // one operator conflicts with a nested one from another.
        let merged = mappings.mergeByFilePath()
        merged.forEach { $0.dropNestedSchemataInOpaqueBodies(of: source) }
        return merged.filter { !$0.isEmpty }
    }

    func pathContainsDotSwift(_ filePath: String) -> Bool {
        let url = URL(fileURLWithPath: filePath)
        return url.lastPathComponent.contains(".swift")
    }
}
