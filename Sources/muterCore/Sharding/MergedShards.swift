import ArgumentParser

/// The results files of a split's shards (`run --shard`), merged into the results of the whole run: one shard's file
/// alone too, a merge of one, so that a CI job's glob that finds one file is judged as one that finds two. Each shard
/// is checked against the one with the lowest index first, as a resume is checked against the run it continues, so
/// that the report holds only results a whole run would give: what a resume compares, but for the shard itself, and
/// the project's files, of which `--merge-ignoring` may let some through. A shard whose file isn't given, or whose run
/// didn't finish, is said, not refused, as a run still going is; but `report` then fails.
struct MergedShards {
    /// One shard's results file.
    struct Part {
        let path: String
        let recorded: RecordedResults
        /// Its last session's header, which `report` reads a single file by.
        let header: ResultsHeader
        let selection: ShardSelection

        var shard: Shard {
            selection.shard
        }
    }

    /// By index.
    let parts: [Part]
    /// The build and toolchain differences `--force-merge` let through, by their names in `provenance`.
    let forced: [String]
    /// The project files that differ between the shards, which `--merge-ignoring` let through, by their paths.
    let waived: [String]
    /// Every shard's results, by key.
    let latest: [MutantKey: MutantResult]

    /// The shard the others are checked against, whose header gives the report's project paths, coverage and update
    /// notice.
    var reference: Part {
        parts[0]
    }

    /// Whether every shard discovered the same mutants: then how many have no result is known exactly.
    var discoveriesAgree: Bool {
        parts.allSatisfy { $0.selection.allKeysSHA256 == reference.selection.allKeysSHA256 }
    }

    /// The indices of the shards whose files weren't given, with how many mutants each holds, as the reference shard's
    /// discovery split them.
    var absentShards: [(index: Int, mutants: Int)] {
        let given = Set(parts.map(\.shard.index))
        return (1...reference.shard.count).filter { !given.contains($0) }.map { index in
            (index, reference.selection.mutantsPerShard.indices.contains(index - 1)
                ? reference.selection.mutantsPerShard[index - 1]
                : 0)
        }
    }

    /// Whether the report is known to lack results, so `report` exits with `exitStatus` and doesn't check its score: a
    /// shard stopped on an error; or has fewer results than mutants, as one that was interrupted or killed, or is still
    /// running; or the file of a shard that holds mutants wasn't given, or holds only why its run stopped before its
    /// first mutant, as a shard's whose baseline failed does, which `ResultsReport` leaves out. So a CI job that checks
    /// the report fails as one that checked every shard's run would.
    /// Discoveries that differ only warn: each shard has its own mutants' results.
    var lacksResults: Bool {
        parts.contains { $0.recorded.stoppedOnAnError || $0.recorded.latest.count < $0.header.mutantsDiscovered }
            || absentShards.contains { $0.mutants > 0 }
    }

    /// The status `report` exits with when the report lacks results: that of the first shard, by its index, that
    /// stopped on an error, as its run exited (`RecordedResults.exitStatus`), else `abortedMidRun`, as the whole run
    /// didn't test every mutant. nil when it lacks none.
    var exitStatus: ExitCode? {
        guard lacksResults else { return nil }
        return parts.lazy.compactMap(\.recorded.exitStatus).first ?? .abortedMidRun
    }

    /// The shards the report covers, when it covers only some: those given, unless every shard that holds mutants is.
    var scope: ShardScope? {
        guard absentShards.contains(where: { $0.mutants > 0 }) else { return nil }
        return ShardScope(
            indices: parts.map(\.shard.index),
            count: reference.shard.count,
            mutantsInAllShards: reference.selection.mutantsInAllShards
        )
    }

