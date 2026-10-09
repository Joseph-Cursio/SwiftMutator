import Foundation
@testable import muterCore

final class ProcessSpy: MuterProcess {
    var processIdentifier: Int32 { 0 }
    var terminationStatus: Int32 = 0
    var terminationReason: Foundation.Process.TerminationReason = .exit
    var terminationHandler: (@Sendable (Foundation.Process) -> Void)? = nil
    var environment: [String: String]?
    var arguments: [String]?
    var executableURL: URL?
    var currentDirectoryURL: URL?
    var standardOutput: Any?
    var standardError: Any?

    private let queue = Queue<String>()
    var stdoutToBeReturned = "" {
        didSet {
            queue.enqueue(stdoutToBeReturned)
        }
    }

    var runCalled = false
    /// Set to simulate a process that can't be launched at all — what `Foundation.Process.run()` throws
    /// when `executableURL` names a file that doesn't exist.
    var runError: Error?
    func run() throws {
        runCalled = true

        if let runError {
            throw runError
        }
    }

    var waitUntilExitCalled = false
    /// What the process writes to its `standardOutput` before it exits, such as a test command's log.
    /// Separate from `stdoutToBeReturned`, which is what `runProcess` returns.
    var outputWrittenBeforeExit = Data()
    func waitUntilExit() {
        waitUntilExitCalled = true
        try? (standardOutput as? FileHandle)?.write(contentsOf: outputWrittenBeforeExit)
    }

    func runProcess(url: String, arguments args: [String]) -> Data? {
        executableURL = URL(string: url)
        arguments = args

        print("WARNING: Missing return for \(url) \(args.joined(separator: " "))")
        
        return queue.dequeue()?.data(using: .utf8)
    }

    /// Each command `runCommand` was asked for, its executable first, in order.
    private(set) var commandsRun: [[String]] = []
    /// What `runCommand` gives for a command, its executable first: nil, as for one that can't be started, unless set.
    var commandResult: ([String]) -> CommandResult? = { _ in nil }
    func runCommand(url: String, arguments args: [String]) -> CommandResult? {
        commandsRun.append([url] + args)
        return commandResult([url] + args)
    }

    var terminateCalled = false
    func terminate() {
        terminateCalled = true
    }

    func interrupt() {}

    // Override the protocol's default `terminateTree()` so tests can assert the timeout handler
    // reaches for the tree-kill without invoking the real `ps`/`kill` path.
    private(set) var terminateTreeCalled = false
    func terminateTree() {
        terminateTreeCalled = true
    }
}
