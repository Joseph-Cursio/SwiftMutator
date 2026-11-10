@testable import muterCore
import XCTest

/// `xcrun simctl`: `list devices --json` prints `list`, and every other command succeeds with no output unless
/// `answering` says otherwise. Commands may run at once, from any thread.
final class SimctlStandIn: MuterProcess, @unchecked Sendable { // every `var` it changes is behind `lock`
    struct Answer {
        var status: Int32 = 0
        var endedBySignal = false
        var output = ""
        var errors = ""
        var timedOut = false
    }

    private let lock = NSLock()
    private let list: Data?
    private var answer: @Sendable ([String]) -> Answer? = { _ in nil }
    private var started: [(arguments: [String], timeLimit: TimeInterval?)] = []
    private var bootsToHoldFor = 0
    private var bootsHeldUntilKilled = false
    private var killed = 0
    private var bootsUnderWay = 0
    private var mostBoots = 0

    init(list: Data?) {
        self.list = list
    }

    /// Each command run, after `xcrun simctl`, in the order they started.
    var commands: [[String]] { lock.withLock { started.map(\.arguments) } }
    var timeLimits: [TimeInterval?] { lock.withLock { started.map(\.timeLimit) } }
    /// The most `bootstatus` commands that ran at once.
    var mostBootsAtOnce: Int { lock.withLock { mostBoots } }
    /// How many times a command was killed, with every process it started.
    var treesKilled: Int { lock.withLock { killed } }

    /// Gives `answer`'s answer to a command, where it gives one.
    func answering(_ answer: @escaping @Sendable ([String]) -> Answer?) {
        lock.withLock { self.answer = answer }
    }

    /// Has each `bootstatus` wait until `count` are under way, for at most 5 seconds, so that boots run one after
    /// another show as one at a time.
    func holdingBootsUntil(_ count: Int) {
        lock.withLock { bootsToHoldFor = count }
    }

    /// Has each `bootstatus` wait until a command is killed, for at most 5 seconds, and then end by SIGKILL.
    func holdingBootsUntilKilled() {
        lock.withLock { bootsHeldUntilKilled = true }
    }

    func runCommand(url: String, arguments args: [String], timeLimit: TimeInterval?) async -> CommandResult? {
        guard url == "/usr/bin/xcrun", args.first == "simctl" else {
            return nil
        }
        let simctlArguments = Array(args.dropFirst())
        let answering = lock.withLock {
            started.append((simctlArguments, timeLimit))
            return self.answer
        }
        let reply = answering(simctlArguments)
        if simctlArguments.first == "bootstatus", lock.withLock({ bootsHeldUntilKilled }) {
            let deadline = Date().addingTimeInterval(5)
            while lock.withLock({ killed }) == 0, Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return CommandResult(status: SIGKILL, endedBySignal: true, output: "", errors: "")
        }
        if simctlArguments.first == "bootstatus" {
            await holdBoot()
        }
        if simctlArguments == ["list", "devices", "--json"], reply == nil {
            guard let list else {
                return CommandResult(status: 1, endedBySignal: false, output: "", errors: "simctl failed")
            }
            return CommandResult(
                status: 0,
                endedBySignal: false,
                output: String(lossyUTF8: list),
                errors: ""
            )
        }
        let given = reply ?? Answer()
        return CommandResult(
            status: given.status,
            endedBySignal: given.endedBySignal,
            output: given.output,
            errors: given.errors,
            timedOut: given.timedOut
        )
    }

    private func holdBoot() async {
        let holdFor = lock.withLock {
            bootsUnderWay += 1
            mostBoots = max(mostBoots, bootsUnderWay)
            return bootsToHoldFor
        }
        let deadline = Date().addingTimeInterval(5)
        while lock.withLock({ mostBoots }) < holdFor, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        lock.withLock { bootsUnderWay -= 1 }
    }

    var processIdentifier: Int32 { 0 }
    var terminationStatus: Int32 { 0 }
    var terminationReason: Foundation.Process.TerminationReason { .exit }
    var terminationHandler: (@Sendable (Foundation.Process) -> Void)?
    var environment: [String: String]?
    var arguments: [String]?
    var executableURL: URL?
    var currentDirectoryURL: URL?
    var standardOutput: Any?
    var standardError: Any?

    func runProcess(url _: String, arguments _: [String]) -> Data? { nil }

    func run() throws {
        // A fake process: nothing runs.
    }

    func terminate() {
        // A fake process: nothing runs.
    }

    func interrupt() {
        // A fake process: nothing runs.
    }

    func terminateTree() {
        lock.withLock { killed += 1 }
    }
}
