import Foundation

/// Takes a lock: test runs started at once, as parallel workers' are, each write their active-mutant file
/// through it, from several threads.
final class WriteFileSpy {
    private let lock = NSLock()
    private var called = false
    private var content: String?
    private var path: String?
    private var error: Error?

    var writeFileCalled: Bool { lock.withLock { called } }
    var contentPassed: String? { lock.withLock { content } }
    var pathPassed: String? { lock.withLock { path } }
    /// Set to simulate a file that can't be written, such as one in a folder without write permission.
    var errorToThrow: Error? {
        get { lock.withLock { error } }
        set { lock.withLock { error = newValue } }
    }

    func writeFile(_ content: String, _ path: String) throws {
        try lock.withLock {
            called = true
            self.content = content
            self.path = path

            if let error {
                throw error
            }
        }
    }
}
