import XCTest

extension TestPlanAcceptanceTests {
    /// That a one-mutant run printed the mutant's block: where it is and its switch, its change, the failed test's
    /// line, its verdict, and the mutated project it kept.
    func assertTheOneMutantBlock(in printed: String) {
        XCTAssertTrue(
            printed.contains(
                """
                🔬 Sources/Lib/Checks.swift:1:65 RelationalOperatorReplacement (changed != to ==)
                Switch: Checks_
                """
            ),
            printed
        )
        XCTAssertTrue(
            printed.contains(
                """
                Change:
                  -1: func isPositive(_ values: [Int]) -> Bool { values.contains { $0 != 0 } }
                  +1: func isPositive(_ values: [Int]) -> Bool { values.contains { $0 == 0 } }
                Tests (log:
                """
            ),
            printed
        )
        XCTAssertTrue(
            printed.contains("  ✘ Test check() recorded an issue at ChecksTests.swift:3:5: Expectation failed\n"),
            printed
        )
        XCTAssertTrue(printed.contains("Verdict: killed by check() (1 failed test), in "), printed)
        XCTAssertTrue(printed.contains("/project_mutated.noindex\nTo run its tests with it on:\n"), printed)
    }
}
