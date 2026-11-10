@testable import muterCore
import XCTest

extension ProcessTreeTerminateTests {
    // MARK: - Helpers

    /// A signal `terminate` sent to a process.
    struct Sent: Equatable, CustomStringConvertible {
        let pid: Int32
        let signal: Int32

        init(_ pid: Int32, _ signal: Int32) {
            self.pid = pid
            self.signal = signal
        }

        var description: String {
            let name = [SIGSTOP: "STOP", SIGKILL: "KILL"][signal] ?? "\(signal)"
            return "(\(pid), \(name))"
        }
    }

    /// What a kill did: its signals, and its checks, pauses and SIGKILLs in order.
    struct KillRecord {
        var sent: [Sent] = []
        var steps: [String] = []
        var pauses: [useconds_t] = []
    }

    /// What stopping the descendants did: its signals, how many times it listed them, its steps in order, and the
    /// processes it stopped.
    struct StopToSuspendRun {
        let sent: [Sent]
        let listings: Int
        let steps: [String]
        let stopped: [Int32]
    }

    /// `ProcessTree.terminate` or `ProcessTree.terminateDescendants`.
    typealias Terminating = (
        _ root: Int32,
        _ descendants: (Int32) -> [Int32],
        _ check: ProcessTree.KillCheck,
        _ signal: (_ pid: Int32, _ signal: Int32) -> Void
    ) -> Void

    /// What `terminate` did. A process in `endsAtCheck` starts at 100, and reads as ended at that check after the first
    /// SIGKILL, or never at `.max`; any other had ended before the kill. `startTime`, if there is one, answers instead.
    func killing(
        root: Int32,
        listings: [[Int32]],
        endsAtCheck: [Int32: Int] = [:],
        startTime: ((Int32) -> UInt64?)? = nil
    ) -> KillRecord {
        recordKill(
            ProcessTree.terminate(root:descendants:checking:signal:),
            root: root,
            listings: listings,
            endsAtCheck: endsAtCheck,
            startTime: startTime
        )
    }

    /// `killing(root:…)` for `ProcessTree.terminateDescendants`.
    func killingDescendants(of root: Int32, listings: [[Int32]], endsAtCheck: [Int32: Int]) -> KillRecord {
        recordKill(
            ProcessTree.terminateDescendants(of:descendants:checking:signal:),
            root: root,
            listings: listings,
            endsAtCheck: endsAtCheck,
            startTime: nil
        )
    }

    func recordKill(
        _ terminating: Terminating,
        root: Int32,
        listings: [[Int32]],
        endsAtCheck: [Int32: Int],
        startTime: ((Int32) -> UInt64?)?
    ) -> KillRecord {
        var record = KillRecord()
        var listingCount = 0
        // The read before the first SIGKILL counts as check 0.
        var checksMade: [Int32: Int] = [:]
        let check = ProcessTree.KillCheck(
            startTime: { pid in
                record.steps.append("started \(pid)")
                if let startTime { return startTime(pid) }
                let made = checksMade[pid, default: -1] + 1
                checksMade[pid] = made
                guard let ending = endsAtCheck[pid] else { return nil }
                return made < ending ? 100 : nil
            },
            pause: { microseconds in
                record.steps.append("pause \(microseconds)")
                record.pauses.append(microseconds)
            }
        )
        let descendants = { (_: Int32) -> [Int32] in
            listingCount += 1
            return listings[min(listingCount, listings.count) - 1]
        }
        terminating(root, descendants, check) { pid, signal in
            record.sent.append(Sent(pid, signal))
            if signal == SIGKILL { record.steps.append(Sent(pid, signal).description) }
        }
        return record
    }

    /// Terminates `root`, whose descendants are listed as `listings`, one listing each time `terminate`
    /// asks, then the last one again. Returns the signals it sent and how many times it listed.
    func terminate(
        root: Int32,
        listings: [[Int32]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (sent: [Sent], listings: Int) {
        record(
            ProcessTree.terminate(root:descendants:checking:signal:),
            root: root,
            listings: listings,
            file: file,
            line: line
        )
    }

    /// `terminate(root:listings:)` for `ProcessTree.terminateDescendants`.
    func terminateDescendants(
        of root: Int32,
        listings: [[Int32]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (sent: [Sent], listings: Int) {
        record(
            ProcessTree.terminateDescendants(of:descendants:checking:signal:),
            root: root,
            listings: listings,
            file: file,
            line: line
        )
    }

    /// What a suspension's stop of root 1's descendants did, with them listed as `listings`, one listing each time it
    /// asks, then the last one again. A process in `stopsThatDontHold` shows as running for that many checks; every
    /// other shows as stopped.
    func stopToSuspend(
        listings: [[Int32]],
        stopsThatDontHold: [Int32: Int] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> StopToSuspendRun {
        var sent: [Sent] = []
        var listingCount = 0
        var steps: [String] = []
        var running = stopsThatDontHold
        let settling = ProcessTree.Settling(
            pause: { steps.append("pause") },
            isStoppedOrEnded: { pid in
                steps.append("check \(pid)")
                guard let checks = running[pid], checks > 0 else { return true }
                running[pid] = checks - 1
                return false
            }
        )
        let descendants = { (parent: Int32) -> [Int32] in
            XCTAssertEqual(parent, 1, "lists only the root's descendants", file: file, line: line)
            listingCount += 1
            steps.append("list")
            return listings[min(listingCount, listings.count) - 1]
        }
        let stopped = ProcessTree.stopDescendants(of: 1, descendants: descendants, settling: settling) { pid, signal in
            sent.append(Sent(pid, signal))
            steps.append(Sent(pid, signal).description)
        }
        return StopToSuspendRun(sent: sent, listings: listingCount, steps: steps, stopped: stopped)
    }

    func record(
        _ terminating: Terminating,
        root: Int32,
        listings: [[Int32]],
        file: StaticString,
        line: UInt
    ) -> (sent: [Sent], listings: Int) {
        var sent: [Sent] = []
        var listingCount = 0
        let descendants = { (parent: Int32) -> [Int32] in
            XCTAssertEqual(parent, root, "lists only the root's descendants", file: file, line: line)
            listingCount += 1
            return listings[min(listingCount, listings.count) - 1]
        }
        // Made-up IDs, each read as having ended, so that no check looks at a real process of that ID.
        let check = ProcessTree.KillCheck(
            startTime: { _ in nil },
            pause: { _ in XCTFail("paused", file: file, line: line) }
        )
        terminating(root, descendants, check) { pid, signal in sent.append(Sent(pid, signal)) }
        return (sent, listingCount)
    }
}
