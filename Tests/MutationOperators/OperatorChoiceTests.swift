@testable import muterCore
import XCTest

final class OperatorChoiceTests: XCTestCase {
    private func options(
        named: MutationOperatorList? = nil,
        skipping: MutationOperatorList? = nil,
        testPlan: URL? = nil,
        mutant: MutantReference? = nil
    ) -> Run.Options {
        Run.Options(
            skipCoverage: false,
            skipUpdateCheck: false,
            configurationURL: nil,
            mutationOperatorsList: named ?? .allOperators,
            operatorsAreNamed: named != nil,
            skipOperators: skipping,
            testPlanURL: testPlan,
            mutant: mutant
        )
    }

    func test_withoutKeysOrSkips_theCommandLineStands() throws {
        XCTAssertNil(try options().chosenOperators(given: MuterConfiguration()))
        XCTAssertNil(try options(named: [.ror]).chosenOperators(given: MuterConfiguration()))
    }

    func test_theOperatorsKey_replacesTheDefault() throws {
        let configuration = MuterConfiguration(operators: [.swapTernary, .ror])

        XCTAssertEqual(try options().chosenOperators(given: configuration), [.swapTernary, .ror])
    }

    func test_theSkipOperatorsKey_leavesOperatorsOutOfAllOfThem() throws {
        let configuration = MuterConfiguration(skipOperators: [.swapTernary, .removeSideEffects])

        XCTAssertEqual(
            try options().chosenOperators(given: configuration),
            [
                .ror,
                .relationalBoundary,
                .logicalOperator,
                .negateConditional,
                .arithmeticOperator,
                .flipBooleanLiteral,
                .replaceBooleanValue,
                .replaceReturnValue,
            ]
        )
    }

    func test_bothKeys_leaveOperatorsOutOfTheList() throws {
        let configuration = MuterConfiguration(operators: [.swapTernary, .ror], skipOperators: [.ror, .logicalOperator])

        XCTAssertEqual(try options().chosenOperators(given: configuration), [.swapTernary])
    }

    func test_namedOperators_winOverBothKeys() throws {
        let configuration = MuterConfiguration(operators: [.ror], skipOperators: [.swapTernary])

        XCTAssertNil(try options(named: [.swapTernary]).chosenOperators(given: configuration))
    }

    func test_skipOperatorsOption_replacesItsKey_andLeavesOutOfTheOperatorsKey() throws {
        let configuration = MuterConfiguration(operators: [.swapTernary, .ror], skipOperators: [.swapTernary])

        XCTAssertEqual(try options(skipping: [.ror]).chosenOperators(given: configuration), [.swapTernary])
    }

    func test_bothOptions_leaveOperatorsOutOfThoseNamed() throws {
        XCTAssertEqual(
            try options(named: [.swapTernary, .ror], skipping: [.ror]).chosenOperators(given: MuterConfiguration()),
            [.swapTernary]
        )
    }

    func test_anOperatorListedTwice_isUsedOnce() throws {
        let configuration = MuterConfiguration(operators: [.ror, .swapTernary, .ror])

        XCTAssertEqual(try options().chosenOperators(given: configuration), [.ror, .swapTernary])
    }

    func test_leavingEveryOperatorOut_isRefused() {
        let cases: [(Run.Options, MuterConfiguration)] = [
            (options(), MuterConfiguration(skipOperators: .allOperators)),
            (options(), MuterConfiguration(operators: [.ror], skipOperators: [.ror])),
            (options(skipping: .allOperators), MuterConfiguration()),
            (options(named: [.ror], skipping: [.ror]), MuterConfiguration()),
        ]
        for (options, configuration) in cases {
            XCTAssertThrowsError(try options.chosenOperators(given: configuration)) { error in
                XCTAssertTrue("\(error)".contains("Every operator is left out"), "\(error)")
            }
        }
    }

    // A plan's own operators stand for its run, and --mutant looks for its mutant among them all.
    func test_aTestPlanAndAOneMutantRun_lookAtNoKeys() {
        let configuration = MuterConfiguration(operators: [.ror], skipOperators: [.ror])

        XCTAssertNoThrow(XCTAssertNil(
            try options(testPlan: URL(fileURLWithPath: "/plan.json")).chosenOperators(given: configuration)
        ))
        XCTAssertNoThrow(XCTAssertNil(
            try options(mutant: MutantReference(path: "Bar.swift", line: 12)).chosenOperators(given: configuration)
        ))
    }
}
