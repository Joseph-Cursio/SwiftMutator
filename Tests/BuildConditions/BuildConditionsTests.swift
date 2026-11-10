import XCTest

final class BuildConditionsTests: XCTestCase {
    // MARK: Which clauses

    func test_ofAnIfsClauses_onlyTheOneThatHoldsCompiles() {
        let inactive = inactiveCode("""
        #if os(iOS)
        iOS()
        #elseif os(macOS)
        macOS()
        #elseif os(Linux)
        linux()
        #else
        other()
        #endif
        """)

        XCTAssertEqual(inactive, ["iOS()", "linux()", "other()"])
    }

    func test_whenNoConditionHolds_theElseCompiles() {
        let inactive = inactiveCode("""
        #if os(iOS)
        iOS()
        #else
        other()
        #endif
        """)

        XCTAssertEqual(inactive, ["iOS()"])
    }

    func test_undecidedCode_isKept_withTheElseAfterIt() {
        let inactive = inactiveCode("""
        #if canImport(SomePackage)
        package()
        #else
        other()
        #endif
        """)

        XCTAssertEqual(inactive, [])
    }

    // `SwiftIfConfig` gives false for a condition it can't evaluate, and `!` makes that true.
    func test_aNegatedUndecidedCondition_isUndecided() {
        let inactive = inactiveCode("""
        #if !canImport(SomePackage)
        other()
        #else
        package()
        #endif
        """)

        XCTAssertEqual(inactive, [])
    }

    // Whichever clause compiles, it isn't one after a condition that holds.
    func test_afterAnUndecidedClause_aConditionThatHolds_stillRulesOutTheClausesAfterIt() {
        let inactive = inactiveCode("""
        #if canImport(SomePackage)
        package()
        #elseif os(macOS)
        macOS()
        #else
        other()
        #endif
        """)

        XCTAssertEqual(inactive, ["other()"])
    }

    func test_afterAnUndecidedClause_aConditionThatDoesntHold_isInactive_andTheElseIsKept() {
        let inactive = inactiveCode("""
        #if canImport(SomePackage)
        package()
        #elseif os(iOS)
        iOS()
        #else
        other()
        #endif
        """)

        XCTAssertEqual(inactive, ["iOS()"])
    }

    func test_afterAClauseThatHolds_anUndecidedCondition_isInactive() {
        let inactive = inactiveCode("""
        #if os(macOS)
        macOS()
        #elseif canImport(SomePackage)
        package()
        #else
        other()
        #endif
        """)

        XCTAssertEqual(inactive, ["package()", "other()"])
    }

    func test_inAnActiveOrUndecidedClause_aNestedIfIsDecided() {
        let inactive = inactiveCode("""
        #if canImport(SomePackage)
        #if os(iOS)
        iOS()
        #else
        other()
        #endif
        #endif
        """)

        XCTAssertEqual(inactive, ["iOS()"])
    }

    func test_inAnInactiveClause_aNestedIfGivesNoRegionOfItsOwn() {
        let regions = regions(
            in: """
            #if os(iOS)
            #if os(macOS)
            never()
            #endif
            iOS()
            #endif
            """
        )

        XCTAssertEqual(regions.count, 1)
    }

    func test_wholeDeclarations_membersAndPostfixExpressions_areFound() {
        let inactive = inactiveCode("""
        #if os(iOS)
        func f() {}
        #endif
        struct S {
            #if os(iOS)
            var m = 1
            #endif
        }
        let v = view
            #if os(iOS)
            .modifier()
            #endif
        """)

        XCTAssertEqual(inactive, ["func f() {}", "var m = 1", ".modifier()"])
    }

    func test_aFileWithNoIf_hasNoInactiveCode() {
        XCTAssertEqual(inactiveCode("let a = 1"), [])
    }
}
