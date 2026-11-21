import Foundation

/// Cuts the pieces a growing log is read in into whole lines. A line is returned only once its "\n" has
/// arrived, so a piece that ends partway through a line, or through a character such as "✘", is never
/// decoded early.
struct LogLineBuffer {
    /// An unfinished line longer than this isn't a failed-test line: dropping it keeps a test that prints
    /// without line breaks from growing this without limit. The rest of that line is dropped as it arrives,
    /// as it isn't the start of a line either.
    static let maximumPendingBytes = 1 << 20
    private static let lineBreak = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    private var pending = Data()
    private var isDroppingLine = false

    /// The lines `bytes` finishes, without their line breaks.
    mutating func append(_ bytes: Data) -> [String] {
        var bytes = bytes
        if isDroppingLine {
            guard let breakIndex = bytes.firstIndex(of: Self.lineBreak) else { return [] }
            bytes = bytes[bytes.index(after: breakIndex)...]
            isDroppingLine = false
        }
        pending.append(bytes)
        guard let lastLineBreak = pending.lastIndex(of: Self.lineBreak) else {
            if pending.count > Self.maximumPendingBytes {
                pending = Data()
                isDroppingLine = true
            }
            return []
        }
        // Split before decoding: decoded, "\r\n" is a single Character, so no line would end at "\n".
        let lines = pending[..<lastLineBreak]
            .split(separator: Self.lineBreak, omittingEmptySubsequences: false)
            .map { line in
                String(lossyUTF8: line.last == Self.carriageReturn ? line.dropLast() : line)
            }
        pending = Data(pending[pending.index(after: lastLineBreak)...])
        return lines
    }
}

/// Follows a test command's log while the command writes it, and finds the first line that shows a failed
/// test or a crash. It only reads: the command writes the log itself, as its standard output and error.
struct TestLogFollower {
    /// The most it reads at once.
    static let readSize = 65_536

    let logFileUrl: URL
    /// Whether the log is xcodebuild's, where a crash shows as the Swift runtime's trap message (`TrapLine`) or
    /// xcodebuild's restart line (`XcodebuildRestartLine`), as `TestSuiteOutcome` reads them at the time limit. Not
    /// for SwiftPM, whose test process can print the runtime's message and go on, and whose signal line (`CrashLine`)
    /// follows it when the process dies of it. Parallel testing's `Test case '…' failed on '…'` lines never stop a
    /// run: they read the same for a crash and a failed test. A worker on a simulator of its own tests one test at a
    /// time, and a lone worker on the test command's destination that tests in parallel doesn't stop at all
    /// (`MuterConfiguration.stopAtFirstFailureUnsupportedReason`), as nothing but a crash would stop its runs.
    var readsXcodebuildCrashes = false
    /// How long it waits for more output once it has read everything written so far.
    var pollInterval: TimeInterval = 0.1

    /// The first line that shows a failed test (`FailedTestLine`) or a crash (`CrashLine`, and under xcodebuild
    /// `TrapLine` and `XcodebuildRestartLine`), without colour codes, as the reason to stop the run. Nil once the
    /// calling task is cancelled, or if the log can't be opened: the run then goes to its end.
    func firstStop() async -> TestRunEnding.Reason? {
        guard let reader = try? FileHandle(forReadingFrom: logFileUrl) else { return nil }
        defer { try? reader.close() }
        var lines = LogLineBuffer()
        while !Task.isCancelled {
            if let bytes = try? reader.read(upToCount: Self.readSize), !bytes.isEmpty {
                for line in lines.append(bytes) {
                    if FailedTestLine.matches(line) {
                        return .failedTest(line: FailedTestLine.withoutColours(line))
                    }
                    if showsACrash(line) {
                        return .crashed(line: FailedTestLine.withoutColours(line))
                    }
                }
                continue
            }
            // Once the task is cancelled this throws at once, and the loop ends.
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return nil
    }

    private func showsACrash(_ line: String) -> Bool {
        CrashLine.matches(line)
            || readsXcodebuildCrashes && (TrapLine.matches(line) || XcodebuildRestartLine.matches(line))
    }
}
