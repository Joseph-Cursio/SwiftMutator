@testable import muterCore
import XCTest

final class LogLineBufferTests: XCTestCase {
    private let failedTestLine = "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed"

    func test_aLineIsReturnedOnlyOnceItsLineBreakArrives() {
        var buffer = LogLineBuffer()

        XCTAssertEqual(buffer.append(Data("✘ Test sum() recorded an is".utf8)), [])
        XCTAssertEqual(buffer.append(Data("sue at SumTests.swift:3:5: Expectation failed".utf8)), [])
        XCTAssertEqual(buffer.append(Data("\n".utf8)), [failedTestLine])
    }

    // ✘ is the three bytes E2 9C 98; decoded on its own, the first would become U+FFFD.
    func test_aCharacterSplitAcrossPieces_isDecodedWhole() {
        var buffer = LogLineBuffer()

        XCTAssertEqual(buffer.append(Data([0xE2])), [])
        let rest = Data(" Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed\n".utf8)
        XCTAssertEqual(buffer.append(Data([0x9C, 0x98]) + rest), [failedTestLine])
    }

    func test_severalLinesInOnePiece_areReturnedInOrder() {
        var buffer = LogLineBuffer()

        XCTAssertEqual(buffer.append(Data("first\n\nthird\nunfinished".utf8)), ["first", "", "third"])
        XCTAssertEqual(buffer.append(Data(" line\n".utf8)), ["unfinished line"])
    }

    // In Swift "\r\n" is one Character, so lines split from decoded text at "\n" alone would stay joined.
    func test_carriageReturnsAreDropped() {
        var buffer = LogLineBuffer()

        XCTAssertEqual(buffer.append(Data("first\r\n\(failedTestLine)\r\nthird\r".utf8)), ["first", failedTestLine])
        XCTAssertEqual(buffer.append(Data("\n".utf8)), ["third"])
    }

    func test_anOverlongUnfinishedLineIsDropped_andLaterLinesStillArrive() {
        var buffer = LogLineBuffer()
        let longOutput = Data(repeating: UInt8(ascii: "x"), count: LogLineBuffer.maximumPendingBytes)
        // Each line cut short, so a failure doesn't print a megabyte of output.
        func append(_ bytes: Data) -> [String] {
            buffer.append(bytes).map { String($0.prefix(100)) }
        }

        XCTAssertEqual(append(longOutput), [])
        XCTAssertEqual(append(Data("x".utf8)), [])
        XCTAssertEqual(append(longOutput), [])
        // The rest of the dropped line isn't at the start of a line, so it can't show a failed test.
        XCTAssertEqual(append(Data("\(failedTestLine)\nnext\n".utf8)), ["next"])
        XCTAssertEqual(append(Data("\(failedTestLine)\n".utf8)), [failedTestLine])
    }
}

/// These follow real files, which each test writes as a test command would.
final class TestLogFollowerTests: XCTestCase {
    private let pollInterval: TimeInterval = 0.005
    private var logFileUrl: URL!
    private var writer: FileHandle!

    override func setUpWithError() throws {
        try super.setUpWithError()
        logFileUrl = try URL(fileURLWithPath: makeTemporaryDirectory()).appendingPathComponent("test.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: logFileUrl.path, contents: nil))
        writer = try FileHandle(forWritingTo: logFileUrl)
    }

    override func tearDownWithError() throws {
        try writer?.close()
        try super.tearDownWithError()
    }

    func test_findsAFailedTestLineWrittenAfterItStarted() async throws {
        try write("◇ Test run started.\n✔ Test passes() passed after 0.001 seconds.\n")
        let following = follow()

        try await Task.sleep(nanoseconds: 50_000_000)
        try write("✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed\n✔ Test later() passed.\n")

        let line = await following.value
        XCTAssertEqual(line, "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed")
    }

    func test_findsALineWrittenInTwoPieces() async throws {
        let following = follow()

        try write("Test Case '-[BTests.BXCTests testIncrement]' fai")
        try await Task.sleep(nanoseconds: 50_000_000)
        try write("led (0.048 seconds).\n")

        let line = await following.value
        XCTAssertEqual(line, "Test Case '-[BTests.BXCTests testIncrement]' failed (0.048 seconds).")
    }

    func test_findsAFailedTestLineAfterMoreOutputThanOneRead() async throws {
        let passingLine = "✔ Test case passing 1 argument value → 1 to parameterized(value:) passed.\n"
        let passingLines = String(repeating: passingLine, count: 3 * TestLogFollower.readSize / passingLine.utf8.count)
        try write(passingLines + "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed\n")

        let line = await follow().value

        XCTAssertEqual(line, "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed")
    }

    func test_returnsTheLineWithoutColourCodes() async throws {
        let escape = "\u{1B}"
        try write("\(escape)[91m✘\(escape)[0m Test sum() recorded an issue at SumTests.swift:3:5: x\n")

        let line = await follow().value

        XCTAssertEqual(line, "✘ Test sum() recorded an issue at SumTests.swift:3:5: x")
    }

    func test_keepsWatchingPastKnownIssuesWarningsAndPasses_untilCancelled() async throws {
        let lines = [
            "━ Test knownIssue() recorded a known issue at ATests.swift:34:13: Expectation failed: 1 == 2",
            "⚠︎ Test recordsWarning() recorded a warning at CTests.swift:35:21: Issue recorded",
            "✔ Test passes() passed after 0.001 seconds.",
            "Test Case '-[BTests.BXCTests testIncrement]' passed (0.001 seconds).",
        ]
        try write(lines.map { "\($0)\n" }.joined())
        let started = Date()

        let line = await follow(cancellingAfter: 0.3).value

        XCTAssertNil(line)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.3, "it stopped watching before it was cancelled")
        XCTAssertLessThan(elapsed, 3, "it kept watching after it was cancelled")
    }

    func test_returnsNilWhenTheLogCannotBeOpened() async {
        let missingLog = logFileUrl.deletingLastPathComponent().appendingPathComponent("missing.log")
        let started = Date()

        let line = await follow(missingLog).value

        XCTAssertNil(line)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "it gave up only when cancelled")
    }

    // MARK: - Helpers

    private func write(_ text: String) throws {
        try writer.write(contentsOf: Data(text.utf8))
    }

    /// Follows the log at `url`, this test's unless given, and cancels the follower after `timeout` seconds,
    /// so a follower that never finds its line fails a test instead of hanging it.
    private func follow(_ url: URL? = nil, cancellingAfter timeout: TimeInterval = 5) -> Following {
        let follower = TestLogFollower(logFileUrl: url ?? logFileUrl, pollInterval: pollInterval)
        let returned = XCTestExpectation(description: "the follower returned")
        let following = Task {
            let line = await follower.firstFailedTestLine()
            returned.fulfill()
            return line
        }
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            following.cancel()
        }
        addTeardownBlock {
            following.cancel()
            deadline.cancel()
        }
        return Following(task: following, returned: returned, waitLimit: timeout + 5)
    }

    /// A follower `follow` started.
    private struct Following {
        let task: Task<String?, Never>
        let returned: XCTestExpectation
        let waitLimit: TimeInterval

        /// What the follower returned. Waits at most `waitLimit` seconds, as cancelling the follower ends it
        /// only if it checks for cancellation: one that doesn't fails the test instead of hanging it.
        var value: String? {
            get async {
                guard await XCTWaiter().fulfillment(of: [returned], timeout: waitLimit) == .completed else {
                    XCTFail("the follower ignored its cancellation")
                    return nil
                }
                return await task.value
            }
        }
    }
}
