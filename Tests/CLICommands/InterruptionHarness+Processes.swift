import XCTest

extension InterruptionHarness {
    /// As a terminal's Ctrl-C, or a hangup a shell forwards: the group holds SwiftMutator alone, since each process
    /// SwiftMutator starts leads a group of its own.
    func signalGroup(of mutator: Foundation.Process, _ signal: Int32) {
        let pid = mutator.processIdentifier
        guard pid > 1, mutator.isRunning else {
            XCTFail("SwiftMutator isn't running")
            return
        }
        kill(-pid, signal)
    }

    func signalProcess(_ mutator: Foundation.Process, _ signal: Int32) {
        let pid = mutator.processIdentifier
        guard pid > 1, mutator.isRunning else {
            XCTFail("SwiftMutator isn't running")
            return
        }
        kill(pid, signal)
    }

    /// Whether the process with this ID is stopped, as by SIGSTOP or SIGTSTP. A process that is gone isn't.
    func isStopped(_ pid: Int32) -> Bool {
        #if os(macOS)
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat == SSTOP
        #else
        // proc(5): the state follows the name, which is in parentheses.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let end = stat.lastIndex(of: ")")
        else { return false }
        return stat[stat.index(after: end)...].trimmingCharacters(in: .whitespaces).hasPrefix("T")
        #endif
    }

    func describe(_ ended: Foundation.Process) -> String {
        ended.terminationReason == .uncaughtSignal
            ? "killed by signal \(ended.terminationStatus)"
            : "exited with \(ended.terminationStatus)"
    }

    func records(in file: URL) throws -> [[String: Any]] {
        try contents(of: file)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    func contents(of file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    /// Polls `condition` until it holds or `timeout` seconds pass, and returns whether it held.
    func waitUntil(within timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}
