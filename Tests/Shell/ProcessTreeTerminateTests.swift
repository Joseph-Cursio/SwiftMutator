@testable import muterCore
import XCTest

/// `ProcessTree.terminate` and `terminateDescendants` with made-up listings, and the stop a suspension makes, with
/// made-up states too. They record the signals they would send instead of sending them; `ProcessTreeTests` kills a real
/// tree.
final class ProcessTreeTerminateTests: XCTestCase {
    func test_terminate_stopsTheWholeTreeTopDownBeforeKillingIt() {
        let run = terminate(root: 1, listings: [[2, 3], [2, 3]])

        XCTAssertEqual(run.sent, [
            Sent(1, SIGSTOP), Sent(2, SIGSTOP), Sent(3, SIGSTOP),
            Sent(2, SIGKILL), Sent(3, SIGKILL), Sent(1, SIGKILL),
        ])
        XCTAssertEqual(run.listings, 2)
    }

    // Stopping a process stops it starting others, but a child can start one between the listing and its
    // own stop. The next listing finds it.
    func test_terminate_stopsAChildStartedWhileTheTreeWasBeingStopped() {
        let run = terminate(root: 1, listings: [[2], [2, 4], [2, 4]])

        XCTAssertEqual(run.sent, [
            Sent(1, SIGSTOP), Sent(2, SIGSTOP), Sent(4, SIGSTOP),
            Sent(2, SIGKILL), Sent(4, SIGKILL), Sent(1, SIGKILL),
        ])
        XCTAssertEqual(run.listings, 3)
    }

    func test_terminate_listsAtMostTenTimes() {
        // Each listing finds one process the listing before it didn't.
        let listings = (1...20).map { Array(Int32(2)...Int32($0 + 1)) }

        let run = terminate(root: 1, listings: listings)

        XCTAssertEqual(ProcessTree.maximumListings, 10)
        XCTAssertEqual(run.listings, 10)
        let everyListed = Array(Int32(2)...Int32(11))
        XCTAssertEqual(run.sent, [Sent(1, SIGSTOP)] + everyListed.map { Sent($0, SIGSTOP) }
            + everyListed.map { Sent($0, SIGKILL) } + [Sent(1, SIGKILL)])
    }

    // A process that never launched has the ID 0. kill(0, …) would signal SwiftMutator's own process
    // group, and kill(-1, …) every process it may signal.
    func test_terminate_doesNothingForAProcessThatNeverLaunched() {
        for root: Int32 in [0, -1] {
            let run = terminate(root: root, listings: [[2]])

            XCTAssertEqual(run.sent, [], "root \(root)")
            XCTAssertEqual(run.listings, 0, "root \(root)")
        }
    }

    // MARK: - terminateDescendants: SwiftMutator's own descendants, never SwiftMutator

    func test_terminateDescendants_stopsEveryDescendantThenKillsThem_neverTheRoot() {
        let run = terminateDescendants(of: 1, listings: [[2, 3], [2, 3]])

        XCTAssertEqual(run.sent, [
            Sent(2, SIGSTOP), Sent(3, SIGSTOP),
            Sent(2, SIGKILL), Sent(3, SIGKILL),
        ])
        XCTAssertEqual(run.listings, 2)
    }

    func test_terminateDescendants_stopsAChildStartedWhileStopping() {
        let run = terminateDescendants(of: 1, listings: [[2], [2, 4], [2, 4]])

        XCTAssertEqual(run.sent, [
            Sent(2, SIGSTOP), Sent(4, SIGSTOP),
            Sent(2, SIGKILL), Sent(4, SIGKILL),
        ])
        XCTAssertEqual(run.listings, 3)
    }

    // The root is SwiftMutator itself: stopped, it would never send the SIGKILLs.
    func test_terminateDescendants_ignoresTheRootIfListed() {
        let run = terminateDescendants(of: 1, listings: [[1, 2], [2, 1]])

        XCTAssertEqual(run.sent, [Sent(2, SIGSTOP), Sent(2, SIGKILL)])
        XCTAssertFalse(run.sent.contains { $0.pid == 1 })
    }

    func test_terminateDescendants_ofNoProcess_sendsNothing() {
        for root: Int32 in [0, -1] {
            let run = terminateDescendants(of: root, listings: [[2]])

            XCTAssertEqual(run.sent, [], "root \(root)")
            XCTAssertEqual(run.listings, 0, "root \(root)")
        }
    }

    // MARK: - A suspension's stop: each round's stops must hold, since its processes stay stopped

