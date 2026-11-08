@testable import muterCore
import SwiftParser
import XCTest

/// A mutant's place as the Stryker and SARIF reports give it: the code it changes, found from where its operator
/// places it, with columns in UTF-16 code units, where SwiftSyntax gives UTF-8 bytes, and an end just past that code.
final class SourceSpanTests: MuterTestCase {
    private func span(
        _ text: String,
        line: Int = 1,
        utf8Column: Int,
        before: String = "==",
        by operatorId: MutationOperator.Id = .ror
    ) -> SourceSpan? {
        SourceLines(text).span(of: before, placedAt: line, utf8Column: utf8Column, by: operatorId)
    }

    private func position(_ line: Int, _ column: Int) -> SourceSpan.Position {
        SourceSpan.Position(line: line, column: column)
    }

    // é is two bytes and one unit; an emoji four bytes and two units; each of 日 and 本 three bytes and one unit; a tab
    // one of each.
    func test_aColumn_countsUTF16CodeUnits() {
        let cases: [(text: String, utf8Column: Int, utf16Column: Int)] = [
            ("    return a == b", 14, 14),
            ("    let café = 1; if a == b {", 25, 24),
            ("    let s = \"🎉\"; if a == b {", 26, 24),
            ("    let s = \"日本\"; if a == b {", 28, 24),
            ("\tif a == b {", 7, 7),
        ]
        for (text, utf8Column, utf16Column) in cases {
            XCTAssertEqual(
                span(text, utf8Column: utf8Column),
                SourceSpan(start: position(1, utf16Column), end: position(1, utf16Column + 2)),
                text
            )
        }
    }

    // The end counts the code's own units: `"é"` is three of them, where it is four bytes.
    func test_theEnd_isJustPastTheCode_inUTF16CodeUnits() {
        XCTAssertEqual(
            span("    let s = \"é\" + t", utf8Column: 13, before: "\"é\""),
            SourceSpan(start: position(1, 13), end: position(1, 16))
        )
    }

    // A ternary over three lines, which its operator gives on one line and places where it ends, starts on the first
    // and ends on the third, just past its last character, counted from the line's start.
    func test_codeOverSeveralLines_endsOnItsLastLine() {
        let text = "let x = flag\n    ? café\n    : b\n"

        XCTAssertEqual(
            span(text, line: 3, utf8Column: 8, before: "flag ? café : b", by: .swapTernary),
            SourceSpan(start: position(1, 9), end: position(3, 8))
        )
    }

    // `&&` that starts a line is placed before its line break, at the end of the line above.
    func test_anOperatorThatStartsItsLine_isOnThatLine() {
        XCTAssertEqual(
            span("guard a\n    && b else { return }", utf8Column: 8, before: "&&", by: .logicalOperator),
            SourceSpan(start: position(2, 5), end: position(2, 7))
        )
    }

    // A comparison or logical operator is placed before any comment beside its token, and its `before` holds the
    // comment, but its mutant changes the token alone, so the span is the token's, not the comment's too.
    func test_aCommentBesideAnOperator_isntInItsSpan() {
        XCTAssertEqual(
            span(
                "guard a\n    // both must hold\n    && b else { return }",
                utf8Column: 8,
                before: "// both must hold\n    &&",
                by: .logicalOperator
            ),
            SourceSpan(start: position(3, 5), end: position(3, 7))
        )
        XCTAssertEqual(
            span("x = a ==  // why\n  b", utf8Column: 7, before: "==  // why"),
            SourceSpan(start: position(1, 7), end: position(1, 9))
        )
        XCTAssertEqual(
            span(
                "x = a\n  /* a /* nested */ one */ <= b",
                utf8Column: 6,
                before: "/* a /* nested */ one */ <=",
                by: .relationalBoundary
            ),
            SourceSpan(start: position(2, 28), end: position(2, 30))
        )
        XCTAssertEqual(SourceLines.code(of: "// why\n    &&  /* and */", by: .logicalOperator), "&&")
        XCTAssertEqual(SourceLines.code(of: "save() // why", by: .removeSideEffects), "save() // why")
    }

    // `before` is trimmed and inlined, which takes out every Unicode space, as a no-break one, not only ASCII ones, so
    // the file's are spaces too.
    func test_unicodeSpaces_areSpaces() {
        let flush = "cache.flush() // done"
        XCTAssertEqual(
            span("    \(flush)\u{00A0}", utf8Column: 28, before: flush, by: .removeSideEffects),
            SourceSpan(start: position(1, 5), end: position(1, 26))
        )
        let save = "    save(a,\u{00A0}\n        b)"
        XCTAssertEqual(
            span(save, line: 2, utf8Column: 11, before: "save(a, b)", by: .removeSideEffects),
            SourceSpan(start: position(1, 5), end: position(2, 11))
        )
        XCTAssertEqual(
            span("\u{3000}if a\u{3000}== b {", utf8Column: 7, before: "a == b", by: .negateConditional),
            SourceSpan(start: position(1, 5), end: position(1, 11))
        )
    }

