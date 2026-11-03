@testable import muterCore
import XCTest

final class ParallelTestingSpreadTests: XCTestCase {
    func test_theClones_areTheDifferentNumbers_ofPassedFailedAndSkippedTests() {
        let log = """
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (123)' (0.010 seconds)
        Test case 'SumTests.difference()' failed on 'Clone 2 of iPhone 17 Pro - App (124)' (0.020 seconds)
        Test case 'SumTests.product()' skipped on 'Clone 3 of iPhone 17 Pro - App (125)' (0.000 seconds)
        Test case 'SumTests.quotient()' passed on 'Clone 1 of iPhone 17 Pro - App (126)' (1.500 seconds)
        """

        let spread = ParallelTestingSpread.of(baselineLog: log)

        XCTAssertEqual(spread?.clones, 3)
        XCTAssertEqual(spread?.testSeconds ?? 0, 1.53, accuracy: 0.0001)
    }

    // Each test class's process on a clone has an ID of its own, which says nothing of the clone.
    func test_oneClone_withSeveralProcesses_countsOnce() {
        let log = """
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (123)' (2.000 seconds)
        Test case 'ParserTests.parse()' passed on 'Clone 1 of iPhone 17 Pro - App (456)' (3.000 seconds)
        """

        XCTAssertEqual(ParallelTestingSpread.of(baselineLog: log), ParallelTestingSpread(clones: 1, testSeconds: 5))
    }

    func test_aLineWithoutItsSeconds_countsNone() {
        let log = "Test case 'SumTests.sum()' passed on 'Clone 2 of iPhone 17 Pro - App (123)'\r\n"
            + "Test case 'SumTests.difference()' passed on 'Clone 1 of iPhone 17 Pro - App (124)' (4.25 seconds)\r\n"

        XCTAssertEqual(ParallelTestingSpread.of(baselineLog: log), ParallelTestingSpread(clones: 2, testSeconds: 4.25))
    }

    // Each destination numbers its own clones, and a mutant's run tests only on the first.
    func test_severalDestinations_countOnlyTheNamedDevice_orElseTheFirstTheLogShows() {
        let log = """
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPad Air - App (201)' (30.000 seconds)
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (101)' (4.000 seconds)
        Test case 'ParserTests.parse()' passed on 'Clone 2 of iPhone 17 Pro - App (102)' (4.000 seconds)
        Test case 'ParserTests.parse()' passed on 'Clone 2 of iPad Air - App (202)' (6.000 seconds)
        Test case 'MapTests.map()' failed on 'Clone 3 of iPad Air - App (203)' (1.000 seconds)
        """

        XCTAssertEqual(
            ParallelTestingSpread.of(baselineLog: log, onDeviceNamed: "iPhone 17 Pro"),
            ParallelTestingSpread(clones: 2, testSeconds: 8)
        )
        XCTAssertEqual(
            ParallelTestingSpread.of(baselineLog: log, onDeviceNamed: "iPad Air"),
            ParallelTestingSpread(clones: 3, testSeconds: 37)
        )
        XCTAssertEqual(ParallelTestingSpread.of(baselineLog: log), ParallelTestingSpread(clones: 3, testSeconds: 37))
        XCTAssertEqual(
            ParallelTestingSpread.of(baselineLog: log, onDeviceNamed: "iPhone 16"),
            ParallelTestingSpread(clones: 3, testSeconds: 37)
        )
    }

    // A name that begins another device's names only its own device.
    func test_aNamedDevice_isNotTakenForOneWhoseNameItBegins() {
        let log = """
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro Max - App (101)' (20.000 seconds)
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (201)' (2.000 seconds)
        """

        XCTAssertEqual(
            ParallelTestingSpread.of(baselineLog: log, onDeviceNamed: "iPhone 17 Pro"),
            ParallelTestingSpread(clones: 1, testSeconds: 2)
        )
    }

    // Tests run one at a time print XCTest's own lines, and the lines that say where testing started name no test.
    func test_aLogWithoutALineForATestOnAClone_hasNoSpread() {
        let serial = """
        Test Suite 'SumTests' started at 2026-11-03 10:00:00.000.
        Test Case '-[AppTests.SumTests testSum]' passed (0.01 seconds).
        Test Case 'SumTests.sum()' passed (0.01 seconds).
        Testing started on 'Clone 1 of iPhone 17 Pro'
        Testing started on 'iPhone 17 Pro'
        ** TEST SUCCEEDED **
        """

        XCTAssertNil(ParallelTestingSpread.of(baselineLog: serial))
        XCTAssertNil(ParallelTestingSpread.of(baselineLog: ""))
    }
}
