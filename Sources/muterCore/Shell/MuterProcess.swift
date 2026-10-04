import Foundation

typealias Process = MuterProcess

protocol MuterProcess: AnyObject {
    var processIdentifier: Int32 { get }
    var terminationStatus: Int32 { get }
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
    ) -> Data?

    func run() throws

    func waitUntilExit()

    func terminate()

    func interrupt()

    /// Stop, then SIGKILL, this process and every transitive descendant (default impl: `ProcessTree.terminate`).
    /// Declared here so it dynamically dispatches to conformers/test doubles rather than binding statically.
    func terminateTree()
}

extension MuterProcess {
    /// Waits for this process to exit on a GCD thread. `waitUntilExit()` blocks its thread until then,
    /// and Swift concurrency has only about as many threads as the machine has cores: test runs waiting
    /// on them could hold every one, and nothing else could run, not even a run's time limit. Ignores
    /// cancellation, as `waitUntilExit()` does: `terminationStatus` may be read only after exit. So
    /// whoever cancels a run kills its process, and this returns once the process is gone.
    func exited() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                self.waitUntilExit()
                continuation.resume()
            }
        }
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
    ) -> String? {
        guard let output: Data = runProcess(url: url, arguments: arguments) else {
            return nil
        }

        return String(data: output, encoding: .utf8)
    }

    func find(
        atPath path: String,
        byName name: String
    ) -> String? {
        runProcess(
            url: "/usr/bin/find",
            arguments: [path, "-name", name]
        )
        .flatMap(\.nilIfEmpty)
    }

    /// Paths under `path` whose name is any of `names`, in one `find` call.
    func find(
        atPath path: String,
        byNames names: [String]
    ) -> String? {
        let alternatives = names.flatMap { ["-o", "-name", $0] }.dropFirst()
        return runProcess(
            url: "/usr/bin/find",
            arguments: [path, "("] + alternatives + [")"]
        )
        .flatMap(\.nilIfEmpty)
    }

    func findExecutable(
        atPath path: String,
        byName name: String
    ) -> String? {
        runProcess(
            url: "/usr/bin/find",
            arguments: [path, "-type", "f", "-name", name]
        )
        .flatMap(\.nilIfEmpty)
        .map(\.trimmed)
    }

    func which(_ application: String) -> String? {
        runProcess(
            url: "/usr/bin/which",
            arguments: [application]
        )
        .flatMap(\.nilIfEmpty)
        .map(\.trimmed)
    }
}
