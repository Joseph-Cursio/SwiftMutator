@testable import muterCore
import XCTest

extension MutatedProjectLockTests {
    func test_startTime_tellsAProcessFromALaterOne_andNoProcessIsNone() throws {
        let own = try XCTUnwrap(MutatedProjectLock.startTime(of: getpid()))
        XCTAssertEqual(MutatedProjectLock.startTime(of: getpid()), own)
        let child = try spawn("/bin/sleep", "30")
        defer {
            kill(child, SIGKILL)
            waitpid(child, nil, 0)
        }

        XCTAssertGreaterThan(try XCTUnwrap(MutatedProjectLock.startTime(of: child)), own)
        XCTAssertNil(MutatedProjectLock.startTime(of: 0))
        XCTAssertNil(MutatedProjectLock.startTime(of: -1))
    }

    // The holder can be another user's run, in a checkout shared through a group. Process 1, launchd or init, is
    // root's.
    func test_startTime_ofAnotherUsersProcess_canBeRead() {
        XCTAssertNotNil(MutatedProjectLock.startTime(of: 1))
    }

    func test_systemStartTime_isInThePast() throws {
        let started = try XCTUnwrap(MutatedProjectLock.systemStartTime())

        XCTAssertLessThan(started, Date().timeIntervalSince1970)
        XCTAssertGreaterThan(started, Date(timeIntervalSinceReferenceDate: 0).timeIntervalSince1970)
    }
}
