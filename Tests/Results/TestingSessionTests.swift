@testable import muterCore
import XCTest

/// A stop at once writes the end line from another thread while mutation testing may be writing a line.
final class TestingSessionTests: XCTestCase {
    private let file = SlowFile()
    private lazy var session: TestingSession = {
        let made = TestingSession(startedAt: Date(timeIntervalSince1970: 0))
        _ = made.startResults(in: file, writing: [])
        return made
    }()

    func test_theEndLineAtOnce_waitsForTheLineUnderWay_andCountsIt() throws {
        let sessionUnderTest = session
        let writing = Thread.detach { _ = sessionUnderTest.append({ "mutant" }, isAMutant: true) }
        XCTAssertTrue(file.started.wait(timeout: .now() + 5) == .success)

        let ending = Thread.detach { sessionUnderTest.end(waitingAtMost: 5) { Self.endLine(recorded: $0) } }
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
        let sessionUnderTest = session
        let writing = Thread.detach { _ = sessionUnderTest.append({ "mutant" }, isAMutant: true) }
        XCTAssertTrue(file.started.wait(timeout: .now() + 5) == .success)
        defer {
            file.finish.signal()
            _ = writing.wait(timeout: .now() + 5)
        }

        let start = Date()
        sessionUnderTest.end(waitingAtMost: 0.2) { Self.endLine(recorded: $0) }

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

    // A resumed session's header and its `retired` line: an end line between them would end the session before it
    // retired the results it doesn't keep.
    func test_theEndLineAtOnce_comesAfterTheFirstLines_neverBetweenThem() throws {
        let secondSession = TestingSession(number: 2, startedAt: Date(timeIntervalSince1970: 0))
        let header = ResultsHeader.make(formatVersion: ResultsCoding.resumedFormatVersion, session: 2)
        let retired = ResultsRetired(session: 2, keys: [MutantResult.make().key])
        let starting = Thread.detach { [file] in _ = secondSession.startResults(in: file, writing: [header, retired]) }
        XCTAssertTrue(file.started.wait(timeout: .now() + 5) == .success)

        // The end line waits for the first lines to be written, not only to start: if it reached the file while they
        // were under way, it would come among them.
        let ending = Thread.detach { secondSession.end(waitingAtMost: 5) { Self.endLine(recorded: $0) } }
        XCTAssertTrue(file.started.wait(timeout: .now() + 0.2) == .timedOut, "the end line came among the first lines")
        file.finish.signal() // for the first lines
        XCTAssertTrue(file.started.wait(timeout: .now() + 5) == .success, "the end line wasn't written")
        file.finish.signal() // for the end line

        XCTAssertTrue(starting.wait(timeout: .now() + 5) == .success)
        XCTAssertTrue(ending.wait(timeout: .now() + 5) == .success)
        XCTAssertEqual(file.lines, [json(header), json(retired), "end of 0"])
        XCTAssertTrue(file.isClosed)
    }

    // Before its first lines, a session has no file, and a stop at once ends nothing: the process exits next.
    func test_theEndLineAtOnce_beforeTheFirstLines_writesNothing() throws {
        let newSession = TestingSession(startedAt: Date(timeIntervalSince1970: 0))

        newSession.end(waitingAtMost: 1) { Self.endLine(recorded: $0) }

        XCTAssertNil(newSession.results)
        XCTAssertEqual(file.lines, [])
        XCTAssertFalse(file.isClosed)
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

/// A results file whose appends each wait for `finish`, after signalling `started`, as does each batch of lines, once
/// for all of them. It keeps an end line as "end of <recorded>", and anything else as JSON.
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
        append(contentsOf: [line])
    }

    func append(contentsOf lines: [any Encodable]) -> Bool {
        guard !lines.isEmpty else { return true }
        started.signal()
        finish.wait()
        let texts = lines.map { line in (line as? ResultsEnd).map { "end of \($0.recorded)" } ?? json(line) }
        lock.withLock { written += texts }
        return true
    }

    func close() {
        lock.withLock { closed = true }
    }
}

/// `line` as JSON, its keys sorted so the same line always reads the same.
private func json(_ line: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: (try? encoder.encode(line)) ?? Data(), as: UTF8.self)
}

private extension Thread {
    /// Runs `body` on a thread of its own, and returns a semaphore signalled once it has.
    static func detach(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Self.detachNewThread {
            body()
            done.signal()
        }
        return done
    }
}
