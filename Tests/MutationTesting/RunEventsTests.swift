@testable import muterCore
import XCTest

final class RunEventsTests: MuterTestCase {
    func test_eachObserver_getsEachEvent_inTheOrderTheyWereAdded() {
        let events = RunEvents()
        var seen: [String] = []
        let first = events.observe { seen.append("first \($0.name)") }
        let second = events.observe { seen.append("second \($0.name)") }

        events.send(.mutationTestingStarted)
        events.send(.mutantRunsStarted)

        XCTAssertEqual(seen, [
            "first mutationTestingStarted", "second mutationTestingStarted",
            "first mutantRunsStarted", "second mutantRunsStarted",
        ])
        withExtendedLifetime((first, second)) {}
    }

    // The run relies on it: the report is written before SwiftMutator exits.
    func test_anEvent_isHandled_beforeSendReturns_onTheSendersThread() {
        let events = RunEvents()
        let sender = Thread.current
        var handledOn: Thread?
        let subscription = events.observe { _ in handledOn = Thread.current }

        events.send(.muterLaunched)

        XCTAssertIdentical(handledOn, sender)
        withExtendedLifetime(subscription) {}
    }

    func test_aCancelledObserver_getsNoMoreEvents() {
        let events = RunEvents()
        var count = 0
        let subscription = events.observe { _ in count += 1 }

        events.send(.muterLaunched)
        subscription.cancel()
        events.send(.muterLaunched)

        XCTAssertEqual(count, 1)
    }

    func test_anObserverWhoseSubscriptionIsLetGo_getsNoMoreEvents() {
        let events = RunEvents()
        var count = 0
        var subscription: RunEvents.Subscription? = events.observe { _ in count += 1 }

        events.send(.muterLaunched)
        subscription = nil
        events.send(.muterLaunched)

        XCTAssertEqual(count, 1)
        XCTAssertNil(subscription)
    }

    // An observer can say something of its own, as a warning in reply to an event.
    func test_anObserver_canSendAnEvent() {
        let events = RunEvents()
        var seen: [RunEvent.Name] = []
        let subscription = events.observe { event in
            seen.append(event.name)
            if event.name == .mutationTestingStarted { events.send(.mutantRunsStarted) }
        }

        events.send(.mutationTestingStarted)

        XCTAssertEqual(seen, [.mutationTestingStarted, .mutantRunsStarted])
        withExtendedLifetime(subscription) {}
    }

    // Observers such as `Logger` and `MutationTestObserver` keep state with no lock of their own, so a second sender
    // waits for the event under way.
    func test_eventsSentFromManyThreads_areHandledOneAtATime() {
        let events = RunEvents()
        let handling = OverlapCounter()
        let subscription = events.observe { _ in handling.handle() }

        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            events.send(.mutantRunsStarted)
        }

        XCTAssertEqual(handling.handled, 200)
        XCTAssertEqual(handling.overlaps, 0)
        withExtendedLifetime(subscription) {}
    }

    // Observing the run's events used to keep the observer alive for good, as NotificationCenter kept its handlers.
    func test_theMutationTestObserver_isFreed_andHandlesNoMoreEvents() throws {
        var observer: MutationTestObserver? = MutationTestObserver(runOptions: .make())
        try observer?.start()
        weak let freed = observer

        observer = nil
        runEvents.send(.mutationTestingStarted)

        XCTAssertNil(freed)
        XCTAssertEqual(printer.linesPassed, [])
    }
}

/// Counts the events an observer handles, and how many of them began while another was being handled.
private final class OverlapCounter: @unchecked Sendable { // every `var` is behind `lock`
    private let lock = NSLock()
    private var active = 0
    private var handledCount = 0
    private var overlapCount = 0

    var handled: Int { lock.withLock { handledCount } }
    var overlaps: Int { lock.withLock { overlapCount } }

    func handle() {
        lock.withLock {
            if active > 0 { overlapCount += 1 }
            active += 1
        }
        // Long enough for another sender to arrive meanwhile.
        Thread.sleep(forTimeInterval: 0.0001)
        lock.withLock {
            active -= 1
            handledCount += 1
        }
    }
}
