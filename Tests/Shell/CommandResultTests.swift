@testable import muterCore
import XCTest

final class CommandResultTests: XCTestCase {
    // Through the protocol, as the coverage step runs it, so `Foundation.Process`'s own is the one run.
    func test_aCommand_givesItsExitStatus_andWhatItWroteToEachStream() {
        let process: MuterProcess = Foundation.Process()
        let result = process.runCommand(
            url: "/bin/sh",
            arguments: ["-c", "echo out; echo err >&2; exit 3"]
        )

        XCTAssertEqual(result, CommandResult(status: 3, endedBySignal: false, output: "out\n", errors: "err\n"))
        XCTAssertEqual(result?.succeeded, false)
    }

    // Standard error can't fill a pipe and hold the command up while its standard output is read.
    func test_aCommand_thatWritesMuchToStandardError_stillEnds() {
        let result = Foundation.Process().runCommand(
            url: "/bin/sh",
            arguments: ["-c", "head -c 1000000 /dev/zero | tr '\\\\0' x >&2; echo done"]
        )

        XCTAssertEqual(result?.output, "done\n")
        XCTAssertEqual(result?.errors.count, 1_000_000)
        XCTAssertEqual(result?.succeeded, true)
    }

    // Standard output is read while the command runs, so one that writes more than a pipe holds still ends. On a
    // thread of its own, so a command that never ends fails the test rather than hanging the suite.
    func test_aCommand_thatWritesMuchToStandardOutput_stillEnds() {
        let process = Foundation.Process()
        let ended = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: CommandResult?
        Thread.detachNewThread {
            result = process.runCommand(url: "/usr/bin/head", arguments: ["-c", "1000000", "/dev/zero"])
            ended.signal()
        }
        guard ended.wait(timeout: .now() + 30) == .success else {
            process.terminate()
            return XCTFail("runCommand didn't end")
        }

        XCTAssertEqual(result?.output.utf8.count, 1_000_000)
        XCTAssertEqual(result?.succeeded, true)
    }

    func test_aCommandKilledByASignal_saysSo() {
        let result = Foundation.Process().runCommand(url: "/bin/sh", arguments: ["-c", "kill -9 $$"])

        XCTAssertEqual(result?.endedBySignal, true)
        XCTAssertEqual(result?.status, 9)
        XCTAssertEqual(result?.succeeded, false)
    }

    // `runProcess` hangs here: the pipe it reads stays open at this end.
    func test_aCommandThatCantBeStarted_givesNil_atOnce() {
        XCTAssertNil(Foundation.Process().runCommand(url: "/nonexistent/tool", arguments: []))
    }
}
