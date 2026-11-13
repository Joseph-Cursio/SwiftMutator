@testable import muterCore
import SwiftParser
import XCTest

extension SourceSpanTests {
    func span(
        _ text: String,
        utf8Column: Int,
        line: Int = 1,
        before: String = "==",
        by operatorId: MutationOperator.Id = .ror,
        after: String = ""
    ) -> SourceSpan? {
        SourceLines(text).span(of: before, placedAt: line, utf8Column: utf8Column, by: operatorId, after: after)
    }

    func position(_ line: Int, _ column: Int) -> SourceSpan.Position {
        SourceSpan.Position(line: line, column: column)
    }

    /// Each mutant discovery finds in `code`, with the text of the span found for it.
    func spans(of code: String) throws -> [(schema: MutationSchema, text: String?)] {
        let source = SourceCodeInfo(path: "/path/to/Sample.swift", code: Parser.parse(source: code))
        let lines = SourceLines(code)
        return try generateSchemataMappings(for: source).flatMap(\.mutationSchemata).map { schema in
            let position = schema.position
            let span = try XCTUnwrap(
                lines.span(
                    of: schema.snapshot.before,
                    placedAt: position.line,
                    utf8Column: position.column,
                    by: schema.mutationOperatorId,
                    after: schema.snapshot.after
                ),
                "\(schema.mutationOperatorId) \(schema.snapshot.before) at \(position.line):\(position.column)"
            )
            return (schema, lines.text(of: span))
        }
    }

    /// A function with code for each operator, some of it over several lines or with comments inside.
    var codeForEveryOperator: String {
        """
        func f(_ a: Bool, _ b: Bool, _ items: inout [Int]) -> Int {
            guard a
                && b else { return 0 }
            guard a
                // both must hold
                && b, a <  // why
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
    }
}
