import Foundation

typealias Process = MuterProcess

/// How a command ended, and what it wrote.
struct CommandResult: Equatable {
    /// Its exit code, or the signal that killed it.
    let status: Int32
    let endedBySignal: Bool
    let output: String
    let errors: String
    /// Whether it ran past its time limit, so it was killed with every process it started. A `var` only so the
    /// memberwise initializer can leave it out.
    var timedOut = false

    /// Not when it timed out, even if it exited as it was killed.
    var succeeded: Bool { !timedOut && !endedBySignal && status == 0 }
}

/// Sendable: once a process runs, its time limit, its first failed test and its task's cancellation each kill it from a
/// task or thread of their own, and Foundation calls its `terminationHandler` on another. They only read it: it is set
/// up before `run()`. `Foundation.Process` is Sendable itself.
protocol MuterProcess: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    var terminationStatus: Int32 { get }
    /// Whether the process exited or died of a signal; `terminationStatus` is then its exit code or that signal.
    var terminationReason: Foundation.Process.TerminationReason { get }
    var terminationHandler: (@Sendable (Foundation.Process) -> Void)? { get set }
    var environment: [String: String]? { get set }
    var arguments: [String]? { get set }
    var executableURL: URL? { get set }
    var currentDirectoryURL: URL? { get set }
    var standardOutput: Any? { get set }
    var standardError: Any? { get set }

    func runProcess(
        url: String,
        arguments args: [String]
    ) async -> Data?

    /// Runs `url` with `arguments` to its end, for its exit status and what it wrote to standard output and standard
    /// error, or nil if it couldn't be started. Past `timeLimit` seconds, if there is one, it kills the command and
    /// every process it started, and the result says it timed out. Waiting for it holds no thread.
    func runCommand(url: String, arguments args: [String], timeLimit: TimeInterval?) async -> CommandResult?

    /// Starts the process. Its `terminationHandler`, set before, says when it has exited: there is no
    /// `waitUntilExit()`, which would hold a thread of Swift concurrency's pool until then.
    func run() throws

    func terminate()

    func interrupt()

    /// Stop, then SIGKILL, this process and every transitive descendant (default impl: `ProcessTree.terminate`).
    /// Declared here so it dynamically dispatches to conformers/test doubles rather than binding statically.
    func terminateTree()

    /// Whether the process has exited, though Foundation may not have reaped it yet. Declared here for test doubles.
    func hasExited() -> Bool
}

extension MuterProcess {
    /// For test doubles that never run a command this way: as if it couldn't be started. `Foundation.Process` runs it.
    func runCommand(url: String, arguments args: [String], timeLimit: TimeInterval?) async -> CommandResult? {
        nil
    }

    /// `runCommand` with no time limit.
    func runCommand(url: String, arguments args: [String]) async -> CommandResult? {
        await runCommand(url: url, arguments: args, timeLimit: nil)
    }

    /// SIGKILL this process and every transitive descendant. `interrupt()`/`terminate()` signal only
    /// the launched command (`swift test` / `xcodebuild`), not the test-runner grandchildren it spawns
    /// (`swiftpm-testing-helper`, `xctest`); those survive, keep spinning at ~100% CPU, and accumulate
    /// across mutants until they starve the machine. Stop the whole tree, listing it from the kernel on
    /// macOS so no `ps` starts on every kill, then kill it, so a timed-out mutant's test leaves nothing behind.
    func terminateTree() {
        ProcessTree.terminate(root: processIdentifier, descendants: ProcessTree.descendants(of:)) { pid, signal in
            kill(pid, signal)
        }
    }

    /// Asks the kernel, without reaping the process: Foundation still reaps it, and reads how it ended. A process
    /// that never launched, or isn't SwiftMutator's child, hasn't exited.
    func hasExited() -> Bool {
        guard processIdentifier > 0 else { return false }
        var info = siginfo_t()
        guard waitid(P_PID, id_t(processIdentifier), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else { return false }
        // With WNOHANG, a child that is still running leaves `si_signo` 0 (POSIX).
        return info.si_signo == SIGCHLD
    }

    /// `terminateTree()` on a GCD thread, for a caller that shouldn't wait while the tree is listed, such
    /// as a task's cancellation handler, which runs on the thread that cancels the task.
    func terminateTreeInBackground() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.terminateTree()
        }
    }

    func runProcess(
        url: String,
        arguments: [String]
    ) async -> String? {
        guard let output: Data = await runProcess(url: url, arguments: arguments) else {
            return nil
        }

        return String(data: output, encoding: .utf8)
    }

    func find(
        atPath path: String,
        byName name: String
    ) async -> String? {
        await runProcess(
            url: "/usr/bin/find",
            arguments: [path, "-name", name]
        )
        .flatMap(\.nilIfEmpty)
    }

    /// Paths under `path` whose name is any of `names`, in one `find` call.
    func find(
        atPath path: String,
        byNames names: [String]
    ) async -> String? {
        let alternatives = names.flatMap { ["-o", "-name", $0] }.dropFirst()
        return await runProcess(
            url: "/usr/bin/find",
            arguments: [path, "("] + alternatives + [")"]
        )
        .flatMap(\.nilIfEmpty)
    }

    func which(_ application: String) async -> String? {
        await runProcess(
            url: "/usr/bin/which",
            arguments: [application]
        )
        .flatMap(\.nilIfEmpty)
        .map(\.trimmed)
    }
}
