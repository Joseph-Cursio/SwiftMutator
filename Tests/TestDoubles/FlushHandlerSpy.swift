import Foundation

// A test sets it up, then the code under test uses it from one task at a time, so it needs no lock.
final class FlushHandlerSpy: @unchecked Sendable {
    private(set) var flushHandlerWasCalled = false

    func flush() {
        flushHandlerWasCalled = true
    }
}
