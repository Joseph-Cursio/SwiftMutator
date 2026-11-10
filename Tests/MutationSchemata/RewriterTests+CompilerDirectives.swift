@testable import muterCore
import SnapshotTesting
import SwiftParser
import SwiftSyntax
import TestingExtensions
import XCTest

extension RewriterTests {
    // `#if` is not a scope: a `let` in a clause is visible after `#endif`. Switching the clause's own
    // statements put that `let` inside an `if` block and hid it from the code after `#endif`
    // ("cannot find 'outputActual' in scope", swift-argument-parser's TestHelpers.swift). Such a
    // clause's mutants are switched in the list around the `#if` instead.
    func test_switchesAroundAnIfConfigClauseThatDeclaresSomething() throws {
        let source = SourceCodeInfo(path: "/path/to/describe.swift", code: Parser.parse(source: """
        func describe(_ flag: Bool) throws -> String {
            #if os(macOS)
            let value = flag ? "on" : "off"
            #else
            throw Failure()
            #endif
            return value
        }
        """))
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)

        XCTAssertEqual(mapping.codeBlocks.count, 1)
        let block = try XCTUnwrap(mapping.codeBlocks.first)
        XCTAssertTrue(block.contains("#endif") && block.contains("return value"), block)

        // Each branch holds the whole `#if`, and the `return` after it: `return value`, or ReplaceReturnValue's
        // `return ""` in its own branch.
        let rewritten = MuterRewriter(mapping).rewrite(source.code).description
        let branches = mapping.mutationSchemata.count + 1
        XCTAssertEqual(rewritten.components(separatedBy: "#endif").count - 1, branches, rewritten)
        XCTAssertEqual(rewritten.components(separatedBy: "return value").count - 1, branches - 1, rewritten)
    }

    func test_keepsSwitchingInsideAnIfConfigClauseWithoutDeclarations() throws {
        let source = SourceCodeInfo(path: "/path/to/log.swift", code: Parser.parse(source: """
        func log(_ flag: Bool) {
            #if DEBUG
            print(flag ? 1 : 2)
            #endif
            print("done")
        }
        """))
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)

        XCTAssertEqual(mapping.codeBlocks.count, 1)
        XCTAssertFalse(try XCTUnwrap(mapping.codeBlocks.first).contains("#if"), mapping.codeBlocks.description)
    }

    // Each mutant's branch held a copy of the list's directives, and a `#sourceLocation()` in a copy could close a
    // location none had opened: test_theGeneratedCodeBuildsAroundSourceLocationDirectives compiles such files. Only
    // the original's branch keeps them now, at any depth: in a closure, a type, a `case`, a list with a switch of
    // its own, and a list whose first mutant removes the statement that holds one.
    func test_keepsEachSourceLocationDirectiveInTheOriginalsBranchAlone() throws {
        let code = """
        func record(_ log: (() -> Void) -> Void, _ note: () -> Void) {
            do {
                log {
        #sourceLocation()
                }
                note()
            }
        }
        func located(_ items: [Int]) -> Int {
            let count = items.count > 1 ? 1 : 2; #sourceLocation(file: "Located.swift.gyb", line: 1)
            let run = { () -> Int in
        #sourceLocation()
                return count
            }
            struct Box {
                let value = 1
        #sourceLocation(file: "Located.swift.gyb", line: 10)
            }
            switch count {
            case 1:
        #sourceLocation()
            default:
                return 0
            }
            if count > 0 {
                let other = count < 5 ? 3 : 4
        #sourceLocation(file: "Located.swift.gyb", line: 20)
                return other + run() + Box().value
            }
            return count
        }
        """
        let rewritten = try rewrite(code)

        XCTAssertFalse(Parser.parse(source: rewritten).hasError, rewritten)
        XCTAssertEqual(
            rewritten.components(separatedBy: "#sourceLocation").count,
            code.components(separatedBy: "#sourceLocation").count,
            rewritten
        )
        // A `case` that held nothing but a directive must still hold a statement, on the directive's line.
        XCTAssertTrue(rewritten.contains("case 1:\ndo {}\n    default:"), rewritten)
        XCTAssertTrue(rewritten.contains("case 1:\n#sourceLocation()\n    default:"), rewritten)
    }
}
