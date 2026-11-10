@testable import muterCore
import TestingExtensions
import XCTest

/// The base of the suites that run code against `current`: each test gets fresh doubles in a world of their own.
class MuterTestCase: XCTestCase { // swiftlint:disable:this final_test_case - the suites' base, with no tests itself
    // swiftlint:disable:next test_case_accessibility - the suites reach their doubles through it
    let doubles = TestDoubles()

    // The operators `generateSchemataMappings` discovers with.
    // swiftlint:disable:next test_case_accessibility - a suite overrides it to discover with fewer operators
    var operatorsToDiscoverWith: MutationOperatorList {
        .allOperators
    }

    override func setUp() {
        super.setUp()

        current = doubles.world
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        current = doubles.world
    }

    /// Puts the real world back, so that nothing running after the test sees its doubles.
    override func tearDown() {
        current = World()
        super.tearDown()
    }
}
