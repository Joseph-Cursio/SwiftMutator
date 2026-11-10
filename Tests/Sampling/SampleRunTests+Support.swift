import Foundation
@testable import muterCore

extension SampleRunTests {
    func summary(
        outsideTheSample: Int,
        toTest: Int = 1,
        sampleIsPartial: Bool = false,
        selectionChange: String? = nil
    ) -> ResumeSummary {
        ResumeSummary(
            path: "/logs/results.jsonl",
            reused: 4,
            toTest: toTest,
            retestedBecause: toTest == 0 ? [:] : [.notRecorded: toTest],
            noLongerDiscovered: 0,
            outsideTheSample: outsideTheSample,
            sampleIsPartial: sampleIsPartial,
            discoveredBefore: 5,
            coverageChange: nil,
            forced: [],
            waived: [],
            notices: [],
            selectionChange: selectionChange
        )
    }

    /// The keys of the mutants discovery keeps with `sample` and `shard`, in job order; nil discovers every one.
    func keys(discovering sample: Sample?, shard: Shard? = nil) async throws -> [MutantKey] {
        state.runOptions = .make(shard: shard, sample: sample)
        let changes = try await DiscoverMutationPoints().run(with: state)
        let mappings = changes.compactMap { change -> [SchemataMutationMapping]? in
            guard case let .mutationMappingsDiscovered(mappings) = change else { return nil }
            return mappings
        }.first ?? []
        return MutantKey.keys(for: mappings.flatMap(\.mutationSchemata), under: state.mutatedProjectDirectoryURL)
    }

    func prepare() throws {
        let project = try makeTemporaryDirectory()
        let path = "\(project)/Check.swift"
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.sourceFileCandidates = [path]
    }
}
