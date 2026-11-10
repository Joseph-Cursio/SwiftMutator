@testable import muterCore
import XCTest

extension MuterTestCase {
    /// An expectation fulfilled by the first event named `name` sent from now on that `handler`, if given, accepts.
    /// Events are handled as they are sent, so a test can wait for it with any timeout once the event's sender returns.
    func expectation(forEvent name: RunEvent.Name, handler: ((RunEvent) -> Bool)? = nil) -> XCTestExpectation {
        let expectation = expectation(description: "\(name) sent")
        expectation.assertForOverFulfill = false
        let subscription = runEvents.observe(name) { event in
            if handler?(event) ?? true { expectation.fulfill() }
        }
        addTeardownBlock { subscription.cancel() }
        return expectation
    }
}
