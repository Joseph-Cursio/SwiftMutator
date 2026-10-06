import Foundation

/// Which of a results file's results a resumed run keeps, and which of its jobs it tests. A recorded result is kept
/// for the job with its key only if that key's place and operator appear once in this run's discovery, it isn't a
/// build error, its file's hash is this run's, and its mutation is the job's. Every other job is tested, counted by
/// why. A mutant's `switchID` and `utf8Offset` are never compared: both count the header and import SwiftMutator
/// inserts, so they change with how it prepares the file, and an edit of the file changes its hash anyway.
struct ResumePlan: Equatable {
    /// Why a job is tested.
    enum Reason: String, CaseIterable {
        /// No result of its key is recorded, or a `retired` line retired it.
        case notRecorded
        /// Its result was a build error, as every run that couldn't start is: resuming is how to try it again.
        case buildError
        /// Its file's hash isn't the one its result recorded, or one of them is missing.
        case fileChanged
        /// Its file is the same, but the mutation SwiftMutator makes there isn't.
        case mutationChanged
        /// Its place and operator appear more than once in this run's discovery, so its repeats share a switch ID and
        /// no result of theirs can be trusted.
        case repeated
    }

    /// The results kept, by job index.
    let reused: [Int: MutantResult]
    /// The indices of the jobs to test, in job order.
    let toRun: [Int]
    /// How many of `toRun` are tested for each reason; a reason with none is absent.
    let retestedBecause: [Reason: Int]
    /// Every recorded key whose result isn't kept, sorted: those of the jobs tested again, and those of mutants this
    /// run's discovery no longer finds. A resumed session's `retired` line lists them.
    let retired: [MutantKey]
}

extension ResumePlan {
    /// The plan for the jobs whose keys are `keys` and whose mutations are `snapshots`, one each in job order, given
    /// the results file's `recorded` results (`RecordedResults.latest`) and the hashes of this run's project files by
    /// their paths relative to the project (`ProjectTree.files`), as keys' paths are.
    static func make(
        keys: [MutantKey],
        snapshots: [MutationOperator.Snapshot],
        recorded: [MutantKey: MutantResult],
        fileHashes: [String: String]
    ) -> ResumePlan {
        let places = Dictionary(keys.map { (Place($0), 1) }, uniquingKeysWith: +)
        var reused: [Int: MutantResult] = [:]
        var toRun: [Int] = []
        var reasons: [Reason: Int] = [:]
        for (index, key) in keys.enumerated() {
            let reason: Reason?
            if places[Place(key)] != 1 {
                reason = .repeated
            } else if let record = recorded[key] {
                reason = reasonToRetest(record, fileHash: fileHashes[key.path], snapshot: snapshots[index])
                if reason == nil {
                    reused[index] = record
                }
            } else {
                reason = .notRecorded
            }
            if let reason {
                toRun.append(index)
                reasons[reason, default: 0] += 1
            }
        }
        let kept = Set(reused.keys.map { keys[$0] })
        return ResumePlan(
            reused: reused,
            toRun: toRun,
            retestedBecause: reasons,
            retired: recorded.keys.filter { !kept.contains($0) }.sorted { $0.description < $1.description }
        )
    }

    /// Every job, as a run that isn't resumed tests them: nothing is reused, tested again or retired.
    static func everything(_ count: Int) -> ResumePlan {
        ResumePlan(reused: [:], toRun: Array(0..<count), retestedBecause: [:], retired: [])
    }

    /// Why `record`, recorded for a job whose key appears once, doesn't hold for it, given its file's hash and its
    /// mutation now; nil if it holds. A record without a hash never holds, even if this run can't hash its file
    /// either: nothing shows the file is the same.
    private static func reasonToRetest(
        _ record: MutantResult,
        fileHash: String?,
        snapshot: MutationOperator.Snapshot
    ) -> Reason? {
        if record.outcome == .buildError {
            return .buildError
        }
        if record.fileSHA256 == nil || record.fileSHA256 != fileHash {
            return .fileChanged
        }
        if record.snapshot != snapshot {
            return .mutationChanged
        }
        return nil
    }

    /// A key without its occurrence: where a mutant is, and which operator mutates it there.
    private struct Place: Hashable {
        let path: String
        let mutationOperatorId: MutationOperator.Id
        let line: Int
        let column: Int

        init(_ key: MutantKey) {
            path = key.path
            mutationOperatorId = key.mutationOperatorId
            line = key.line
            column = key.column
        }
    }
}
