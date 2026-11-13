/// The counts a `PropertyKillSummary` is made of, as its kills are added one at a time.
private struct PropertyKillTally {
    var examplesOnly = 0
    var propertiesOnly = 0
    var both = 0
    var namingNone = 0
    var examplesOnlyIncomplete = 0
    var propertiesOnlyIncomplete = 0
    var reruns = 0
    var rerunKills = 0
    var rerunPasses = 0
    var exampleReruns = 0
    var exampleRerunKills = 0
    var exampleRerunPasses = 0
    /// For each property test, how many kills it was recorded failing for, and how many of those only it was.
    var byProperty: [FailedTestLine.TestIdentity: (mutants: Int, only: Int)] = [:]

    /// Adds `mutation`, a kill, whose property tests are those `isProperty` picks out.
    mutating func add(_ mutation: MutationTestOutcome.Mutation, isProperty: (FailedTestLine.TestIdentity) -> Bool) {
        let tests = Set((mutation.killingTests?.tests ?? []).map(FailedTestLine.TestIdentity.init))
        guard !tests.isEmpty else {
            namingNone += 1
            return
        }
        let recorded = tests.filter(isProperty)
        let rerun = recorded.isEmpty ? mutation.propertyRerun : nil
        if let rerun {
            add(rerun)
        }
        // Only for a kill by properties alone, whose rerun says whether an example would have failed too.
        let exampleRerun = recorded.count == tests.count ? mutation.exampleRerun : nil
        let examplesFailed = exampleRerun?.examplesFailed(isProperty: isProperty) == true
        if let exampleRerun {
            exampleReruns += 1
            if examplesFailed { exampleRerunKills += 1 }
            if exampleRerun.outcome == .passed { exampleRerunPasses += 1 }
        }
        let properties = split(
            mutation,
            tests: tests,
            properties: recorded,
            reruns: (rerun, exampleRerun.map { ($0, examplesFailed) }),
            isProperty: isProperty
        )
        for property in properties {
            byProperty[property, default: (0, 0)].mutants += 1
            // The count, not the list: more may have failed than it holds. Never with a rerun's example failing.
            if rerun == nil, !examplesFailed, mutation.killingTests?.count == 1 {
                byProperty[property, default: (0, 0)].only += 1
            }
        }
    }

    /// Counts a run of the property tests alone with a kill's mutant on.
    private mutating func add(_ rerun: MutationTestOutcome.PropertyRerun) {
        reruns += 1
        if rerun.killed { rerunKills += 1 }
        if rerun.outcome == .passed { rerunPasses += 1 }
    }

    /// Counts `mutation`, whose recorded failed `tests` hold `properties`, as a kill only by examples, only by
    /// properties, or by both, given its `reruns`: the property rerun of a kill by examples alone, and the example
    /// rerun of one by properties alone with whether an example failed in it. Gives the properties that killed it.
    private mutating func split(
        _ mutation: MutationTestOutcome.Mutation,
        tests: Set<FailedTestLine.TestIdentity>,
        properties: Set<FailedTestLine.TestIdentity>,
        reruns: (MutationTestOutcome.PropertyRerun?, (MutationTestOutcome.ExampleRerun, Bool)?),
        isProperty: (FailedTestLine.TestIdentity) -> Bool
    ) -> Set<FailedTestLine.TestIdentity> {
        let (rerun, exampleRerun) = reruns
        let isComplete = mutation.killingTests?.isComplete == true
        switch (properties.isEmpty, properties.count == tests.count) {
        case (true, _) where rerun?.killed == true:
            both += 1
            // The properties the rerun saw failing killed it too, with the examples its own run recorded.
            return Set((rerun?.killingTests?.tests ?? []).map(FailedTestLine.TestIdentity.init))
                .filter(isProperty)

        case (true, _):
            examplesOnly += 1
            // Every property passed with it on, so no property was hidden, however the list was cut short.
            if !isComplete, rerun?.outcome != .passed { examplesOnlyIncomplete += 1 }

        case (false, true) where exampleRerun?.1 == true:
            // An example failed with the property tests skipped: it killed the mutant too.
            both += 1

        case (false, true):
            propertiesOnly += 1
            // Every other test passed with it on, so no example was hidden, however the list was cut short.
            if !isComplete, exampleRerun?.0.outcome != .passed { propertiesOnlyIncomplete += 1 }

        case (false, false):
            both += 1
        }
        return properties
    }
}

extension PropertyKillSummary {
    /// The split of `mutations`' kills by the property tests `globs` pick out: nil without globs.
    init?(of mutations: [MutationTestOutcome.Mutation], globs: [String]) {
        guard !globs.isEmpty else { return nil }
        let patterns = globs.map(PropertyTestPattern.init)
        let isProperty = { (test: FailedTestLine.TestIdentity) in patterns.contains { $0.matches(test) } }

        let killed = mutations.filter { $0.testSuiteOutcome == .failed || $0.testSuiteOutcome == .runtimeError }
        var tally = PropertyKillTally()
        for mutation in killed {
            tally.add(mutation, isProperty: isProperty)
        }
        // A total order, so every report lists the same properties the same way.
        let ranked = tally.byProperty
            .sorted { ($1.value.mutants, $0.key) < ($0.value.mutants, $1.key) }
            .map { identity, counts in
                Property(
                    name: identity.name, file: identity.file, mutants: counts.mutants, onlyRecordedKillerOf: counts.only
                )
            }

        self.init(
            globs: globs,
            scoredMutants: mutations.count { $0.testSuiteOutcome != .buildError },
            killedMutants: killed.count,
            killedOnlyByExamples: tally.examplesOnly,
            killedOnlyByProperties: tally.propertiesOnly,
            killedByBoth: tally.both,
            killedNamingNoTest: tally.namingNone,
            incompleteExampleOnlyKills: tally.examplesOnlyIncomplete,
            incompletePropertyOnlyKills: tally.propertiesOnlyIncomplete,
            propertyReruns: tally.reruns,
            propertyRerunKills: tally.rerunKills,
            propertyRerunPasses: tally.rerunPasses,
            exampleReruns: tally.exampleReruns,
            exampleRerunKills: tally.exampleRerunKills,
            exampleRerunPasses: tally.exampleRerunPasses,
            distinctProperties: ranked.count,
            properties: Array(ranked.prefix(Self.shownProperties))
        )
    }
}
