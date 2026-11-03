import Foundation

/// The mutants under way, by worker, and when one last finished, for the line that says the run is still testing once
/// none has finished for `interval`: off a terminal nothing else prints between mutants, so a hung run would look the
/// same as a slow one. Runs start and finish on whichever threads test them, and the clock is read on another.
final class Heartbeat: @unchecked Sendable { // `workers`, `running` and `quietSince` are behind `lock`
    /// How long no mutant finishes before the line, and between lines while none does.
    static let interval: TimeInterval = 60

    private let lock = NSLock()
    /// How many workers test the mutants, which the line names only if there are more than one.
    private var workers = 1
    private var running: [Int: (place: String, since: DispatchTime)] = [:]
    /// When a mutant last finished, or the last line was due; at first, when the mutants started.
    private var quietSince = DispatchTime(uptimeNanoseconds: 0)

    /// The mutants start at `time`, on `workers` workers, none yet under way.
    func begin(workers: Int, at time: DispatchTime) {
        lock.withLock {
            self.workers = workers
            running = [:]
            quietSince = time
        }
    }

    /// `worker` started testing the mutant at `place`, "Rules.swift:42:17", at `time`.
    func started(_ place: String, on worker: Int, at time: DispatchTime) {
        lock.withLock { running[worker] = (place, time) }
    }

    /// `worker`'s mutant finished at `time`.
    func finished(on worker: Int, at time: DispatchTime) {
        lock.withLock {
            running[worker] = nil
            quietSince = time
        }
    }

    /// The seconds from `time` until the next line is due, if no mutant finishes meanwhile.
    func secondsUntilDue(at time: DispatchTime) -> TimeInterval {
        lock.withLock { max(Self.interval - Self.seconds(from: quietSince, to: time), 0) }
    }

    /// The mutants under way at `time`, by worker, if a line is due; the next is then due `interval` later. None if
    /// none is under way, as between one mutant's end and the next one's start.
    func due(at time: DispatchTime) -> StillTesting? {
        lock.withLock {
            guard Self.seconds(from: quietSince, to: time) >= Self.interval else { return nil }
            quietSince = time
            guard !running.isEmpty else { return nil }
            return StillTesting(
                runs: running.sorted { $0.key < $1.key }.map { worker, run in
                    StillTesting.Run(worker: worker, place: run.place, seconds: Self.seconds(from: run.since, to: time))
                },
                workers: workers
            )
        }
    }

    /// None if `end` is the earlier.
    private static func seconds(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
        guard end >= start else { return 0 }
        return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}

/// The mutants under way once none has finished for a while (`Heartbeat`).
struct StillTesting: Equatable, Sendable {
    struct Run: Equatable, Sendable {
        /// From 0.
        let worker: Int
        /// "Rules.swift:42:17".
        let place: String
        /// How long it has run.
        let seconds: TimeInterval
    }

    /// By worker.
    let runs: [Run]
    /// How many workers test the mutants.
    let workers: Int
}
