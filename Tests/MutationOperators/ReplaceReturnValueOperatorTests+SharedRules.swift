@testable import muterCore
import XCTest

extension ReplaceReturnValueOperatorTests {
    func test_aDisableTag_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Int {
            // muter:disable
            if a { return b }
            // muter:enable
            return c
        }
        """), ["c"])
    }

    // The tag can sit beside the value itself, so it has to be read before the value is.
    func test_aDisableTagBesideTheValue_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Int {
            return
                // muter:disable
                count
        }
        """), [])
    }

    func test_aDisableNextLineTag_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Int {
            // muter:disable-next-line
            if a { return b }
            return c
        }
        """), ["c"])
    }

    func test_aValueInACompilerDirectivesCode_isReplaced() throws {
        XCTAssertEqual(try values(in: """
        func f() -> String {
            #if DEBUG
            return debugName
            #else
            return name
            #endif
        }
        """), ["debugName", "name"])
    }

    // As with any other operator, code the tests never ran gets no mutant.
    func test_codeThatNeverRan_isLeftOut() throws {
        let visitor = try visitor(
            walking: """
            func f() -> Int {
                if a {
                    return b
                }
                return c
            }
            """,
            coverage: .make(regionsWithoutCoverage: [.make(lineStart: 2, columnStart: 10, lineEnd: 4, columnEnd: 6)])
        )

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.position.line), [5])
    }
}
