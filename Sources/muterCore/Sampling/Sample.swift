#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// `--sample N --seed S`: of the mutants discovered, a sample of about `size` that the seed chooses, so a trend check,
/// such as a nightly score, needn't test every mutant. The same seed chooses the same mutants on every machine, and,
/// after a small change, mostly the same ones, which keeps a trend line steady.
struct Sample: Hashable, Sendable {
    let size: Int
    let seed: UInt64
    /// Whether SwiftMutator chose the seed, there being no `--seed`: the run says which, and the command that continues
    /// it gives it.
    let seedIsChosen: Bool

    /// The seed SwiftMutator chooses when there is no `--seed`: short enough to type again.
    static func chooseSeed() -> UInt64 {
        UInt64.random(in: 1...999_999)
    }

    /// Where the mutants at `key`'s place, whatever its occurrence, come in the order a sample takes places in: SHA-256
    /// over the seed and the place's path, operator, line and column, each followed by a NUL, its first 8 bytes read as
    /// a big-endian number. Not Swift's `hashValue`, which each process seeds afresh.
    static func rank(ofPlace key: MutantKey, seed: UInt64) -> UInt64 {
        let text = [String(seed), key.path, key.mutationOperatorId.rawValue, String(key.line), String(key.column)]
            .map { $0 + "\0" }
            .joined()
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}

/// What a session run with `--sample` records of it in the results file's header: the sample asked for, and how many
/// mutants it held of how many discovered. `mutantsDiscovered` and `mutantsToTest` count the sample's.
struct SampleSelection: Codable, Equatable, Sendable {
    /// `--sample`'s N.
    let size: Int
    let seed: UInt64
    /// How many mutants were discovered, after the excludes, the coverage filter and `--since`, before the sample.
    let mutantsSampledFrom: Int
    /// How many the sample holds: `size`, or a few more when the last place it took has repeats; every mutant when
    /// fewer were discovered.
    let mutantsSampled: Int

    /// Whether the sample left any mutant out. One that didn't is the whole run, which the reports say nothing of.
    var isPartial: Bool {
        mutantsSampled < mutantsSampledFrom
    }
}

extension [SchemataMutationMapping] {
    /// Of these mappings, every discovered mutant in the mutated project at `projectRoot`, only the ones `sample`
    /// holds; what it recorded of them; and the keys of the mutants it leaves out, which a resume or a reuse tells from
    /// mutants no longer discovered. A file left with none is left out.
    ///
    /// The places, a mutant's key without its occurrence (`MutantKey`), are ranked (`Sample.rank(ofPlace:seed:)`), ties
    /// broken by the place itself. The sample takes whole
    /// places in that order until it holds `size` mutants. Whole places, so that every repeat of one place and
    /// operator is in or out together: the sample's jobs then number their occurrences as a whole run's do
    /// (`MutantKey.keys`), and its keys are the whole run's.
    func keepingSample(
        _ sample: Sample,
        under projectRoot: URL
    ) -> (mappings: Self, selection: SampleSelection, leftOut: Set<MutantKey>) {
        let places = flatMap(\.mutationSchemata).map { Self.place(of: $0, under: projectRoot) }
        let mutantsAt = Dictionary(places.map { ($0, 1) }, uniquingKeysWith: +)
        let ranked = mutantsAt.keys
            .map { (place: $0, rank: Sample.rank(ofPlace: $0, seed: sample.seed)) }
            .sorted { ($0.rank, $0.place.description) < ($1.rank, $1.place.description) }
        var kept: Set<MutantKey> = []
        var mutantsSampled = 0
        for (place, _) in ranked where mutantsSampled < sample.size {
            kept.insert(place)
            mutantsSampled += mutantsAt[place, default: 0]
        }
        let mappings: Self = compactMap { mapping in
            var mapping = mapping
            mapping.keepOnly { kept.contains(Self.place(of: $0, under: projectRoot)) }
            return mapping.isEmpty ? nil : mapping
        }
        let selection = SampleSelection(
            size: sample.size,
            seed: sample.seed,
            mutantsSampledFrom: places.count,
            mutantsSampled: mutantsSampled
        )
        // Keyed over the whole discovery, as a whole run keys them.
        let leftOut = MutantKey.keys(for: flatMap(\.mutationSchemata), under: projectRoot).filter { key in
            !kept.contains(MutantKey(
                path: key.path,
                mutationOperatorId: key.mutationOperatorId,
                line: key.line,
                column: key.column,
                occurrence: 0
            ))
        }
        return (mappings, selection, Set(leftOut))
    }

