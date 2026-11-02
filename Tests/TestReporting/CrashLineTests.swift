@testable import muterCore
import XCTest

final class CrashLineTests: XCTestCase {
    private let escape = "\u{1B}"

    func test_swiftPMsLinesForATestProcessEndedByACrashsSignal_match() {
        let lines = [
            // Swift Testing's helper, as `swift test` and `DirectTestRun`'s script report it.
            "error: Process '/usr/libexec/swift/pm/swiftpm-testing-helper --test-bundle-path "
                + "/p/Debug/BTests.xctest/Contents/MacOS/BTests /p/Debug/BTests.xctest/Contents/MacOS/BTests "
                + "--testing-library swift-testing' exited with unexpected signal code 5",
            "error: Process '/Applications/Xcode.app/Contents/Developer/usr/bin/xctest /p/CTests.xctest' "
                + "exited with unexpected signal code 11",
            "error: Process '/p/.build/out/Products/Debug-linux/CoreTests-test-runner' "
                + "exited with unexpected signal code 4",
            // Older SwiftPM.
            "\(escape)[1;31merror: \(escape)[0mExited with signal code 11",
            "Exited with signal code 4",
            "error: Process '/p/Tests.xctest' exited with unexpected signal code 10",
        ]

        for line in lines {
            XCTAssertTrue(CrashLine.matches(line), line)
        }
    }

    // SIGKILL is stopping a run's own; SIGHUP, SIGINT and SIGTERM stop a process from outside rather than crash it.
    // A `Fatal error:` line can be printed by a process that exits 0, and its signal line follows when it dies.
    // A line that only mentions a crash, as a test may print, doesn't start with SwiftPM's.
    func test_otherLines_dontMatch() {
        let lines = [
            "error: Process '/p/Tests.xctest' exited with unexpected signal code 9",
            "error: Process '/p/Tests.xctest' exited with unexpected signal code 1",
            "error: Process '/p/Tests.xctest' exited with unexpected signal code 2",
            "error: Process '/p/Tests.xctest' exited with unexpected signal code 15",
            "Sample/Sample.swift:12: Fatal error: Index out of range",
            "✔ Test reportsCrashes() passed: error: Process 'x' exited with unexpected signal code 5",
            "  error: Process '/p/Tests.xctest' exited with unexpected signal code 5",
            "error: a test process ended with an unknown signal code",
        ]

        for line in lines {
            XCTAssertFalse(CrashLine.matches(line), line)
        }
    }

    func test_first_givesTheFirstCrashLine_withoutColourCodes() {
        let log = """
            ✔ Test run with 2 tests in 1 suite passed after 0.1 seconds.
            \(escape)[1;31merror: \(escape)[0mExited with signal code 11
            error: Process '/p/Tests.xctest' exited with unexpected signal code 5
            """

        XCTAssertEqual(CrashLine.first(inLog: log), "error: Exited with signal code 11")
        XCTAssertNil(CrashLine.first(inLog: "✔ Test run with 2 tests in 1 suite passed after 0.1 seconds."))
    }
}
