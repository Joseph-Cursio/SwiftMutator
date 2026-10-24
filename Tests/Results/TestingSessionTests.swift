@testable import muterCore
import XCTest

/// A stop at once writes the end line from another thread while mutation testing may be writing a line.
final class TestingSessionTests: XCTestCase {
    private let file = SlowFile()
    private lazy var session: TestingSession = {
        let session = TestingSession(startedAt: Date(timeIntervalSince1970: 0))
        session.startResults(in: file)
        return session
    }()

    func test_theEndLineAtOnce_waitsForTheLineUnderWay_andCountsIt() throws {
        let session = session
        let writing = Thread.detach { _ = session.append({ "mutant" }, isAMutant: true) }
        XCTAssertTrue(file.started.wait(timeout: .now() + 5) == .success)

        let ending = Thread.detach { session.end(waitingAtMost: 5) { Self.endLine(recorded: $0) } }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(file.lines, [], "the end line came inside the line under way")
        file.finish.signal() // for the mutant's line
        file.finish.signal() // for the end line

        XCTAssertTrue(writing.wait(timeout: .now() + 5) == .success)
        XCTAssertTrue(ending.wait(timeout: .now() + 5) == .success)
        XCTAssertEqual(file.lines, ["\"mutant\"", "end of 1"])
        XCTAssertTrue(file.isClosed)
    }

    // As on a disk that has stopped answering: SwiftMutator must still stop.
    func test_theEndLineAtOnce_givesUpOnALineThatTakesTooLong() throws {
        let session = session
        let writing = Thread.detach { _ = session.append({ "mutant" }, isAMutant: true) }
        XCTAssertTrue(file.started.wait(timeout: .now() + 5) == .success)
        defer {
            file.finish.signal()
            _ = writing.wait(timeout: .now() + 5)
        }

        let start = Date()
        session.end(waitingAtMost: 0.2) { Self.endLine(recorded: $0) }

        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(file.lines, [])
    }

    func test_onceEnded_nothingMoreIsWritten() throws {
        file.finish.signal() // for the mutant's line
        file.finish.signal() // for the end line
        XCTAssertEqual(session.append({ "mutant" }, isAMutant: true), true)

        XCTAssertEqual(session.end { Self.endLine(recorded: $0) }, true)

        XCTAssertNil(session.append({ "mutant" }, isAMutant: true))
        XCTAssertNil(session.end { Self.endLine(recorded: $0) })
        session.end(waitingAtMost: 1) { Self.endLine(recorded: $0) }
        XCTAssertEqual(file.lines, ["\"mutant\"", "end of 1"])
    }

    private static func endLine(recorded: Int) -> ResultsEnd {
        ResultsEnd(
            session: 1,
            endedAt: Date(timeIntervalSince1970: 0),
            reason: .interrupted,
            detail: nil,
            testDurationSeconds: 0,
            recorded: recorded
        )
    }
}

/// A results file whose appends each wait for `finish`, after signalling `started`. It keeps an end line as
/// "end of <recorded>", and anything else as JSON.
private final class SlowFile: ResultsRecording, @unchecked Sendable { // `written` and `closed` are behind `lock`
    let path = "/logs/results.jsonl"
    let writeError: Error? = nil
    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var written: [String] = []
    private var closed = false

    var lines: [String] { lock.withLock { written } }
    var isClosed: Bool { lock.withLock { closed } }

    func append(_ line: some Encodable) -> Bool {
        started.signal()
        finish.wait()
        let text = (line as? ResultsEnd).map { "end of \($0.recorded)" }
            ?? String(decoding: (try? JSONEncoder().encode(line)) ?? Data(), as: UTF8.self)
        lock.withLock { written.append(text) }
        return true
    }

    func close() {
        lock.withLock { closed = true }
    }
}

private extension Thread {
    /// Runs `body` on a thread of its own, and returns a semaphore signalled once it has.
    static func detach(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            body()
            done.signal()
        }
        return done
    }
}
