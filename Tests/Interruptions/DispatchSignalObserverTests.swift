@testable import muterCore
import XCTest

/// These change SIGUSR2's disposition in the test runner, and give the earlier one back in `tearDown`. They send no
/// signal: a test never signals the test runner. The acceptance tests send real ones to a SwiftMutator they start.
final class DispatchSignalObserverTests: XCTestCase {
    private let queue = DispatchQueue(label: "DispatchSignalObserverTests")
    private var observer: DispatchSignalObserver!
    private var earlier = sigaction()

    override func setUp() {
        super.setUp()
        sigaction(SIGUSR2, nil, &earlier)
        Foundation.signal(SIGUSR2, SIG_DFL)
        observer = DispatchSignalObserver()
    }

    override func tearDown() {
        queue.sync { observer.stop() }
        sigaction(SIGUSR2, &earlier, nil)
        super.tearDown()
    }

    func test_observesTheSignalsItIsGiven_ignoringThemMeanwhile() {
        let observed = observer.start(observing: [SIGUSR2], on: queue) { _ in }

        XCTAssertEqual(observed, [SIGUSR2])
        // Its default action would end the process, which the signal source alone doesn't stop.
        XCTAssertTrue(DispatchSignalObserver.isIgnored(disposition(of: SIGUSR2)))
    }

    func test_stopping_givesBackTheEarlierDisposition() {
        observer.start(observing: [SIGUSR2], on: queue) { _ in }

        queue.sync { observer.stop() }

        XCTAssertEqual(DispatchSignalObserver.handlerAddress(of: disposition(of: SIGUSR2)), 0, "SIG_DFL")
    }

    func test_stopping_givesBackAHandlerThatWasThereBefore() {
        let doNothing: @convention(c) (Int32) -> Void = { _ in }
        Foundation.signal(SIGUSR2, doNothing)
        observer.start(observing: [SIGUSR2], on: queue) { _ in }

        queue.sync { observer.stop() }

        XCTAssertEqual(
            DispatchSignalObserver.handlerAddress(of: disposition(of: SIGUSR2)),
            unsafeBitCast(doNothing, to: Int.self)
        )
    }

    // `nohup` ignores SIGHUP so that a run outlives its terminal, and a shell ignores SIGINT in a background job.
    func test_aSignalIgnoredAtStart_isNotObserved_andStaysIgnored() {
        Foundation.signal(SIGUSR2, SIG_IGN)

        let observed = observer.start(observing: [SIGUSR2], on: queue) { _ in }
        queue.sync { observer.stop() }

        XCTAssertEqual(observed, [])
        XCTAssertTrue(DispatchSignalObserver.isIgnored(disposition(of: SIGUSR2)))
    }

    // MARK: - Helpers

    private func disposition(of signal: Int32) -> sigaction {
        var current = sigaction()
        sigaction(signal, nil, &current)
        return current
    }
}