    // A removed statement is placed where it ends, after any comment beside it, which is part of its code.
    func test_aRemovedStatement_endsWhereItIsPlaced() {
        XCTAssertEqual(
            span("    save()\n    save()\n", utf8Column: 11, before: "save()", by: .removeSideEffects),
            SourceSpan(start: position(1, 5), end: position(1, 11))
        )
        XCTAssertEqual(
            span(
                "    foo(\n        a: 1\n    ) // why\n",
                line: 3,
                utf8Column: 13,
                before: "foo( a: 1 ) // why",
                by: .removeSideEffects
            ),
            SourceSpan(start: position(1, 5), end: position(3, 13))
        )
    }

    // A later link of a ternary chain is placed at its `?`, inside the code it changes.
    func test_aLaterLinkOfATernaryChain_startsBeforeItsPlace() {
        XCTAssertEqual(
            span("x = a ? b : c\n    ? d : e", line: 2, utf8Column: 5, before: "c ? d : e", by: .swapTernary),
            SourceSpan(start: position(1, 13), end: position(2, 12))
        )
    }

    // Code that isn't where its operator places it, as in a file changed since, isn't found; its mutant then spans its
    // whole line.
    func test_codeNotWhereItIsPlaced_spansItsWholeLine() {
        XCTAssertNil(span("if a != b {", utf8Column: 6))
        XCTAssertNil(span("    save()", utf8Column: 11, before: "load()", by: .removeSideEffects))

        let found = SourceSpan.of(ToolReportFixture.mutant(.passed, line: 1, column: 6), in: SourceLines("if a != b {"))
        XCTAssertEqual(found.span, SourceSpan(start: position(1, 1), end: position(1, 12)))
        XCTAssertFalse(found.isFound)
    }

    // Without the file's text, as for one that can't be read, the columns stay as SwiftSyntax counts them, and code
    // placed where it ends is taken to end there.
    func test_withoutTheLine_theColumnsStayInBytes() {
        let unread = SourceSpan(placedAt: 2, utf8Column: 25, before: "\"é\"", by: .ror)
        XCTAssertEqual(unread, SourceSpan(start: position(2, 25), end: position(2, 29)))
        let removed = SourceSpan(placedAt: 7, utf8Column: 11, before: "save()", by: .removeSideEffects)
        XCTAssertEqual(removed, SourceSpan(start: position(7, 5), end: position(7, 11)))
        let commented = SourceSpan(placedAt: 2, utf8Column: 8, before: "==  // why", by: .ror)
        XCTAssertEqual(commented, SourceSpan(start: position(2, 8), end: position(2, 10)))
        let shorter = SourceSpan.of(ToolReportFixture.mutant(.passed, line: 3, column: 25), in: SourceLines("one line"))
        XCTAssertEqual(shorter.span, SourceSpan(start: position(3, 25), end: position(3, 27)))
        XCTAssertFalse(shorter.isFound)
    }

    // Every operator's place finds the code it changes, as discovery gives both, and the fixture's mutants are at
    // the places discovery gives them.
    func test_eachOperatorsPlace_findsItsCode() throws {
        let code = """
        func f(_ a: Bool, _ b: Bool, _ items: inout [Int]) -> Int {
            guard a
                && b else { return 0 }
            guard a
                // both must hold
                && b, a ==  // why
                b else { return 0 }
            if a &&
                b {
                items.append(
                    1
                ) // one
            }
            let x = a ? 1 : b ? 2 : 3
            let y = x
                == 1
            return a
                ? x
                : x + 1 * (y ? 1 : 0)
        }
        """
        let found = try spans(of: code)
        let operators = Set(found.map(\.schema.mutationOperatorId))
        XCTAssertTrue(
            operators.isSuperset(of: [
                .ror, .logicalOperator, .negateConditional, .swapTernary, .removeSideEffects, .arithmeticOperator,
            ]),
            "\(operators)"
        )
        for (schema, text) in found {
            let before = SourceLines.code(of: schema.snapshot.before, by: schema.mutationOperatorId)
            XCTAssertEqual(text?.inlined, before.inlined, "\(schema.mutationOperatorId)")
        }
        XCTAssertTrue(found.contains { $0.schema.snapshot.before.hasPrefix("// both must hold") && $0.text == "&&" })
        XCTAssertTrue(found.contains { $0.schema.snapshot.before.hasSuffix("// why") && $0.text == "==" })

        let fixture = try spans(of: ToolReportFixture.rules).map(\.schema)
        let places = Set(fixture.map { "\($0.mutationOperatorId) \($0.position.line):\($0.position.column)" })
        for (operatorId, place) in [
            (MutationOperator.Id.swapTernary, ToolReportFixture.ternaryEnd),
            (.logicalOperator, ToolReportFixture.andPlace),
            (.removeSideEffects, ToolReportFixture.statementEnd),
        ] {
            XCTAssertTrue(places.contains("\(operatorId) \(place.line):\(place.column)"), "\(operatorId) in \(places)")
        }
        XCTAssertTrue(fixture.contains { $0.snapshot.before == ToolReportFixture.ternary })
        XCTAssertTrue(fixture.contains { $0.snapshot.before == "items.append(1)" })
    }

