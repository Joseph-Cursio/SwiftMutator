import Foundation

extension Foundation.Process: MuterProcess {}

extension Foundation.Process {
    /// What `url` with `arguments` wrote to standard output, as `runCommand` runs it with no time limit, or nil if it
    /// couldn't be started. Its exit status is then `terminationStatus`: it returns once Foundation has reaped the
    /// command, which on Linux waits for every process the command started that is still running.
    func runProcess(
        url: String,
        arguments args: [String]
    ) async -> Data? {
        await runCommand(url: url, arguments: args, timeLimit: nil, untilFoundationReapsIt: true)
            .map { Data($0.output.utf8) }
    }

    /// How long the output of a command killed at its time limit is waited for. Killing the command's tree closes
    /// its standard output at once, unless a process that escaped the kill, as one whose parent had already exited,
    /// still holds it.
    private static let outputWaitAfterTimeLimit: TimeInterval = 1

    func runCommand(url: String, arguments args: [String], timeLimit: TimeInterval?) async -> CommandResult? {
        await runCommand(url: url, arguments: args, timeLimit: timeLimit, untilFoundationReapsIt: false)
    }

    /// `runCommand`, which returns once the command has exited, and its output has been read, unless
    /// `untilFoundationReapsIt`, when it returns once Foundation has reaped the command too.
    private func runCommand(
        url: String,
        arguments args: [String],
        timeLimit: TimeInterval?,
        untilFoundationReapsIt: Bool
    ) async -> CommandResult? {
        // Standard error goes to a file: a command that filled its pipe while standard output was being read would
        // never exit.
        let errorsURL = FileManager.default.temporaryDirectory.appendingPathComponent("muter-\(UUID().uuidString).err")
        guard FileManager.default.createFile(atPath: errorsURL.path, contents: nil),
              let errorsFile = try? FileHandle(forWritingTo: errorsURL)
        else { return nil }
        defer {
            try? errorsFile.close()
            try? FileManager.default.removeItem(at: errorsURL)
        }
        let output = Pipe()
        standardOutput = output
        standardError = errorsFile
        executableURL = URL(fileURLWithPath: url)
        arguments = args
        // Recorded as soon as Foundation reaps the process, so the time limit never kills a process that has exited,
        // whose ID the system may give to another process. Waiting for the handler holds no thread.
        let ending = TestRunEnding()
        let exited = Latch()
        terminationHandler = ending.recordingExit(opening: exited)
        // Not `try?` then a read: a command that can't be started leaves the pipe open at this end, so the read
        // would never return.
        do { try runWithNoSignalBlocked() } catch { return nil }
        if !untilFoundationReapsIt { watchForExit(recordingIn: ending, opening: exited) }
        if let timeLimit {
            // Not counting the time SwiftMutator was suspended, by Ctrl-Z, with the command.
            @Dependency(\.suspensions) var suspensions: Suspensions
            // The whole tree, not just the command: the test processes `swift test` starts would go on running.
            suspensions.after(timeLimit, on: .global(qos: .userInitiated)) {
                if ending.recordTimeLimit(of: self) { self.terminateTree() }
            }
        }
        // Read while the command runs: one that filled the pipe would never exit.
        let reader = PipeReader(output.fileHandleForReading)
        await exited.wait()
        let timedOut = ending.reason == .timedOut
        let outputData = await reader.data(waitingAtMost: timedOut ? Self.outputWaitAfterTimeLimit : nil)
        let errorsData = FileManager.default.contents(atPath: errorsURL.path) ?? Data()
        let exit = ending.exit(of: self)
        return CommandResult(
            status: exit.status,
            endedBySignal: exit.reason == .uncaughtSignal,
            output: String(lossyUTF8: outputData),
            errors: String(lossyUTF8: errorsData),
            timedOut: timedOut
        )
    }
}
