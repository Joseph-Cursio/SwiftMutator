@testable import muterCore
import TestingExtensions

extension SwapTernaryOperatorTests {
    func test_identicalBranches_getNoMutant() throws {
        let mutations = try swappedMutations(of: """
        func pick(_ c: Bool, _ x: Int) -> Int {
            return c ? x : x
        }
        """)

        XCTAssertEqual(mutations, [])
    }

    // The tokens are what's compared: the spacing of the two branches, or a comment in them, is no difference.
    func test_identicalBranches_areFoundWhateverTheirSpacing() throws {
        let mutations = try swappedMutations(of: """
        func pick(_ c: Bool, _ x: Int) -> Int {
            let first = c ? x + 1 : x  +  1
            let second = c
                ? f(x) /* one */
                : f(
                    x
                )
            return first + second
        }
        """)

        XCTAssertEqual(mutations, [])
    }

    func test_identicalBranchesAtALaterLink_leaveTheOtherLinksTheirMutants() throws {
        let schemata = try swappedSchemata(of: """
        func pick(_ a: Bool, _ b: Bool) -> Int {
            return a ? 1 : b ? 2 : 2
        }
        """)

        XCTAssertEqual(schemata.map(\.snapshot.before), ["a ? 1 : b ? 2 : 2"])
    }

    // The compiler doesn't take the two spellings of `é` for one name, though `String`'s `==` does.
    func test_branchesThatDifferInTheirBytes_getAMutant() throws {
        let mutations = try swappedMutations(of: "func pick(_ c: Bool) -> Int {\n    return c ? \u{e9} : e\u{301}\n}")

        XCTAssertEqual(mutations.count, 1)
    }

    func test_branchesThatDifferInTheirTokens_getAMutant() throws {
        let mutations = try swappedMutations(of: """
        func pick(_ c: Bool, _ x: Int) -> Int {
            return c ? x : x + 1
        }
        """)

        XCTAssertEqual(mutations, ["return c ? x + 1 : x"])
    }
}