    /// Each mutant discovery finds in `code`, with the text of the span found for it.
    private func spans(of code: String) throws -> [(schema: MutationSchema, text: String?)] {
        let source = SourceCodeInfo(path: "/path/to/Sample.swift", code: Parser.parse(source: code))
        let lines = SourceLines(code)
        return try generateSchemataMappings(for: source).flatMap(\.mutationSchemata).map { schema in
            let position = schema.position
            let span = try XCTUnwrap(
                lines.span(
                    of: schema.snapshot.before,
                    placedAt: position.line,
                    utf8Column: position.column,
                    by: schema.mutationOperatorId
                ),
                "\(schema.mutationOperatorId) \(schema.snapshot.before) at \(position.line):\(position.column)"
            )
            return (schema, lines.text(of: span))
        }
    }

    // A lone `\r` breaks a line as SwiftSyntax numbers lines, so a `\r\r\n` is two breaks, and the code after them is
    // on the line its mutant gives.
    func test_aLoneReturn_breaksALine_asSwiftSyntaxCounts() throws {
        let lines = SourceLines("a\r\r\nb\rc")
        XCTAssertEqual((1...4).map(lines.line), ["a", "", "b", "c"])
        XCTAssertNil(lines.line(5))

        let found = try spans(of: "func f() -> Bool {\r\r\n    // x\r    return a == b\n}\n")
            .filter { $0.schema.mutationOperatorId == .ror }
        XCTAssertEqual(found.map(\.schema.position.line), [4])
        XCTAssertEqual(found.map(\.text), ["=="])
    }

    // A Windows line break is one; `\r\n` is one Character, which a split on "\n" wouldn't find.
    func test_lines_splitAtEveryLineBreak() {
        let lines = SourceLines("café\r\n\tb\nc")

        XCTAssertEqual(lines.line(1), "café")
        XCTAssertEqual(lines.line(2), "\tb")
        XCTAssertEqual(lines.line(3), "c")
        XCTAssertNil(lines.line(4))
        XCTAssertNil(lines.line(0))
        XCTAssertEqual(lines.utf16Column(ofUTF8Column: 6, onLine: 1), 5, "just past café")
    }

    // A file changed since may put a column inside a character, or past its line's end.
    func test_aColumnThatDoesntFitTheLine_stillGivesOne() {
        let lines = SourceLines("é = 1")

        XCTAssertEqual(lines.utf16Column(ofUTF8Column: 2, onLine: 1), 2, "the first byte of é")
        XCTAssertEqual(lines.utf16Column(ofUTF8Column: 9, onLine: 1), 8, "two bytes past the end")
    }

    // The text of a span, over its lines, and how many lines above each hold the same text.
    func test_aSpansText_andRepeatedLines() {
        let lines = SourceLines("a = 1\n  b(\n    c)\n a = 1 \n")

        XCTAssertEqual(lines.text(of: SourceSpan(start: position(2, 3), end: position(3, 7))), "b(\n    c)")
        XCTAssertEqual(lines.text(of: SourceSpan(start: position(1, 5), end: position(1, 6))), "1")
        XCTAssertNil(lines.text(of: SourceSpan(start: position(5, 1), end: position(6, 1))))
        XCTAssertEqual(lines.repeatsAbove, [0, 0, 0, 1, 0])
    }

    // Each file is read once, and one that can't be read has no text.
    func test_originalFiles_readEachFileOnce() {
        let reads = Locked<[String]>([])
        let files = OriginalFiles(["/a.swift", "/b.swift", "/a.swift"]) { path in
            reads.change { $0.append(path) }
            return path == "/a.swift" ? Data("a\u{FF}".utf8) : nil
        }

        XCTAssertEqual(reads.value.sorted(), ["/a.swift", "/b.swift"])
        XCTAssertEqual(files.text(at: "/a.swift"), "a\u{FF}")
        XCTAssertNil(files.text(at: "/b.swift"))
        XCTAssertNil(files.read("/b.swift"))
    }
}
