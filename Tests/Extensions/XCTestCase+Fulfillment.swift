import XCTest

#if os(Linux)
public extension XCTestCase {
    /// Waits for the expectations on a detached thread, standing in for the async fulfillment Apple platforms have.
    func fulfillment(of expectations: [XCTestExpectation], timeout: TimeInterval, enforceOrder: Bool = false) async {
        // The test awaits the thread below and does nothing meanwhile, so the two never use the test case at once.
        nonisolated(unsafe) let testCase = self
        await withCheckedContinuation { continuation in
            // This function operates by blocking a background thread instead of one owned by libdispatch or by the
            // Swift runtime (as used by Swift concurrency.) To ensure we use a thread owned by neither subsystem, use
            // Foundation's Thread.detachNewThread(_:).
            Thread.detachNewThread {
                testCase.wait(for: expectations, timeout: timeout, enforceOrder: enforceOrder)
                continuation.resume()
            }
        }
    }
}
#endif
