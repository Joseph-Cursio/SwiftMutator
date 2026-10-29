@testable import muterCore
import SwiftParser
import SwiftSyntax
import TestingExtensions
import XCTest

final class SchemataBuilderTests: MuterTestCase {
    override func setUp() {
        super.setUp()

        fileManager.currentDirectoryPathToReturn = "/path/fileName"
    }

    func test_schemataMerging() throws {
        let codeBlock = try sourceCode("return 1").statements

        let x = SchemataMutationMapping()
        try x.add(codeBlock, .make(filePath: ""))
        try x.add(codeBlock, .make())

        let y = SchemataMutationMapping()
        try y.add(codeBlock, .make())
        try y.add(codeBlock, .make())

        let actualMappings = x + y

        XCTAssertEqual(actualMappings.codeBlocks, ["return 1"])
        XCTAssertEqual(actualMappings.mutationSchemata.count, 4)
    }

    func test_mutationSwitch() throws {
        let originalSyntax = try sourceCode("\n  a != b\n").statements
        let mutationSchemata = try makeMutationSchemata([
            "\n  a >= b\n",
            "\n  a <= b\n",
            "\n  a == b\n",
        ])

        let actualMutationSwitch = MutationSwitch.apply(
            mutationSchemata: mutationSchemata,
            with: originalSyntax,
            onALineStartingWith: .newline,
            readingEnvironmentFrom: MuterRewriter.environmentCacheName(forFileAt: "/path/to/file")
        )

        AssertSnapshot(formatCode(actualMutationSwitch.description))
    }

    func test_startOfTheFirstLineOfAList() throws {
        let file = try sourceCode("""
          print(1)
        func check(_ values: [Int]) -> String {
        \tlet text = \"""
        \t  Big: \\(values.filter { $0 > 1 }.count)
        \t\"""
        \treturn text
        }
        """)

        XCTAssertEqual(try startOfTheFirstLine(of: "print", in: file), "\n  ", "the file's first line")
        XCTAssertEqual(try startOfTheFirstLine(of: "let", in: file), "\n\t")
        XCTAssertEqual(try startOfTheFirstLine(of: "$0", in: file), "\n\t  ", "in the string's text, not in trivia")
        for lineBreak in ["\r\n", "\r"] {
            let other = try sourceCode("func check() {\(lineBreak)  let value = 1\(lineBreak)}")
            XCTAssertEqual(try startOfTheFirstLine(of: "let", in: other), lineBreak + "  ", "the file's own line break")
        }
    }

    /// The text of `MutationSwitch.startOfTheFirstLine(of:)` for the statement list around the first token
    /// spelled `text` in `file`.
    private func startOfTheFirstLine(of text: String, in file: SourceFileSyntax) throws -> String {
        MutationSwitch.startOfTheFirstLine(of: try list(startingWith: text, in: file)).description
    }

    /// The statement list around the first token spelled `text` in `file`.
    private func list(startingWith text: String, in file: SourceFileSyntax) throws -> CodeBlockItemListSyntax {
        let token = try XCTUnwrap(file.tokens(viewMode: .sourceAccurate).first { $0.text == text }, text)
        var node: Syntax? = Syntax(token)
        while let current = node, !current.is(CodeBlockItemListSyntax.self) {
            node = current.parent
        }
        return try XCTUnwrap(node?.as(CodeBlockItemListSyntax.self), text)
    }

    private func makeMutationSchemata(
        _ mutations: [String]
    ) throws -> MutationSchemata {
        try mutations
            .enumerated()
            .compactMap {
                try MutationSchema.make(
                    filePath: "/path/to/file",
                    syntaxMutation: $0.element,
                    position: MutationPosition(
                        utf8Offset: 0,
                        line: $0.offset
                    )
                )
            }
    }
}
