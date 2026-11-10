import Foundation

extension ResumeSummary {
    /// The summary of `plan`, made for the resume of `resume`, which let the changed files `waived` through, by a run
    /// that gathered `coverage` in the project copy at `mutatedProject`. A reuse passes what changed (`changes`). A
    /// resume of a test plan's run is one of a run of the same plan, which compares its copy.
    init(
        _ resume: ResumeState,
        _ plan: ResumePlan,
        waived: [String],
        coverage: Coverage,
        in mutatedProject: URL,
        reusing changes: [Int: ReuseChanges]? = nil,
        selecting current: Selection = Selection(),
        sampleIsPartial: Bool = false
    ) {
        let all = changes.map { Array($0.values) } ?? []
        let otherFiles = Dictionary(
            all.flatMap(\.otherFiles).map { ($0.path, $0) }
        ) { _, last in last }
        let testFiles = Set(all.flatMap(\.testFiles).map(\.path))
        self.init(
            path: resume.path,
            isReuse: resume.isReuse,
            reused: plan.reused.count,
            toTest: plan.toRun.count,
            retestedBecause: plan.retestedBecause,
            noLongerDiscovered: plan.noLongerDiscovered,
            outsideTheSample: plan.outsideTheSample,
            sampleIsPartial: sampleIsPartial,
            sampleChanged: resume.isReuse && Self.sampleChange(
                from: resume.lastHeader.sample.map { Sample(size: $0.size, seed: $0.seed, seedIsChosen: false) },
                to: current.sample
            ) != nil,
            discoveredBefore: resume.lastHeader.mutantsDiscovered,
            coverageChange: ResumeCheck.coverageChange(
                from: resume.lastHeader.coverage,
                in: URL(fileURLWithPath: resume.lastHeader.mutatedProjectPath, isDirectory: true),
                to: CoverageSummary(coverage),
                in: mutatedProject
            ),
            forced: resume.forced,
            waived: waived,
            testPlanCopy: resume.lastHeader.usingTestPlan ? mutatedProject.path : nil,
            notices: resume.notices,
            otherFilesChanged: otherFiles.values.sorted { $0.path < $1.path },
            testFilesChanged: testFiles.count,
            selectionChange: resume.isReuse
                ? Self.selectionChange(
                    from: Selection(
                        since: resume.lastHeader.since,
                        shard: resume.lastHeader.shard?.shard,
                        sample: resume.lastHeader.sample.map {
                            Sample(size: $0.size, seed: $0.seed, seedIsChosen: false)
                        }
                    ),
                    to: current
                )
                : nil
        )
    }

    /// Why a reuse whose `--since` choice, shard and sample are `current` discovers other mutants than the earlier run,
    /// whose were `earlier`: a sentence for each that differs, or nil when none does.
    static func selectionChange(
        from earlier: Selection,
        to current: Selection
    ) -> String? {
        let sentences = [
            selectionChange(from: earlier.since, to: current.since),
            shardChange(from: earlier.shard, to: current.shard),
            sampleChange(from: earlier.sample, to: current.sample),
        ].compactMap(\.self)
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// Why a reuse that tests the shard `current` discovers other mutants than the earlier run, which tested `earlier`;
    /// nil when the two tested the same shard, or neither tested one.
    static func shardChange(from earlier: Shard?, to current: Shard?) -> String? {
        switch (earlier, current) {
        case (nil, nil):
            return nil

        case let (earlier?, current?) where earlier == current:
            return nil

        case let (nil, current?):
            return "This run tests only shard \(current.index) of \(current.count), "
                + "so no earlier result of another shard's mutant is reused."

        case let (earlier?, nil):
            return "That run tested only shard \(earlier.index) of \(earlier.count), "
                + "so this run's other mutants have no earlier result."

        case let (earlier?, current?) where !earlier.overlaps(current):
            return "That run tested shard \(earlier.index) of \(earlier.count), and this one tests shard "
                + "\(current.index) of \(current.count), which share no mutant, so no earlier result is reused."

        case let (earlier?, current?):
            return "That run tested shard \(earlier.index) of \(earlier.count), and this one tests shard "
                + "\(current.index) of \(current.count), so only the mutants in both have an earlier result."
        }
    }

    /// Why a reuse that tests the sample `current` discovers other mutants than the earlier run, which tested
    /// `earlier`; nil when the two took the same sample, by its size and seed, or neither took one.
    static func sampleChange(from earlier: Sample?, to current: Sample?) -> String? {
        func named(_ sample: Sample) -> String {
            "a sample of \(sample.size) (seed \(sample.seed))"
        }
        switch (earlier, current) {
        case (nil, nil):
            return nil

        case let (earlier?, current?) where (earlier.size, earlier.seed) == (current.size, current.seed):
            return nil

        case let (nil, current?):
            return "This run tests only \(named(current)), so no earlier result of a mutant outside it is reused."

        case let (earlier?, nil):
            return "That run tested only \(named(earlier)), so this run's other mutants have no earlier result."

        case let (earlier?, current?):
            return "That run tested \(named(earlier)), and this one tests \(named(current)), "
                + "so only the mutants in both have an earlier result."
        }
    }

    /// Why a reuse whose `--since` choice is `current` discovers other mutants than the earlier run, whose choice was
    /// `earlier`; nil when the two chose the same, or neither chose.
    static func selectionChange(from earlier: ChangeSelection?, to current: ChangeSelection?) -> String? {
        func same(_ one: ChangeSelection, _ other: ChangeSelection) -> Bool {
            one.mergeBase == other.mergeBase && one.changedLines == other.changedLines
                && one.files.map(\.path) == other.files.map(\.path)
        }
        switch (earlier, current) {
        case (nil, nil):
            return nil

        case let (earlier?, current?) where same(earlier, current):
            return nil

        case let (_, current?):
            return "This run mutates only what changed since the merge base of \(current.ref) and HEAD "
                + "(\(current.shortMergeBase)), so no earlier result of another mutant is reused."

        case let (earlier?, nil):
            return "That run mutated only what changed since the merge base of \(earlier.ref) and HEAD "
                + "(\(earlier.shortMergeBase)), so this run's other mutants have no earlier result."
        }
    }
}
