import Foundation

/// One reason a set of results files can't be merged, and what would let it be.
enum MergeRefusal: Equatable, CustomStringConvertible {
    /// A results file, and the shard its last session tested.
    struct ShardFile: Equatable {
        let path: String
        let shard: Shard
    }

    /// The file's last session didn't test a shard.
    case notAShard(path: String)
    /// The file's last session tested a shard whose counts don't hold together, as a header edited by hand may not.
    case inconsistentShard(path: String)
    /// The files are shards of splits into different numbers of shards.
    case otherSplits([ShardFile])
    /// Several files are of one shard.
    case givenTwice(Shard, paths: [String])
    /// What a resume compares differs between a shard and the reference shard, the one with the lowest index.
    case differs(Shard, from: Shard, ResumeRefusal)
    /// Project files that differ between a shard and the reference shard, and that no `--merge-ignoring` glob matches.
    case filesDiffer(Shard, from: Shard, [ProjectTree.FileChange])
    /// A shard discovered the same mutants as the reference shard, but split them differently, as a SwiftMutator
    /// that splits by another rule would.
    case splitDifferently(Shard, from: Shard)
    /// Mutants with a result in more than one file, sorted.
    case testedTwice([MutantKey])

    /// How many mutants tested twice are named; the rest are counted.
    static let mutantsNamed = 10

    var description: String {
        switch self {
        case let .notAShard(path):
            return "\(Logger.shellQuoted(path)) isn't the results file of a shard (run --shard), so it can't be "
                + "merged with others."

        case let .inconsistentShard(path):
            return "\(Logger.shellQuoted(path)) records a shard whose counts don't hold together, as a header edited "
                + "by hand might, so nothing shows what the shard holds."

        case let .otherSplits(files):
            let shards = files.map { "\(Logger.shellQuoted($0.path)) is \(Self.named($0.shard))" }
            return "The files are shards of different splits: \(Logger.listed(shards))."

        case let .givenTwice(shard, paths):
            let files = Set(paths).count == 1
                ? "is given \(paths.count) times: \(Logger.shellQuoted(paths[0]))"
                : "is given more than once: \(Logger.listed(paths.map(Logger.shellQuoted)))"
            return "The results file of \(Self.named(shard)) \(files)."

        case let .differs(shard, reference, refusal):
            return Self.describe(refusal, in: shard, from: reference)

        case let .filesDiffer(shard, reference, changes):
            return Self.describe(changes, in: shard, from: reference)

        case let .splitDifferently(shard, reference):
            return "\(Self.named(shard).capitalizedFirst) discovered the same mutants as \(Self.named(reference)), "
                + "but split them differently, as a SwiftMutator that splits by another rule would. Run every shard "
                + "with one SwiftMutator build."

        case let .testedTwice(keys):
            let named = keys.prefix(Self.mutantsNamed).map(\.description)
            let others = keys.count - named.count
            let mutants = keys.count == 1 ? "1 mutant has a result" : "\(keys.count) mutants have a result"
            return "\(mutants) in more than one file: " + named.joined(separator: ", ")
                + (others > 0 ? ", and \(others) more" : "") + "."
        }
    }

    /// "shard 2 of 3".
    private static func named(_ shard: Shard) -> String {
        "shard \(shard.index) of \(shard.count)"
    }

    /// What a resume would refuse, said of `shard` and the `reference` shard it was compared with.
    private static func describe(_ refusal: ResumeRefusal, in shard: Shard, from reference: Shard) -> String {
        func values(_ difference: ResumeCheck.Difference, absent: String) -> String {
            "is \(difference.was ?? absent) in \(named(shard)), and \(difference.isNow ?? absent) in "
                + named(reference)
        }
        switch refusal {
        case let .configurationChanged(difference), let .timeLimitUnknown(difference):
            return "\(difference.name) \(values(difference, absent: "not set")). The shards must test with one "
                + "configuration."

        case let .selectionChanged(difference):
            return "\(difference.name) \(values(difference, absent: "not set")), so the shards chose their mutants "
                + "differently."

        case let .needsForce(difference):
            let subject = "\(ResumeCheck.subject(of: difference.name)) (\(difference.name))"
            let change = difference.was == nil && difference.isNow == nil
                ? "is unknown in both, so it may differ"
                : values(difference, absent: "unknown")
            return "\(subject) \(change). --force-merge merges them anyway."

        case .noProjectTree:
            return "\(named(shard).capitalizedFirst)'s file recorded no project files, so nothing shows that the "
                + "shards tested the same project."

        case .testPlanRun, .testPlanChanged, .testPlanNotRecorded:
            return "A run that tests a test plan has no shards to merge."

        case .inUse, .filesChanged, .copyChanged, .reportWouldReplaceTheResultsFile,
             .otherReportWouldReplaceTheResultsFile, .baselineFileWouldReplaceTheResultsFile, .stoppedBeforeFirstMutant:
            return refusal.description
        }
    }

    /// The project files that differ between `shard` and `reference`, up to `ResumeRefusal.changedFilesNamed` of them
    /// by name, and the flags that would let those through, ready to paste.
    private static func describe(
        _ changes: [ProjectTree.FileChange],
        in shard: Shard,
        from reference: Shard
    ) -> String {
        let named = changes.prefix(ResumeRefusal.changedFilesNamed)
        let others = changes.count - named.count
        let one = changes.count == 1
        let listed = named
            .map { change in
                switch change.kind {
                case .changed:
                    return "\(change.path) (differs)"

                case .added:
                    return "\(change.path) (only in \(Self.named(shard)))"

                case .removed:
                    return "\(change.path) (only in \(Self.named(reference)))"
                }
            }
            .joined(separator: ", ")
        let files = listed + (others > 0 ? ", and \(others) more" : "")
        let globs = named
            .map { "--merge-ignoring " + Logger.shellQuoted(ResumeRefusal.glob(matching: $0.path)) }
            .joined(separator: " ")
        let flags = globs + (others > 0 ? ", plus globs for the other \(others)" : "")
        return [
            "\(changes.count) project file\(one ? "" : "s") \(one ? "differs" : "differ") between "
                + "\(Self.named(reference)) and \(Self.named(shard)): \(files).",
            "If \(one ? "it" : "they") can't change any test's result: \(flags)",
        ].joined(separator: "\n")
    }
}

/// Why `report` won't merge the results files it was given: every reason it found, in one message.
struct MergeRefused: Error, Equatable, CustomStringConvertible {
    let reasons: [MergeRefusal]

    var description: String {
        var lines = [
            "SwiftMutator won't merge these results files, so that the report holds only results a whole run would "
                + "give:",
        ]
        for reason in reasons {
            let reasonLines = reason.description.components(separatedBy: "\n")
            lines.append("  - " + (reasonLines.first ?? ""))
            lines += reasonLines.dropFirst().map { "    " + $0 }
        }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
