import Foundation

extension ResumeCheck.Current {
    /// What `state` would record in its header: the configuration as loaded, and the mutants asked for.
    init(state: AnyMutationTestState, provenance: Provenance) {
        self.init(
            configuration: state.muterConfiguration,
            operators: state.mutationOperatorList.map(\.rawValue).sorted(),
            filesToMutate: state.filesToMutate,
            skipCoverage: state.runOptions.skipCoverage,
            usingTestPlan: state.runOptions.isUsingTestPlan,
            provenance: provenance,
            testPlanSHA256: state.testPlan?.sha256,
            since: state.changeSelection,
            shard: state.runOptions.shard,
            sample: state.runOptions.sample,
            mutant: state.selectedMutant?.description
        )
    }

    /// What `header`'s session recorded, of what a resume compares: the shard the others are merged with.
    init(header: ResultsHeader) {
        self.init(
            configuration: header.configuration,
            operators: header.operators,
            filesToMutate: header.filesToMutate,
            skipCoverage: header.skipCoverage,
            usingTestPlan: header.usingTestPlan,
            provenance: header.provenance,
            testPlanSHA256: header.testPlan?.sha256,
            since: header.since,
            shard: header.shard?.shard,
            sample: header.sample.map { Sample(size: $0.size, seed: $0.seed, seedIsChosen: false) },
            mutant: header.mutant
        )
    }
}