    private static func place(of schema: MutationSchema, under projectRoot: URL) -> MutantKey {
        MutantKey(
            path: RepoRelativePath.of(schema.filePath, under: projectRoot),
            mutationOperatorId: schema.mutationOperatorId,
            line: schema.position.line,
            column: schema.position.column,
            occurrence: 0
        )
    }
}

/// A sample's report: how many mutants it tested of how many, and how far its score may be from a whole run's.
struct SampleScope: Codable, Equatable {
    let mutantsSampled: Int
    let mutantsSampledFrom: Int
    /// How many of the sample's mutants the report has a result for: fewer than `mutantsSampled` for a run stopped
    /// early, or for some shards of a sampled split.
    let mutantsTested: Int
    let seed: UInt64
    /// Half the width, in points, of the score's 95% confidence interval. nil, and left out of the JSON, when the
    /// results are cut short: a run stopped early has the first files' results, which are no random part of the sample.
    /// A shard's results are a random part of it, as its hash doesn't depend on the seed, so a shard's report, and a
    /// merge of some of the shards, have one.
    let marginOfError: Double?

    /// `selection`'s sample, of which a report has `tested` results; those that counted toward the score (all but build
    /// errors) number `scored`, and `killed` of them were killed. The results are `cutShort` when a run, or a shard's,
    /// stopped before every mutant it set out to test had one. nil when the sample held every mutant.
    init?(_ selection: SampleSelection?, killed: Int, scored: Int, tested: Int, cutShort: Bool) {
        guard let selection, selection.isPartial else { return nil }
        mutantsSampled = selection.mutantsSampled
        mutantsSampledFrom = selection.mutantsSampledFrom
        mutantsTested = tested
        seed = selection.seed
        marginOfError = cutShort ? nil : Self.marginOfError(
            killed: killed,
            scored: scored,
            sampled: tested,
            from: selection.mutantsSampledFrom
        )
    }

    init(mutantsSampled: Int, mutantsSampledFrom: Int, mutantsTested: Int, seed: UInt64, marginOfError: Double?) {
        self.mutantsSampled = mutantsSampled
        self.mutantsSampledFrom = mutantsSampledFrom
        self.mutantsTested = mutantsTested
        self.seed = seed
        self.marginOfError = marginOfError
    }

    /// The 95% margin, in points, of a score of `killed` in `scored`, for a sample of `sampled` mutants drawn from
    /// `from`: the Agresti–Coull interval, which adds 2 kills and 2 survivors so a sample that killed all or none still
    /// has a margin, narrowed by the finite-population correction, as the sample is drawn without replacement.
    static func marginOfError(killed: Int, scored: Int, sampled: Int, from population: Int) -> Double {
        guard population > 1, sampled < population else { return 0 }
        let trials = Double(scored) + 4
        let proportion = (Double(killed) + 2) / trials
        let correction = Double(population - sampled) / Double(population - 1)
        return 1.96 * (proportion * (1 - proportion) / trials * correction).squareRoot() * 100
    }

    /// "3.4": the margin, to one decimal. nil when there is none.
    var margin: String? {
        marginOfError.map { String(format: "%.1f", $0) }
    }

    /// "Only a sample of 500 of the 2463 mutants discovered was tested (seed 1234): a whole run's score is within 3.4
    /// points of this one, at 95% confidence." Without a margin, how many of the sample have a result instead.
    var sentence: String {
        let tested = "Only a sample of \(mutantsSampled) of the \(mutantsSampledFrom) mutants discovered was tested "
            + "(seed \(seed))"
        guard let margin else {
            return tested + ", and \(mutantsTested) of them have a result, so no margin is given: the others have none "
                + "yet, so these are the first ones tested, not a random part of the sample."
        }
        // A shard's results, or some shards', are a random part of the sample too.
        let part = mutantsTested < mutantsSampled ? ", and the margin is from the \(mutantsTested) of them here" : ""
        return tested + part + ": a whole run's score is within \(margin) points of this one, at 95% confidence."
    }
}
