@testable import muterCore
import SnapshotTesting
import SwiftSyntax
import TestingExtensions
import XCTest

final class RemoveSideEffectsOperatorTests: MuterTestCase {
    private lazy var sourceWithSideEffects = sourceCode(
        fromFileAt: "\(fixturesDirectory)/MutationExamples/SideEffect/sampleWithSideEffects.swift"
    )!

    func test_visitor() throws {
        let visitor = RemoveSideEffectsOperator.Visitor(
            sourceCodeInfo: sourceWithSideEffects
        )

        visitor.walk(sourceWithSideEffects.code)

        let actualSchemata = visitor.schemataMappings

        assertMutationPositions(
            actualSchemata, [
                MutationPosition(utf8Offset: 186, line: 10, column: 27),
                MutationPosition(utf8Offset: 423, line: 20, column: 62),
                // Lines 30 and 31 declare variables whose string literal contains `_ = `. They used to
                // be removed on that text alone; a declaration is not a side effect to remove.
                MutationPosition(utf8Offset: 906, line: 39, column: 6),
                MutationPosition(utf8Offset: 80, line: 3, column: 27),
                MutationPosition(utf8Offset: 994, line: 44, column: 19),
                MutationPosition(utf8Offset: 1049, line: 48, column: 19),
                MutationPosition(utf8Offset: 1099, line: 52, column: 19),
                MutationPosition(utf8Offset: 1138, line: 56, column: 19),
            ]
        )
    }

    private func assertMutationPositions(
        _ actual: SchemataMutationMapping,
        _ expected: [MutationPosition],
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let actualSorted = actual.mutationSchemata.map(\.position).sorted()
        let expectedSoted = expected.sorted()

        XCTAssertEqual(actualSorted, expectedSoted, file: file, line: line)
    }

    func test_rewriter() throws {
        let visitor = RemoveSideEffectsOperator.Visitor(
            sourceCodeInfo: sourceWithSideEffects
        )

        visitor.walk(sourceWithSideEffects.code)

        let rewriter = MuterRewriter(visitor.schemataMappings).rewrite(sourceWithSideEffects.code)

        AssertSnapshot(formatCode(rewriter.description))
    }

