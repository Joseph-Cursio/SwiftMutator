import ArgumentParser
@testable import muterCore
import XCTest

final class MutantReferenceTests: XCTestCase {
    func test_parsesAFullKey() throws {
        XCTAssertEqual(
            try MutantReference.parse("Sources/Foo/Bar.swift:12:9 SwapTernary"),
            MutantReference(path: "Sources/Foo/Bar.swift", line: 12, column: 9, mutationOperatorId: .swapTernary)
        )
        XCTAssertEqual(
            try MutantReference.parse("Sources/Foo/Bar.swift:12:9 RelationalOperatorReplacement (#3)"),
            MutantReference(
                path: "Sources/Foo/Bar.swift",
                line: 12,
                column: 9,
                mutationOperatorId: .ror,
                occurrence: 2
            )
        )
    }

    func test_aKeysDescription_readsBackAsItWasPrinted_andNamesTheKey() throws {
        let keys = [
            key("Sources/Foo/Bar.swift", line: 12, column: 9),
            key("Sources/Foo/Bar.swift", line: 3, column: 14, mutationOperatorId: .ror, occurrence: 1),
            key("My Files/a:b.swift", line: 1, column: 1, mutationOperatorId: .removeSideEffects, occurrence: 4),
            key("/elsewhere/Gen.swift", line: 7, column: 2, mutationOperatorId: .logicalOperator),
        ]
        for key in keys {
            let reference = try MutantReference.parse(key.description)
            XCTAssertEqual(reference.description, key.description)
            XCTAssertTrue(reference.matches(key), key.description)
        }
    }

    func test_parsesThePlaceAlone_asTheProgressLinesAndTheReportGiveIt() throws {
        XCTAssertEqual(
            try MutantReference.parse("Bar.swift:12:9"),
            MutantReference(path: "Bar.swift", line: 12, column: 9)
        )
        XCTAssertEqual(try MutantReference.parse("Bar.swift:12"), MutantReference(path: "Bar.swift", line: 12))
        XCTAssertEqual(
            try MutantReference.parse("Bar.swift:12 SwapTernary"),
            MutantReference(path: "Bar.swift", line: 12, mutationOperatorId: .swapTernary)
        )
        XCTAssertEqual(
            try MutantReference.parse("  ./Sources/Bar.swift:12:9\n"),
            MutantReference(path: "Sources/Bar.swift", line: 12, column: 9)
        )
        XCTAssertEqual(try MutantReference.parse("Bar.swift:12:9").description, "Bar.swift:12:9")
        XCTAssertEqual(try MutantReference.parse("Bar.swift:12").description, "Bar.swift:12")
    }

    func test_aPath_mayHoldSpacesAndColons() throws {
        XCTAssertEqual(
            try MutantReference.parse("Sources/My Files/Bar.swift:12:9 SwapTernary"),
            MutantReference(path: "Sources/My Files/Bar.swift", line: 12, column: 9, mutationOperatorId: .swapTernary)
        )
        XCTAssertEqual(
            try MutantReference.parse("Sources/a:1:2/Bar.swift:12:9"),
            MutantReference(path: "Sources/a:1:2/Bar.swift", line: 12, column: 9)
        )
        XCTAssertEqual(
            try MutantReference.parse("Sources/My Files 2:3 Bar.swift:12"),
            MutantReference(path: "Sources/My Files 2:3 Bar.swift", line: 12)
        )
    }

    func test_anAbsolutePath_inTheProjectOrItsCopy_isMadeRelative() throws {
        let roots = [URL(fileURLWithPath: "/work/Foo"), URL(fileURLWithPath: "/work/Foo_mutated")]

        let inTheProject = try MutantReference.parse("/work/Foo/Sources/Bar.swift:12:9 SwapTernary")
        let inTheCopy = try MutantReference.parse("/work/Foo_mutated/Sources/Bar.swift:12:9 SwapTernary")
        let elsewhere = try MutantReference.parse("/elsewhere/Sources/Bar.swift:12:9")

        XCTAssertEqual(inTheProject.path, "/work/Foo/Sources/Bar.swift")
        XCTAssertEqual(
            inTheProject.relative(toFirstOf: roots),
            MutantReference(path: "Sources/Bar.swift", line: 12, column: 9, mutationOperatorId: .swapTernary)
        )
        XCTAssertEqual(inTheCopy.relative(toFirstOf: roots), inTheProject.relative(toFirstOf: roots))
        XCTAssertEqual(elsewhere.relative(toFirstOf: roots), elsewhere)
        XCTAssertEqual(
            MutantReference(path: "Sources/Bar.swift", line: 1).relative(toFirstOf: roots),
            MutantReference(path: "Sources/Bar.swift", line: 1)
        )
    }

