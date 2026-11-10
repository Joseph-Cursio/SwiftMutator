@testable import muterCore
import XCTest

extension BuildConditionsTests {
    func test_aConditionEveryTargetSets_holds() {
        let conditions = conditions(custom: [["DEBUG"], ["DEBUG", "OTHER"]])

        XCTAssertEqual(holds("DEBUG", in: conditions), .holds)
    }

    func test_aConditionNoTargetSets_doesntHold() {
        let conditions = conditions(custom: [["DEBUG"]])

        XCTAssertEqual(holds("NOBODY", in: conditions), .doesntHold)
    }

    func test_aConditionOnlySomeTargetsSet_isUndecided() {
        let conditions = conditions(custom: [["DEBUG"], ["DEBUG", "OTHER"]])

        XCTAssertEqual(holds("OTHER", in: conditions), .undecided)
    }

    func test_aConditionSomethingElseMightSet_isUndecided() {
        var conditions = conditions(custom: [["DEBUG"]])
        conditions.undecidedConditions = ["MENTIONED"]

        XCTAssertEqual(holds("MENTIONED", in: conditions), .undecided)
    }

    // A condition every reported target sets is what the build uses, whatever a build file also says.
    func test_aConditionEveryTargetSets_holdsEvenIfABuildFileMentionsIt() {
        var conditions = conditions(custom: [["DEBUG"]])
        conditions.undecidedConditions = ["DEBUG"]

        XCTAssertEqual(holds("DEBUG", in: conditions), .holds)
    }

    // Xcode sets `SWIFT_PACKAGE` for a local package's code, and SwiftPM others for targets with resources.
    func test_aBuildSystemsOwnCondition_isUndecided_unlessEveryTargetSetsIt() {
        XCTAssertEqual(holds("SWIFT_PACKAGE", in: conditions(custom: [["DEBUG"]])), .undecided)
        XCTAssertEqual(holds("SWIFT_MODULE_RESOURCE_BUNDLE_AVAILABLE", in: conditions(custom: [["DEBUG"]])), .undecided)
        XCTAssertEqual(holds("SWIFT_PACKAGE", in: conditions(custom: [["SWIFT_PACKAGE"]])), .holds)
    }

    func test_withNoTargets_noConditionIsDecided() {
        XCTAssertEqual(holds("DEBUG", in: conditions(custom: [])), .undecided)
    }
}
