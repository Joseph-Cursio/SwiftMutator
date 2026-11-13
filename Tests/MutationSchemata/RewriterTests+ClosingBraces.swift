@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

extension RewriterTests {
    // Each branch's closing brace took the statement list's leading trivia. When the first statement
    // shares a line with the `{` that opens the block, that trivia has no line break, so the brace
    // landed at the end of the block's last line: inside a `//` comment there, or after an `#endif`.
    // Either way the file didn't compile, and the build every mutant shares failed with it.
    func test_startsEachClosingBraceOnANewLine_whenTheBlockEndsInALineComment() throws {
        // Two mutants, so the middle branch's brace is covered as well as the first and last.
        let rewritten = try rewrite("""
        func check(_ value: Int) -> Bool { let limit = value > 1
            return limit && value < 9 // done
        }
        """)

        XCTAssertFalse(Parser.parse(source: rewritten).hasError, rewritten)
        XCTAssertFalse(rewritten.contains("// done}"), rewritten)
    }

    func test_startsEachClosingBraceOnANewLine_whenTheBlockEndsInAnEndif() throws {
        let rewritten = try rewrite("""
        func log(_ flag: Bool) { print(flag ? 1 : 2)
            #if DEBUG
            print("debug")
            #endif
        }
        """)

        XCTAssertFalse(Parser.parse(source: rewritten).hasError, rewritten)
        XCTAssertFalse(rewritten.contains("#endif}"), rewritten)
    }

    // A `case` body written on the `case` line has no leading line break either.
    func test_startsEachClosingBraceOnANewLine_inACaseOnOneLine() throws {
        let rewritten = try rewrite("""
        func name(_ value: Int) -> String {
            switch value {
            case 0: return value > 1 ? "a" : "b" // zero
            default: return "c"
            }
        }
        """)

        XCTAssertFalse(Parser.parse(source: rewritten).hasError, rewritten)
        XCTAssertFalse(rewritten.contains("// zero}"), rewritten)
    }

    // Each branch is checked by its own last line. Removing `notify()` leaves a mutant that ends in
    // `// c` although the original doesn't, and its brace swallowed the next branch's `} else if`. That
    // compiled, but the mutant after it could never run.
    func test_startsAClosingBraceOnANewLine_whenOnlyTheMutantEndsInALineComment() throws {
        let rewritten = try rewrite("""
        func step(_ value: Int) { record(value > 1) // c
            notify()
        }
        """)

        XCTAssertFalse(Parser.parse(source: rewritten).hasError, rewritten)
        XCTAssertFalse(rewritten.contains("// c}"), rewritten)
    }

    // Inside a one-line string interpolation a line break doesn't compile, so a closure there must keep
    // its braces on its line. A line break before every brace, the first fix tried, broke these.
    func test_keepsEachClosingBraceOnItsLine_inAStringInterpolation() throws {
        let rewritten = try rewrite("""
        func summary(_ values: [Int]) -> String {
            let plain = "\\(values.filter { $0 > 1 }.count) big"
            let raw = #"\\#(values.filter { $0 < 9 }.count) small"#
            return plain + raw
        }
        """)

        XCTAssertFalse(Parser.parse(source: rewritten).hasError, rewritten)
    }

    // Inside a multi-line string every line, those of an interpolation's code too, must start with the
    // indentation of the closing `"""`. A brace started on a new line took the statement list's leading
    // trivia, which is empty when the first statement shares the `{` line, so it landed at column 0.
    func test_indentsEachClosingBraceOnANewLine_inAMultiLineString() throws {
        let rewritten = try rewrite("""
        func summary(_ items: [Int]) -> String {
            \"""
            Count: \\(items.filter { let limit = 1
                return $0 > limit // the big ones
            }.count)
            Small: \\(items.filter { $0 < 9 // the small ones
            }.count)
            \"""
        }
        """)

        XCTAssertFalse(Parser.parse(source: rewritten).hasError, rewritten)
        // Like the branch's last line, and like the list's first line for a branch on one line.
        XCTAssertTrue(rewritten.contains("// the big ones\n        } else {"), rewritten)
        XCTAssertTrue(rewritten.contains("// the big ones\n        }\n    }.count)"), rewritten)
        XCTAssertTrue(rewritten.contains("// the small ones\n    } else {"), rewritten)
        XCTAssertTrue(rewritten.contains("// the small ones\n    }\n    }.count)"), rewritten)
    }

    // The closing `"""` is indented with a tab, so a line indented with spaces alone didn't compile.
    func test_indentsEachClosingBraceOnANewLine_withTheTabsOfAMultiLineString() throws {
        let rewritten = try rewrite("""
        func summary(_ items: [Int]) -> String {
        \t\"""
        \tCount: \\(items.filter { let limit = 1
        \t    return $0 > limit // the big ones
        \t}.count)
        \tSmall: \\(items.filter { $0 < 9 // the small ones
        \t}.count)
        \t\"""
        }
        """)

        XCTAssertFalse(Parser.parse(source: rewritten).hasError, rewritten)
    }

    // A brace's line starts with the line break of the line whose indentation it copies, so a file's line
    // endings stay as they are. A line feed alone mixed them, and after a lone carriage return the compiler
    // checked the brace's line though it never checked the line it copied.
    func test_startsEachClosingBraceOnANewLine_withTheFilesLineBreaks() throws {
        let code = """
        func summary(_ items: [Int]) -> String {
            \"""
            Count: \\(items.filter { let limit = 1
                return $0 > limit // the big ones
            }.count)
            Small: \\(items.filter { $0 < 9 // the small ones
            }.count)
            \"""
        }
        """
        for lineBreak in ["\r\n", "\r"] {
            let rewritten = try rewrite(code.replacingOccurrences(of: "\n", with: lineBreak))

            XCTAssertFalse(Parser.parse(source: rewritten).hasError, rewritten)
            XCTAssertTrue(rewritten.contains("// the big ones\(lineBreak)        } else {"), rewritten)
            XCTAssertTrue(rewritten.contains("// the small ones\(lineBreak)    } else {"), rewritten)
        }
    }

    func rewrite(_ code: String) throws -> String {
        let source = SourceCodeInfo(path: "/path/to/file.swift", code: Parser.parse(source: code))
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)
        return MuterRewriter(mapping).rewrite(source.code).description
    }
}