    // Statements were matched by their text, so removing one of two identical statements removed
    // both, and the block's two mutants were the same mutant.
    func test_removesOnlyItsOwnStatement_whenTheBlockRepeatsIt() throws {
        let source = try sourceCode(
            """
            func refresh(_ event: Event) {
                reload()
                log(event)
                reload()
            }
            """
        )
        let visitor = RemoveSideEffectsOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source)
        )

        visitor.walk(source)

        let remaining = visitor.schemataMappings.mutationSchemata.map { $0.syntaxMutation.description.trimmed.inlined }
        XCTAssertEqual(remaining.sorted(), ["log(event) reload()", "reload() log(event)", "reload() reload()"])
    }

    // The reparse of the shortened block was told where the edit ends in characters, not UTF-8
    // bytes. After multi-byte text that put the end too early, and the reparse took the statements
    // after it from the wrong place: the mutant meant to remove `notify()` removed `reload()`.
    func test_removesItsOwnStatement_afterMultiByteText() throws {
        let source = try sourceCode(
            """
            func refresh() {
                let label = "🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂"
                record(label)
                reload()
                notify()
            }
            """
        )
        let visitor = RemoveSideEffectsOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source)
        )

        visitor.walk(source)

        let remainingByRemoved = Dictionary(
            uniqueKeysWithValues: visitor.schemataMappings.mutationSchemata.map {
                ($0.snapshot.before, $0.syntaxMutation.description.trimmed.inlined)
            }
        )
        let label = #"let label = "🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂""#
        XCTAssertEqual(remainingByRemoved, [
            "record(label)": "\(label) reload() notify()",
            "reload()": "\(label) record(label) notify()",
            "notify()": "\(label) record(label) reload()",
        ])
    }

    // Removing a statement took the newline before it too, so a statement after it on the same
    // line, after a `;`, joined the line above. `prepare()notify()` doesn't compile, which fails
    // the build every mutant shares and aborts the whole run.
    func test_keepsTheNextStatementOnItsOwnLine_whenTheRemovedOneSharedIt() throws {
        let remainingByRemoved = try remainingStatementsByRemoved(
            in: """
            func refresh() {
                prepare()
                reload(); notify()
            }
            """
        )

        XCTAssertEqual(remainingByRemoved["reload();"], "\n    prepare()\n    notify()")
    }

    // After a `//` comment, the joined statement moved into the comment: the mutant compiled, but
    // removed `notify()` too, so the report described it wrongly.
    func test_keepsTheNextStatementOutOfAComment_whenTheRemovedOneSharedItsLine() throws {
        let remainingByRemoved = try remainingStatementsByRemoved(
            in: """
            func refresh() {
                prepare() // note
                reload(); notify()
            }
            """
        )

        XCTAssertEqual(remainingByRemoved["reload();"], "\n    prepare() // note\n    notify()")
    }

    func test_keepsTheNextStatementOnItsOwnLine_withCRLFLineEndings() throws {
        let remainingByRemoved = try remainingStatementsByRemoved(
            in: ["func refresh() {", "    prepare()", "    reload(); notify()", "}"].joined(separator: "\r\n")
        )

        XCTAssertEqual(remainingByRemoved["reload();"], "\r\n    prepare()\r\n    notify()")
    }

    // A block's first statement compiled either way, since the switch branch's `{` comes before it,
    // but the next statement lost the block's line break and indentation and sat against that `{`.
    func test_keepsTheNextStatementOnItsOwnLine_whenTheRemovedOneOpensTheBlock() throws {
        let remainingByRemoved = try remainingStatementsByRemoved(
            in: """
            func refresh() {
                reload(); notify()
                prepare()
            }
            """
        )

        XCTAssertEqual(remainingByRemoved["reload();"], "\n    notify()\n    prepare()")
    }

    // Only the statement straight after the removed one moves. One that already follows a `;` that
    // stays, as `notify()` does when `reload();` goes, is left where it is.
    func test_movesOnlyTheNextStatement_whenALineHoldsThree() throws {
        let remainingByRemoved = try remainingStatementsByRemoved(
            in: """
            func refresh() {
                prepare()
                load(); reload(); notify()
            }
            """
        )

        XCTAssertEqual(remainingByRemoved["load();"], "\n    prepare()\n    reload(); notify()")
        XCTAssertEqual(remainingByRemoved["reload();"], "\n    prepare()\n    load(); notify()")
    }

    /// Each mutant's whole statement list, exactly, keyed by the statement it removes.
    private func remainingStatementsByRemoved(in code: String) throws -> [String: String] {
        let source = try sourceCode(code)
        let visitor = RemoveSideEffectsOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source)
        )

        visitor.walk(source)

        return Dictionary(
            uniqueKeysWithValues: visitor.schemataMappings.mutationSchemata.map {
                ($0.snapshot.before, $0.syntaxMutation.description)
            }
        )
    }

    func test_sideEffectsInDoStatement() throws {
        let source = try sourceCode(
            """
            static func validate(_ type: ParsableArguments.Type, parent: InputKey?) -> ParsableArgumentsValidatorError? {
              let argumentKeys: [InputKey] = Mirror(reflecting: type.init())
                .children
                .compactMap { child in
                  guard
                    let codingKey = child.label,
                    let _ = child.value as? ArgumentSetProvider
                    else { return nil }

                  // Property wrappers have underscore-prefixed names
                  return InputKey(name: codingKey, parent: parent)
              }
              guard argumentKeys.count > 0 else {
                return nil
              }
              do {
                let _ = try type.init(from: Validator(argumentKeys: argumentKeys))
                return InvalidDecoderError(type: type)
              } catch let result as Validator.ValidationResult {
                switch result {
                case .missingCodingKeys(let keys):
                  return MissingKeysError(missingCodingKeys: keys)
                case .success:
                  return nil
                }
              } catch {
                fatalError("Unexpected validation error: error")
              }
            }
            """
        )
        let visitor = RemoveSideEffectsOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source)
        )

        visitor.walk(source)

        let rewriter = MuterRewriter(visitor.schemataMappings).rewrite(source)

        AssertSnapshot(formatCode(rewriter.description))
    }

    // A discarded result was recognised by searching the statement's text for `_ = `, so a string
    // literal containing it qualified. Removing `let body = "…_ = …"` leaves `body` undeclared, and
    // since every mutant is compiled into one baseline build, that one mutant broke the whole run.
    func test_doesNotRemoveADeclarationWhoseStringLiteralContainsADiscard() throws {
        let source = try sourceCode(
            """
            func describe(_ value: Int) -> String {
                let body = "_ = \\(value); return true"
                record(value)
                _ = validate(value)
                let _ = check(value)
                return body
            }
            """
        )
        let visitor = RemoveSideEffectsOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source)
        )

        visitor.walk(source)

        let removed = visitor.schemataMappings.mutationSchemata.map(\.snapshot.before)
        XCTAssertEqual(removed.sorted(), ["_ = validate(value)", "let _ = check(value)", "record(value)"])
    }
}
