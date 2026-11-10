@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

extension SwapTernaryOperatorTests {
    // The first link's swap moves the rest of the chain whole, so only a link's own swap tests `b ? 2 : 3`.
    func test_eachLinkOfAChain_getsItsOwnMutant() throws {
        let mutations = try swappedMutations(of: """
        func pick(_ a: Bool, _ b: Bool, _ c: Bool) -> Int {
            return a ? 1 : b ? 2 : c ? 3 : 4
        }
        """)

        XCTAssertEqual(Set(mutations), [
            "return a ? b ? 2 : c ? 3 : 4 : 1",
            "return a ? 1 : b ? c ? 3 : 4 : 2",
            "return a ? 1 : b ? 2 : c ? 4 : 3",
        ])
    }

    func test_aLaterLink_namesItsOwnCode_andHasAPlaceOfItsOwn() throws {
        let schemata = try swappedSchemata(of: """
        func pick(_ a: Bool, _ b: Bool) -> Int {
            return a ? 1 : b ? 2 : 3
        }
        """)

        XCTAssertEqual(Set(schemata.map(\.snapshot.before)), ["a ? 1 : b ? 2 : 3", "b ? 2 : 3"])
        XCTAssertEqual(
            Set(schemata.map { collapsingWhitespace($0.snapshot.after) }),
            ["a ? b ? 2 : 3 : 1", "b ? 3 : 2"]
        )
        XCTAssertEqual(Set(schemata.map(\.position.utf8Offset)).count, 2)
    }

    func test_aLaterLink_isPlacedAtItsQuestionMark_onItsOwnLine() throws {
        let schemata = try swappedSchemata(of: """
        func pick(_ a: Bool, _ b: Bool) -> Int {
            return a ? 1
                : b ? 2
                : 3
        }
        """)

        let laterLink = try XCTUnwrap(schemata.first { $0.snapshot.before == "b ? 2\n        : 3".inlined })
        XCTAssertEqual(laterLink.position.line, 3)
        XCTAssertEqual(laterLink.position.column, 13)
    }

    // What's before an assignment is no part of the link after it.
    func test_aLinkAfterAnAssignment_startsAfterIt_andTheLinkBeforeItIsLeftAlone() throws {
        let schemata = try swappedSchemata(of: """
        func pick(_ p: Bool, _ s: Bool) {
            p ? q : r = s ? t : u
        }
        """)

        XCTAssertEqual(schemata.map(\.snapshot.before), ["s ? t : u"])
        XCTAssertEqual(schemata.map { collapsingWhitespace($0.snapshot.after) }, ["s ? u : t"])
    }

    func test_aListWithACast_isStillLeftAlone_atEveryLink() throws {
        let mutations = try swappedMutations(of: """
        func pick(_ a: Bool, _ b: Bool) -> Int? {
            return a ? 1 : b ? 2 : 3 as Int?
        }
        """)

        XCTAssertEqual(mutations, [])
    }

    // A later link is in a branch of the one before it. Its mutant could only survive if that branch never ran.
    func test_aLaterLinkInABranchThatNeverRan_getsNoMutant() throws {
        let source = try sourceCode("""
        func pick(_ a: Bool, _ b: Bool) -> Int {
            return a
                ? 1
                : b ? 2 : 3
        }
        """)
        let visitor = SwapTernaryOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([[[1, 40, 5, 2, 1], [3, 11, 3, 12, 1], [4, 11, 4, 20, 0]]])
        )

        visitor.walk(source)

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.snapshot.before), ["a ? 1 : b ? 2 : 3"])
    }

    func test_aDisableCommentBeforeALaterLink_leavesThatLinkAlone() throws {
        let schemata = try swappedSchemata(of: """
        func pick(_ a: Bool, _ b: Bool) -> Int {
            return a ? 1
                // muter:disable
                : b ? 2 : 3
        }
        """)

        XCTAssertEqual(schemata.count, 1)
        XCTAssertTrue(schemata[0].snapshot.before.hasPrefix("a ? 1"))
    }

    // The comment is right before this link's `?`, so it's read only if the visit reads it before adding the mutant.
    func test_aDisableCommentRightBeforeALaterLinksQuestionMark_leavesThatLinkAlone() throws {
        let schemata = try swappedSchemata(of: """
        func pick(_ a: Bool, _ b: Bool) -> Int {
            return a ? 1 : b
                // muter:disable
                ? 2 : 3
        }
        """)

        XCTAssertEqual(schemata.count, 1)
        XCTAssertTrue(schemata[0].snapshot.before.hasPrefix("a ? 1"))
    }

    // An assignment at the end of the list would take the whole ternary as its left side.
    func test_aThenBranchThatAssigns_isParenthesizedAtEveryLink() throws {
        let mutations = try swappedMutations(of: """
        func pick(_ a: Bool, _ b: Bool) {
            a ? x = 1 : b ? n += 1 : run()
        }
        """)

        XCTAssertEqual(Set(mutations), [
            "a ? b ? n += 1 : run() : (x = 1)",
            "a ? x = 1 : b ? run() : (n += 1)",
        ])
    }

    // Comparisons that end in `=`, unlike an assignment, are part of the branch.
    func test_comparisonsThatEndInAnEqualsSign_areNoAssignments() throws {
        let schemata = try swappedSchemata(of: """
        func pick(_ a: Bool, _ n: Int) -> Int {
            return a ? 0 : 1...5 ~= n ? 1 : 2
        }
        """)

        XCTAssertEqual(Set(schemata.map(\.snapshot.before)), ["a ? 0 : 1...5 ~= n ? 1 : 2", "1...5 ~= n ? 1 : 2"])
    }

    // `--changed-lines` reads this: an edit to any line of the chain may change what a link does.
    func test_aLaterLink_spansTheWholeChainsLines() throws {
        let schemata = try swappedSchemata(of: """
        func pick(_ a: Bool, _ b: Bool) -> Int {
            return a ? 1
                : b ? 2
                : 3
        }
        """)

        XCTAssertEqual(schemata.map(\.lines), [2...4, 2...4])
    }

    // Since a value can hold a switch, a chain outside a function gets a mutant for each link there too.
    func test_eachLinkOfAChainInAStoredProperty_getsItsOwnMutant() throws {
        let schemata = try swappedSchemata(of: """
        struct S {
            let value = a ? 1 : b ? 2 : 3
        }
        """)

        XCTAssertEqual(
            Set(schemata.map { collapsingWhitespace($0.snapshot.after) }),
            ["a ? b ? 2 : 3 : 1", "b ? 3 : 2"]
        )
    }
}
