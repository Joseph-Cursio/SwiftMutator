import XCTest

extension ResumeHarness {
    /// Waits up to 120 seconds for `launched` to end. One still running then is killed, with the process group
    /// Foundation.Process started it in, which holds it alone, and the test fails.
    func waitForEnd(of launched: Launched) throws -> Ended {
        let process = launched.process
        guard waitUntil(within: 120, { !process.isRunning }) else {
            let pid = process.processIdentifier
            if pid > 1 { kill(-pid, SIGKILL) }
            throw RanOver(arguments: process.arguments ?? [])
        }
        process.waitUntilExit()
        return Ended(
            status: process.terminationStatus,
            standardOutput: contents(of: launched.standardOutput),
            standardError: contents(of: launched.standardError)
        )
    }

    /// Waits until the test command hangs, with its `sleep` started, and SwiftMutator still runs.
    func waitUntilHanging(
        _ launched: Launched,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let process = launched.process
        let hanging = waitUntil(within: 60) {
            self.recordMarkers()
            return !self.sleepers.isEmpty || !process.isRunning
        }
        guard hanging, process.isRunning, !sleepers.isEmpty else {
            let error = DidNotHang(description: """
            The test command didn't hang: SwiftMutator \
            \(process.isRunning ? "is still running" : "ended (\(describe(process)))").
            Standard error: \(contents(of: launched.standardError))
            """)
            XCTFail(error.description, file: file, line: line)
            throw error
        }
    }

    /// As a terminal's Ctrl-C: the group holds SwiftMutator alone, since each process SwiftMutator starts leads a
    /// group of its own.
    func signalGroup(of launched: Launched, _ signal: Int32) {
        let pid = launched.process.processIdentifier
        guard pid > 1, launched.process.isRunning else {
            XCTFail("SwiftMutator isn't running")
            return
        }
        kill(-pid, signal)
    }

    /// That SwiftMutator ended within 15 seconds, killed by `signal`, as its default action would have, so that a
    /// shell sees it die of the signal.
    func assertDied(
        _ launched: Launched,
        by signal: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let process = launched.process
        guard waitUntil(within: 15, { !process.isRunning }) else {
            XCTFail("SwiftMutator was still running after 15 s", file: file, line: line)
            return
        }
        XCTAssertEqual(
            describe(process),
            "killed by signal \(signal)",
            contents(of: launched.standardError),
            file: file,
            line: line
        )
    }

    func describe(_ ended: Foundation.Process) -> String {
        ended.terminationReason == .uncaughtSignal
            ? "killed by signal \(ended.terminationStatus)"
            : "exited with \(ended.terminationStatus)"
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
