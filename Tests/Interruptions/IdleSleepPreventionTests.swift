@testable import muterCore
import XCTest

private final class Counts: @unchecked Sendable { // `held` and `released` are behind `lock`
    private let lock = NSLock()
    private var heldCount = 0
    private var releasedCount = 0

    var held: Int { lock.withLock { heldCount } }
    var released: Int { lock.withLock { releasedCount } }

    func add(held: Int = 0, released: Int = 0) {
        lock.withLock {
            heldCount += held
            releasedCount += released
        }
    }
}

final class IdleSleepPreventionTests: XCTestCase {
    func test_beginningTwice_holdsOnce_andEndingTwice_releasesOnce() {
        let counts = Counts()
        let prevention = IdleSleepPrevention {
            counts.add(held: 1)
            return { counts.add(released: 1) }
        }

        prevention.begin()
        prevention.begin()
        XCTAssertEqual(counts.held, 1)
        XCTAssertEqual(counts.released, 0)

        prevention.end()
        prevention.end()
        XCTAssertEqual(counts.released, 1)

        prevention.begin()
        XCTAssertEqual(counts.held, 2)
        prevention.end()
    }

    func test_endingWithoutBeginning_doesNothing() {
        let counts = Counts()
        let prevention = IdleSleepPrevention {
            counts.add(held: 1)
            return { counts.add(released: 1) }
        }

        prevention.end()

        XCTAssertEqual(counts.held, 0)
        XCTAssertEqual(counts.released, 0)
    }

    #if os(macOS)
    // What the system says this process holds, as the point of the option chosen is the assertion it makes:
    // `PreventUserIdleSystemSleep`, which also holds on battery, unlike the `PreventSystemSleep` of `caffeinate -s`.
    func test_onAMac_theSystemListsTheAssertion_untilItEnds() throws {
        let prevention = IdleSleepPrevention()
        XCTAssertEqual(try assertionsOfThisProcess(), [])

        prevention.begin()
        defer { prevention.end() }
        let held = try assertionsOfThisProcess()
        XCTAssertEqual(held.count, 1, "\(held)")
        XCTAssertEqual(held.first?.contains("PreventUserIdleSystemSleep"), true, "\(held)")

        prevention.end()
        XCTAssertEqual(try assertionsOfThisProcess(), [])
    }

    /// The lines of `pmset -g assertions` that name this process and `IdleSleepPrevention.reason`.
    private func assertionsOfThisProcess() throws -> [String] {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["-g", "assertions"]
        let output = Pipe()
        pmset.standardOutput = output
        try pmset.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        pmset.waitUntilExit()
        let pid = "pid \(ProcessInfo.processInfo.processIdentifier)("
        return String(lossyUTF8: data)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(pid) && $0.contains(IdleSleepPrevention.reason) }
    }
    #endif
}
