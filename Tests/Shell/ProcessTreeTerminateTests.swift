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

    // MARK: - A kill's check: a SIGKILL sent just after a SIGSTOP can leave a process suspended

    func test_aKill_killsAProcessAgain_untilItHasEnded() {
        let run = killing(root: 1, listings: [[2]], endsAtCheck: [1: 1, 2: 3])

        XCTAssertEqual(run.steps, [
            "started 2", "started 1", "(2, KILL)", "(1, KILL)",
            "pause 1000", "started 2", "started 1", "(2, KILL)",
            "pause 2000", "started 2", "(2, KILL)",
            "pause 4000", "started 2",
        ])
    }

    func test_aKillOfDescendants_killsAProcessAgain_untilItHasEnded_neverTheRoot() {
        let run = killingDescendants(of: 1, listings: [[2]], endsAtCheck: [1: 9, 2: 2])

        XCTAssertEqual(run.steps, [
            "started 2", "(2, KILL)",
            "pause 1000", "started 2", "(2, KILL)",
            "pause 2000", "started 2",
        ])
    }

    func test_aKill_doesntPause_ifEveryProcessHadEndedBeforeIt() {
        let run = killing(root: 1, listings: [[2]])

        XCTAssertEqual(run.steps, ["started 2", "started 1", "(2, KILL)", "(1, KILL)"])
    }

    // A process that ended by itself may have given its ID to another, which is no part of this tree.
    func test_aKill_leavesAProcessAlone_onceItsIDWentToAnother() {
        var checks = 0
        let run = killing(root: 1, listings: [[2]]) { pid in
            guard pid == 2 else { return nil }
            checks += 1
            return checks < 2 ? 100 : 200
        }

        XCTAssertEqual(run.steps, ["started 2", "started 1", "(2, KILL)", "(1, KILL)", "pause 1000", "started 2"])
    }

    func test_aKill_givesUpOnAProcessThatNeverEnds_keepingItsPausesShort() {
        let run = killing(root: 1, listings: [[2]], endsAtCheck: [2: .max])

        let pauses = run.pauses
        XCTAssertEqual(Array(pauses.prefix(6)), [1_000, 2_000, 4_000, 8_000, 10_000, 10_000])
        XCTAssertEqual(Set(pauses.dropFirst(4)), [ProcessTree.longestKillPauseMicroseconds])
        // 1000 + 2000 + 4000 + 8000, then 10000 each until a full second has passed.
        XCTAssertEqual(pauses.reduce(0, +), ProcessTree.longestKillWaitMicroseconds + 5_000)
        XCTAssertEqual(run.sent.filter { $0 == Sent(2, SIGKILL) }.count, pauses.count + 1)
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
}
