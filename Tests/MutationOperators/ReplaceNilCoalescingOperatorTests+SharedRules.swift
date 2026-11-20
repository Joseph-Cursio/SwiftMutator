@testable import muterCore
import XCTest

extension ReplaceNilCoalescingOperatorTests {
    func test_aDisableTag_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Int {
            // muter:disable
            use(a ?? b)
            // muter:enable
            return c ?? d
        }
        """), ["c ?? d"])
    }

    // The tag can sit just before the operator, so it has to be read before the operator is.
    func test_aDisableTagBeforeTheOperator_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Int {
            return a
                // muter:disable
                ?? b
        }
        """), [])
    }

    func test_aDisableNextLineTag_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Int {
            // muter:disable-next-line
            use(a ?? b)
            return c ?? d
        }
        """), ["c ?? d"])
    }

    // The term's start is its mutant's place, so a tag above where it starts leaves out a link on a later line too.
    func test_aDisableNextLineTagAboveATermOverSeveralLines_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Int {
            // muter:disable-next-line
            return a
                ?? b
        }
        """), [])
    }

    func test_aCoalescingInACompilerDirectivesCode_isReplaced() throws {
        XCTAssertEqual(try values(in: """
        func f() -> String {
            #if DEBUG
            return debugName ?? "debug"
            #else
            return name ?? ""
            #endif
        }
        """), [#"debugName ?? "debug""#, #"name ?? """#])
    }

    func test_aCoalescingInACompilerDirectivesCondition_isLeftAlone() throws {
        let visitor = try visitor(walking: """
        func f() {
            #if (VALUE ?? 1) == 1
            use(a ?? b)
            #elseif compiler(<6) || (OTHER ?? 0) != 2
            use(c ?? d)
            #endif
        }
        """)

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.position.line), [3, 5])
    }

    // A mutant in a macro's arguments is switched around the macro, as other operators' are.
    func test_aCoalescingInAMacrosArguments_counts() throws {
        XCTAssertEqual(try values(in: "func f() { #expect(a ?? b == c) }"), ["a ?? b"])
    }

    func test_aStoredPropertysAStaticsAndAGlobalsValue_areSwitchedInTheValue() throws {
        let visitor = try visitor(walking: """
        struct S {
            var n = a ?? b
            static let s: Int = c ?? d
            lazy var e = f ?? g
        }
        let h = i ?? j
        """)

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.count, 4)
        XCTAssertEqual(visitor.droppedMutants, [])
    }

    // As with any other operator, code the tests never ran gets no mutant.
    func test_codeThatNeverRan_isLeftOut() throws {
        let visitor = try visitor(
            walking: """
            func f() -> Int {
                if flag {
                    return a ?? b
                }
                return c ?? d
            }
            """,
            coverage: .make(regionsWithoutCoverage: [.make(lineStart: 2, columnStart: 13, lineEnd: 4, columnEnd: 6)])
        )

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.position.line), [5])
    }

    // A fallback no test ran is the survivor this operator is for: coverage goes by the `??`, which ran with the term.
    // A later link of a chain sits in the fallback before it, and only matters when that ran.
    func test_aFallbackThatNeverRan_keepsItsMutant_butALaterLinkInIt_hasNone() throws {
        let visitor = try visitor(
            walking: """
            func f() -> Int {
                a ?? b ?? c
            }
            """,
            coverage: .llvmCov([[[1, 17, 3, 2, 1], [2, 10, 2, 16, 0]]])
        )

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.snapshot.before), ["a ?? b ?? c"])
    }
}
