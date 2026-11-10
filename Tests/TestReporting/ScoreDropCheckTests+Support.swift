import ArgumentParser
@testable import muterCore
import XCTest

extension ScoreDropCheckTests {
    /// Results judged that aren't the whole project's, the progress given with them, and why they aren't checked.
    struct UncheckedResults {
        let judged: MutationTestOutcome
        let progress: ScoreGate.Progress?
        let reason: ScoreDropCheck.NotChecked
        let why: String

        init(
            _ judged: MutationTestOutcome,
            _ progress: ScoreGate.Progress?,
            _ reason: ScoreDropCheck.NotChecked,
            _ why: String
        ) {
            self.judged = judged
            self.progress = progress
            self.reason = reason
            self.why = why
        }
    }

    /// Results of a part of the project, made from `tested`, with the reason they aren't checked.
    private func partsOfTheProject(_ tested: MutationTestOutcome) -> [UncheckedResults] {
        var filesToMutate = tested
        filesToMutate.filesToMutate = ["Sources/X.swift"]
        return [
            UncheckedResults(
                .make([.failed], mutant: "Sources/X.swift:1:1 RelationalBoundary"),
                nil,
                .oneMutant,
                "one mutant's score (--mutant) isn't the project's."
            ),
            UncheckedResults(
                .make([.failed], shards: ShardScope(.make(index: 1, count: 2, mutantsInAllShards: 2))),
                nil,
                .shard,
                "a shard's score isn't the whole run's. Compare the merged report instead: swift-mutator report "
                    + "--baseline muter.baseline.yml --max-score-drop 2 <each shard's results file>"
            ),
            UncheckedResults(
                MutationTestOutcome(
                    mutations: tested.mutations,
                    sample: SampleSelection(size: 2, seed: 9, mutantsSampledFrom: 40, mutantsSampled: 2)
                ),
                nil,
                .sample,
                "a sample's score (--sample) isn't the whole project's."
            ),
            UncheckedResults(
                MutationTestOutcome(mutations: tested.mutations, since: .make(changedLines: true)),
                nil,
                .since,
                "the score of the code --since chose isn't the whole project's."
            ),
            UncheckedResults(
                MutationTestOutcome(mutations: tested.mutations, since: .make()),
                nil,
                .since,
                "the score of the code --since chose isn't the whole project's."
            ),
            UncheckedResults(
                filesToMutate,
                nil,
                .filesToMutate,
                "the score of the files --files-to-mutate chose isn't the whole project's."
            ),
        ]
    }

    /// Each kind of results that isn't the whole project's, made from `tested`, with the reason it isn't checked.
    func uncheckedResults(_ tested: MutationTestOutcome) -> [UncheckedResults] {
        partsOfTheProject(tested) + [
            UncheckedResults(
                tested,
                ScoreGate.Progress(results: 2, discovered: 10),
                .unfinished,
                "only 2 of 10 mutants have results, as the run didn't finish."
            ),
            UncheckedResults(
                MutationTestOutcome(mutations: tested.mutations, sampleIsCutShort: true),
                nil,
                .unfinished,
                "the run didn't test every mutant it discovered."
            ),
            UncheckedResults(.make([.buildError]), nil, .nothingScored, "no mutant was scored."),
            UncheckedResults(.make([]), nil, .nothingScored, "no mutant was scored."),
        ]
    }

    func baseline(killed: Int, of scored: Int) -> BaselineFile {
        BaselineFile(
            path: "muter.baseline.yml",
            swiftMutator: "0.1.0",
            score: .init(killed: killed, scored: scored),
            scope: BaselineScope(operators: [], skipCoverage: false, configuration: .init()),
            survivors: []
        )
    }

    func check(
        _ killed: Int,
        of scored: Int,
        against recorded: (killed: Int, scored: Int),
        allowing limit: Double = 2
    ) -> ScoreDropCheck {
        ScoreDropCheck(
            baseline: baseline(killed: recorded.killed, of: recorded.scored),
            maxScoreDrop: limit,
            killed: killed,
            scored: scored
        )
    }

    /// An outcome that killed `killed` of `scored` mutants, each in a file of its own.
    func outcome(killed: Int, of scored: Int) -> MutationTestOutcome {
        .make(Array(repeating: .failed, count: killed) + Array(repeating: .passed, count: scored - killed))
    }
}