    /// The outcome a whole run of the merged mutants would have reported: under the reference shard's project paths,
    /// coverage and update notice, and with the longest shard's test duration, as the shards are meant to run at once,
    /// and every shard's control runs; of the shards given, if some that hold mutants aren't.
    ///
    /// The results of a sample's shards are cut short when one of those given has some of its results, but not all:
    /// they are then its first files'. A shard with none, as one whose job was cancelled before its first mutant, or
    /// whose file isn't given, leaves the others a random part of the sample, as a shard's hash doesn't depend on the
    /// seed.
    ///
    /// A file that differs between the shards (`--merge-ignoring`) was tested as more than one version, so no
    /// report shows a mutant's line from it: the reference shard's hash says nothing of the others' mutants.
    func mutationTestOutcome() -> MutationTestOutcome {
        var outcome = MutationTestOutcome(
            records: latest.values,
            under: reference.header,
            testDuration: parts.map(\.recorded.testDuration).max() ?? 0,
            shards: scope,
            sampleIsCutShort: parts.contains { (1..<$0.header.mutantsDiscovered).contains($0.recorded.latest.count) },
            controlRuns: parts.flatMap(\.recorded.controlRuns),
            // A key is in one shard alone.
            propertyReruns: parts.reduce(into: [:]) { reruns, part in
                reruns.merge(part.recorded.propertyReruns) { _, later in later }
            },
            propertySurvivorReruns: parts.reduce(into: [:]) { reruns, part in
                reruns.merge(part.recorded.propertySurvivorReruns) { _, later in later }
            },
            exampleReruns: parts.reduce(into: [:]) { reruns, part in
                reruns.merge(part.recorded.exampleReruns) { _, later in later }
            }
        )
        outcome.run = RunDetails(of: parts.map { ($0.path, $0.recorded.headers) })
        outcome.uncoveredMutants = uncoveredMutants
        guard !waived.isEmpty else { return outcome }
        var digests = outcome.sourceDigests ?? [:]
        for path in waived {
            digests[path] = Self.differsBetweenShards
        }
        outcome.sourceDigests = digests
        return outcome
    }

    /// Each shard's suspect tests (`KillingTestSummary.suspectIdentities`), by the key of each mutant the shard has a
    /// result for: those its own results give, with its own control runs and thresholds, as its run judged them when it
    /// chose which kills to test again alone. A test that reaches enough files only across the shards is suspect in
    /// none of them, so no shard tested its kills again alone, and no run of one could: `--max-doubtful-kills` judges
    /// each kill by these, not by the merge's suspects, which the merged reports show.
    var suspectTestsByMutant: DoubtfulKillsCheck.SuspectsByMutant {
        var suspects: DoubtfulKillsCheck.SuspectsByMutant = [:]
        for part in parts {
            let outcome = part.recorded.mutationTestOutcome()
            let shardSuspects = KillingTestSummary(
                of: outcome.mutations,
                controlRuns: outcome.controlRuns,
                thresholds: outcome.suspectTestThresholds
            )?.suspectIdentities ?? []
            for key in part.recorded.latest.keys {
                suspects[key] = shardSuspects
            }
        }
        return suspects
    }

    /// The mutants of code no test ran of every shard given, as their last sessions' headers record them: their union,
    /// each once by its key, sorted by it. A shard records those it holds (`Shard.holds`), so each is in one shard's.
    /// nil when a shard's header doesn't record them, which isn't to say it has none
    /// (`ResultsHeader.mutantsNotCovered`).
    var uncoveredMutants: [UncoveredMutant]? {
        var seen: Set<MutantKey> = []
        var all: [UncoveredMutant] = []
        for part in parts {
            guard let recorded = part.header.knownMutantsNotCovered else { return nil }
            all += recorded.filter { seen.insert($0.key).inserted }
        }
        return all.sorted { $0.key.comesBefore($1.key) }
    }

    /// What stands for the hash of a file that differs between the shards: no file has it.
    static let differsBetweenShards = "differs between shards"

    /// How the merged run ended, for its summary: as a shard that was aborted did, else one that was interrupted, else
    /// as they all finished; nil when some shard's last session has no end line, or the file of a shard that holds
    /// mutants wasn't given, as how that shard's run ended is unknown.
    var ending: ResultsEnd? {
        guard !absentShards.contains(where: { $0.mutants > 0 }) else { return nil }
        let ends = parts.map { $0.recorded.sessions.last?.end }
        guard ends.allSatisfy({ $0 != nil }) else { return nil }
        let given = ends.compactMap(\.self)
        return given.first { $0.reason == .aborted } ?? given.first { $0.reason == .interrupted } ?? given.first
    }
}