    func test_refusesText_withoutAPlace() {
        let usage = "give the mutant as path:line[:column] [Operator], "
            + "such as 'Sources/Foo/Bar.swift:12:9 SwapTernary'."
        let refused = [
            "", "Bar.swift", "Bar.swift:", "Bar.swift:x", ":12", ":12:9", "./:12", "12", "Bar.swift:0",
            "Bar.swift:0:9", "Bar.swift:12:0", "Bar.swift:-1", "Bar.swift:12:9:", "Bar.swift:١٢",
            "Bar.swift:99999999999999999999", "Bar.swift:12 (#)", "Bar.swift:12 (#x)", "Bar.swift:12 swap-ternary",
            "Bar.swift:12:9 (swapped ternary operator)",
        ]
        for text in refused {
            XCTAssertThrowsError(try MutantReference.parse(text), text) { error in
                XCTAssertEqual((error as? ValidationError)?.message, usage, text)
            }
        }
    }

    func test_refusesTheFirstRepeat_whichHasNoNumber() {
        for text in ["Bar.swift:12:9 SwapTernary (#1)", "Bar.swift:12:9 (#0)"] {
            XCTAssertThrowsError(try MutantReference.parse(text), text) { error in
                XCTAssertEqual(
                    (error as? ValidationError)?.message,
                    "give a repeat as (#2) or above; the first mutant at a place has no (#n).",
                    text
                )
            }
        }
    }

    func test_anUnknownOperator_isRefusedWithTheOperators() {
        for text in ["Bar.swift:12:9 SwapTernery", "Bar.swift:12 swapTernary (#2)"] {
            XCTAssertThrowsError(try MutantReference.parse(text), text) { error in
                let word = text.contains("Ternery") ? "SwapTernery" : "swapTernary"
                XCTAssertEqual(
                    (error as? ValidationError)?.message,
                    "\(word) isn't an operator: give one of RelationalOperatorReplacement, RemoveSideEffects, "
                        + "ChangeLogicalConnector, SwapTernary.",
                    text
                )
            }
        }
    }

    func test_matchesAKey_byTheEndOfItsPath_onAWholeComponent() {
        let key = key("Sources/Foo/Bar.swift", line: 12, column: 9)

        for path in ["Sources/Foo/Bar.swift", "Foo/Bar.swift", "Bar.swift"] {
            XCTAssertTrue(MutantReference(path: path, line: 12).matches(key), path)
        }
        for path in ["ar.swift", "o/Bar.swift", "Foo", "Sources/Foo", "Other/Bar.swift", "Sources/Foo/Bar.swift/"] {
            XCTAssertFalse(MutantReference(path: path, line: 12).matches(key), path)
        }
    }

    func test_matchesAKey_onTheLine_andOnTheColumnOperatorAndRepeat_onlyWhenGiven() {
        let key = key("Sources/Bar.swift", line: 12, column: 9, mutationOperatorId: .ror, occurrence: 1)

        XCTAssertTrue(MutantReference(path: "Bar.swift", line: 12).matches(key))
        XCTAssertTrue(MutantReference(path: "Bar.swift", line: 12, column: 9).matches(key))
        XCTAssertTrue(MutantReference(path: "Bar.swift", line: 12, mutationOperatorId: .ror).matches(key))
        XCTAssertTrue(MutantReference(path: "Bar.swift", line: 12, occurrence: 1).matches(key))
        XCTAssertTrue(
            MutantReference(path: "Bar.swift", line: 12, column: 9, mutationOperatorId: .ror, occurrence: 1)
                .matches(key)
        )

        XCTAssertFalse(MutantReference(path: "Bar.swift", line: 13).matches(key))
        XCTAssertFalse(MutantReference(path: "Bar.swift", line: 9, column: 12).matches(key))
        XCTAssertFalse(MutantReference(path: "Bar.swift", line: 12, column: 10).matches(key))
        XCTAssertFalse(MutantReference(path: "Bar.swift", line: 12, mutationOperatorId: .swapTernary).matches(key))
        XCTAssertFalse(MutantReference(path: "Bar.swift", line: 12, occurrence: 0).matches(key))
        XCTAssertFalse(MutantReference(path: "Bar.swift", line: 12, occurrence: 2).matches(key))
    }

    func test_aFullKeysText_withoutARepeat_matchesEveryRepeatOfItsPlace() throws {
        let reference = try MutantReference.parse("Sources/Bar.swift:12:9 SwapTernary")

        XCTAssertTrue(reference.matches(key("Sources/Bar.swift", line: 12, column: 9, occurrence: 0)))
        XCTAssertTrue(reference.matches(key("Sources/Bar.swift", line: 12, column: 9, occurrence: 1)))
    }

    private func key(
        _ path: String,
        line: Int,
        column: Int,
        mutationOperatorId: MutationOperator.Id = .swapTernary,
        occurrence: Int = 0
    ) -> MutantKey {
        MutantKey(
            path: path,
            mutationOperatorId: mutationOperatorId,
            line: line,
            column: column,
            occurrence: occurrence
        )
    }
}
