@testable import muterCore
import XCTest

extension ReplaceBooleanValueOperatorTests {
    func test_aDisableTag_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() {
            // muter:disable
            let x = a < b
            // muter:enable
            let y = a > b
        }
        """), ["a > b"])
    }

    // The tag can sit beside the value itself, so it has to be read before the value is.
    func test_aDisableTagBesideTheValue_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Bool {
            return
                // muter:disable
                a < b
        }
        """), [])
    }

    // The `false` mutant is placed where the value ends, after a tag for the next line: both are left out, not one.
    func test_aDisableNextLineTagInsideAValueOverSeveralLines_leavesOutBothOrNeither() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Bool {
            return a &&
                // muter:disable-next-line
                b
        }
        """), [])
    }

    func test_aValueInACompilerDirectivesCode_counts() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Bool {
            #if DEBUG
            return a < b
            #else
            return a > b
            #endif
        }
        """), ["a < b", "a > b"])
    }

    // A mutant in a macro's arguments is switched around the macro, as other operators' are.
    func test_aValueInAMacrosArguments_counts() throws {
        XCTAssertEqual(
            try values(in: "func f() { #expect(items.allSatisfy { (x: Int) -> Bool in x > 1 }) }"),
            ["x > 1"]
        )
    }

    func test_aStoredPropertysAStaticsAndAGlobalsValue_areSwitchedInTheValue() throws {
        let visitor = try visitor(walking: """
        struct S {
            var isLarge = size > 1
            static let isDebug: Bool = Environment.isDebug
            lazy var isEmpty = items.count == 0
        }
        let isQuiet = level < 2
        """)

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.count, 8)
        XCTAssertEqual(visitor.droppedMutants, [])
    }

    // As with any other operator, code the tests never ran gets no mutant.
    func test_codeThatNeverRan_isLeftOut() throws {
        let visitor = try visitor(
            walking: """
            func f() -> Bool {
                if a {
                    return b < c
                }
                return b > c
            }
            """,
            coverage: .make(regionsWithoutCoverage: [.make(lineStart: 2, columnStart: 10, lineEnd: 4, columnEnd: 6)])
        )

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.position.line), [5, 5])
    }
}
