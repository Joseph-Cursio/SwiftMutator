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

    // The run relies on it: the report is written before SwiftMutator exits, and a test's log is in the log folder
    // before its file is removed.
    func test_anEvent_isHandled_beforeSendReturns_onTheSendersThread() {
        let events = RunEvents()
        let sender = Thread.current
        var handledOn: Thread?
        let subscription = events.observe { _ in handledOn = Thread.current }

        events.send(.muterLaunched)

        XCTAssertTrue(handledOn === sender)
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
