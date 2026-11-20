@testable import muterCore
import XCTest

extension MutantDiffTests {
    // A `??` term is placed where it starts, so the diff takes the fallback in its place on the term's line.
    func test_aReplacedCoalescing_givesItsLine() throws {
        let source = """
        func f() -> Int {
            return cached ?? load()
        }

        """
        let schemata = schemata(MutationOperator.Id.replaceNilCoalescing.visitor, in: source)

        XCTAssertEqual(schemata.map { diff(of: $0, in: source) }, [
            ["-2:     return cached ?? load()", "+2:     return load()"],
        ])
    }

    // A chain's inner link starts at its own left side, after the outer link's.
    func test_eachLinkOfACoalescingChain_givesItsLine() throws {
        let source = """
        func f() -> Int {
            return a ?? b ?? c
        }

        """
        let schemata = schemata(MutationOperator.Id.replaceNilCoalescing.visitor, in: source)

        XCTAssertEqual(schemata.map { diff(of: $0, in: source) }, [
            ["-2:     return a ?? b ?? c", "+2:     return b ?? c"],
            ["-2:     return a ?? b ?? c", "+2:     return a ?? c"],
        ])
    }

    // The diff shows the code the mutant makes: a space keeps a fallback off a name it would touch, and parentheses
    // keep it off an operator it would join, as `=-` or `=.` would be one.
    func test_aCoalescingWithoutSpaces_givesItsLine_asTheMutantMakesIt() throws {
        let table: [(code: String, expected: [String])] = [
            ("return(a) ?? b", ["-2:     return(a) ?? b", "+2:     return b"]),
            ("return(a) ?? (b)", ["-2:     return(a) ?? (b)", "+2:     return(b)"]),
            ("x=a ?? -1", ["-2:     x=a ?? -1", "+2:     x=(-1)"]),
            ("x=a ?? .low", ["-2:     x=a ?? .low", "+2:     x=(.low)"]),
        ]
        for (code, expected) in table {
            let source = """
            func f() -> Int {
                \(code)
            }

            """
            let schemata = schemata(MutationOperator.Id.replaceNilCoalescing.visitor, in: source)

            XCTAssertEqual(schemata.map { diff(of: $0, in: source) }, [expected], code)
        }
    }

    // A term over several lines isn't found at its place, as the snapshot gives it on one line, and its mutant is
    // placed where it starts, so the same code on a line above is another's.
    func test_aCoalescingOverSeveralLines_isntTakenForACopyAbove() throws {
        let source = """
        func f(_ a: Int?, _ b: Int) -> Int {
            print(a ?? b)
            return a
                ?? b
        }

        """
        let schemata = schemata(MutationOperator.Id.replaceNilCoalescing.visitor, in: source)

        XCTAssertEqual(schemata.map(\.snapshot.before), ["a ?? b", "a ?? b"])
        XCTAssertEqual(diff(of: schemata[0], in: source), ["-2:     print(a ?? b)", "+2:     print(b)"])
        XCTAssertNil(diff(of: schemata[1], in: source))
    }
}
