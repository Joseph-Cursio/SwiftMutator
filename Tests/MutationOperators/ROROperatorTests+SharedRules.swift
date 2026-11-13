@testable import muterCore
import TestingExtensions
import XCTest

extension ROROperatorTests {
    func test_aCompilerDirectivesCondition_isLeftAlone_howeverDeepItIs() throws {
        let source = try sourceCode("""
        func f(a: Int, b: Int) {
            #if !(swift(>=5.9) && VALUE == 1)
            run(a == b)
            #elseif (compiler(<6) || VALUE != 2)
            run(a != b)
            #endif
        }
        """)
        let visitor = ROROperator.Visitor(sourceCodeInfo: .init(path: "/path/to/file", code: source))

        visitor.walk(source)

        XCTAssertEqual(
            visitor.schemataMappings.mutationSchemata.map(\.position.line).sorted(),
            [3, 3, 5, 5]
        )
    }

    func test_anOperatorsDeclaration_isLeftAlone() throws {
        XCTAssertEqual(try changes(in: """
        struct V: Comparable {
            static func < (lhs: V, rhs: V) -> Bool { lhs.x < rhs.x }
            static func == (lhs: V, rhs: V) -> Bool { true }
        }
        infix operator <=>: ComparisonPrecedence
        """), ["< → !=", "lhs.x < rhs.x → false"])
    }

    func test_aDisableTag_isRead() throws {
        XCTAssertEqual(try changes(in: """
        func f() {
            // muter:disable
            let x = a < b
            // muter:enable
            let y = a == b
        }
        """), ["a == b → true", "a == b → false"])
    }

    // The `false` mutant is placed where the comparison ends, after a tag for the next line: all of a comparison's
    // mutants are left out, not some, as ReplaceBooleanValue leaves out both of a value's.
    func test_aDisableNextLineTagInsideAComparisonOverSeveralLines_leavesOutAllOrNone() throws {
        for code in [
            "func f() -> Bool {\n    return a ==\n        // muter:disable-next-line\n        b\n}",
            "func f() -> Bool {\n    return a\n        // muter:disable-next-line\n        < b\n}",
            "func f() -> Bool {\n    return a\n        // muter:disable-next-line\n        <= b\n}",
        ] {
            XCTAssertEqual(try changes(in: code), [], code)
        }
        let nextLine = "func f() -> Bool {\n    // muter:disable-next-line\n    let x = a < b\n    return a > b\n}"
        XCTAssertEqual(try changes(in: nextLine), ["> → !=", "a > b → false"])
    }

    // As with any other operator, code the tests never ran gets no mutant: the constants go by the operator, as the
    // swap does, so the right-hand side of `&&`, a closure of its own, is left out whole.
    func test_codeThatNeverRan_isLeftOut() throws {
        let visitor = try visitor(
            walking: """
            func f() -> Bool {
                if a {
                    return b < c
                }
                return b == c
            }
            """,
            coverage: .make(regionsWithoutCoverage: [.make(lineStart: 2, columnStart: 10, lineEnd: 4, columnEnd: 6)])
        )

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.position.line), [5, 5])
    }

    func test_aStoredPropertysAndAGlobalsValue_areSwitchedInTheValue() throws {
        let visitor = try visitor(walking: """
        struct S {
            var isLarge = size > 1
            lazy var isEmpty = items.count == 0
        }
        let isQuiet = level < 2
        """)

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.count, 6)
        XCTAssertEqual(visitor.droppedMutants, [])
    }
}