    // A stop checked at once could show as held though it wasn't, and a child its process was starting could be
    // missing from a listing straight after. Each round of stops is followed by a pause, then the checks and a new
    // listing.
    func test_aSuspensionsStop_checksItsStops_andListsAgain_afterAPause() {
        let run = stopToSuspend(listings: [[2], [2, 4], [2, 4]])

        XCTAssertEqual(run.steps, [
            "list", "(2, STOP)", "pause", "check 2",
            "list", "(4, STOP)", "pause", "check 2", "check 4",
            "list",
        ])
        XCTAssertEqual(run.stopped, [2, 4])
    }

    // On macOS, a SIGSTOP sent while a process execs can be lost, and the process runs on.
    func test_aSuspensionsStop_stopsAProcessAgain_whenItsStopDidntHold() {
        let run = stopToSuspend(listings: [[2]], stopsThatDontHold: [2: 1])

        XCTAssertEqual(run.steps, [
            "list", "(2, STOP)", "pause", "check 2", "(2, STOP)",
            "list", "pause", "check 2",
            "list",
        ])
    }

    func test_aSuspensionsStop_givesUpOnAStopThatDoesntHold_afterTenListings() {
        // Held at the 100th check, so that a stop with no bound would end rather than hang the test.
        let run = stopToSuspend(listings: [[2]], stopsThatDontHold: [2: 100])

        XCTAssertEqual(run.listings, ProcessTree.maximumListings)
        XCTAssertEqual(run.sent, Array(repeating: Sent(2, SIGSTOP), count: ProcessTree.maximumListings + 1))
    }

    // With no test process under way, a suspension doesn't wait.
    func test_aSuspensionsStop_ofNoDescendant_neitherSignalsNorPauses() {
        let run = stopToSuspend(listings: [[]])

        XCTAssertEqual(run.steps, ["list"])
    }

    // The root is SwiftMutator itself, which stops itself last, once its descendants are stopped.
    func test_aSuspensionsStop_ignoresTheRootIfListed() {
        let run = stopToSuspend(listings: [[1, 2], [2, 1]])

        XCTAssertEqual(run.sent, [Sent(2, SIGSTOP)])
    }

    // MARK: - Helpers

    /// A signal `terminate` sent to a process.
    private struct Sent: Equatable, CustomStringConvertible {
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

    /// `ProcessTree.terminate` or `ProcessTree.terminateDescendants`.
    private typealias Terminating = (
        _ root: Int32,
        _ descendants: (Int32) -> [Int32],
        _ signal: (_ pid: Int32, _ signal: Int32) -> Void
    ) -> Void

    /// Terminates `root`, whose descendants are listed as `listings`, one listing each time `terminate`
    /// asks, then the last one again. Returns the signals it sent and how many times it listed.
    private func terminate(
        root: Int32,
        listings: [[Int32]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (sent: [Sent], listings: Int) {
        record(
            ProcessTree.terminate(root:descendants:signal:),
            root: root,
            listings: listings,
            file: file,
            line: line
        )
    }

    /// `terminate(root:listings:)` for `ProcessTree.terminateDescendants`.
    private func terminateDescendants(
        of root: Int32,
        listings: [[Int32]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (sent: [Sent], listings: Int) {
        record(
            ProcessTree.terminateDescendants(of:descendants:signal:),
            root: root,
            listings: listings,
            file: file,
            line: line
        )
    }

    /// What a suspension's stop of root 1's descendants did, with them listed as `listings`, one listing each time it
    /// asks, then the last one again. A process in `stopsThatDontHold` shows as running for that many checks; every
    /// other shows as stopped.
    private func stopToSuspend(
        listings: [[Int32]],
        stopsThatDontHold: [Int32: Int] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (sent: [Sent], listings: Int, steps: [String], stopped: [Int32]) {
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
        let stopped = ProcessTree.stopDescendants(
            of: 1,
            descendants: { parent in
                XCTAssertEqual(parent, 1, "lists only the root's descendants", file: file, line: line)
                listingCount += 1
                steps.append("list")
                return listings[min(listingCount, listings.count) - 1]
            },
            settling: settling
        ) { pid, signal in
            sent.append(Sent(pid, signal))
            steps.append(Sent(pid, signal).description)
        }
        return (sent, listingCount, steps, stopped)
    }

    private func record(
        _ terminating: Terminating,
        root: Int32,
        listings: [[Int32]],
        file: StaticString,
        line: UInt
    ) -> (sent: [Sent], listings: Int) {
        var sent: [Sent] = []
        var listingCount = 0
        terminating(
            root,
            { parent in
                XCTAssertEqual(parent, root, "lists only the root's descendants", file: file, line: line)
                listingCount += 1
                return listings[min(listingCount, listings.count) - 1]
            },
            { pid, signal in sent.append(Sent(pid, signal)) }
        )
        return (sent, listingCount)
    }
}
