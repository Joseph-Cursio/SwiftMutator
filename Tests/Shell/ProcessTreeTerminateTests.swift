@testable import muterCore
import XCTest

/// `ProcessTree.terminate` and `terminateDescendants` with made-up listings. They record the signals they
/// would send instead of sending them; `ProcessTreeTests` kills a real tree.
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
