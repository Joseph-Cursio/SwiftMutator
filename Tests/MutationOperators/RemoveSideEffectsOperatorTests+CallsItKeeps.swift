@testable import muterCore
import SnapshotTesting
import SwiftSyntax
import TestingExtensions
import XCTest

extension RemoveSideEffectsOperatorTests {
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

    // The deny-list was searched for in the statement's text, comments included, so `printer.flush()`,
    // `exitEditing()` and a call under a comment that mentions print were never removed. It's now matched by the
    // name a call is called by.
    func test_matchesTheCallsItNeverRemoves_byTheNameTheyAreCalledBy() throws {
        let removed = try removedStatements(
            in: """
            func finish(_ printer: Printer, _ editor: Editor, _ logger: Logger) {
                print("done")
                Swift.print("done")
                debugPrint(printer)
                printer.flush()
                printer.print("page")
                editor.exitEditing()
                // Don't print anything after this.
                save()
                items.forEach { print($0) }
                logger.debug("x")
                self.logger.debug("y")
                log("z")
                Log.log("w")
                catalog.update()
                exit(0)
                Darwin.exit(1)
            }
            """,
            excludeCalls: ["log", "logger.debug"]
        )

        XCTAssertEqual(removed, [
            "printer.flush()",
            "printer.print(\"page\")",
            "editor.exitEditing()",
            "// Don't print anything after this. save()",
            "catalog.update()",
        ])
    }

    // A function passed by name is called too, and the old text search kept it, with or without its argument labels.
    // `super.` calls the excluded method as `self.` does. An entry written as the code reads, `logger?.debug`, still
    // matches, and `.debug` passed as a value isn't a call of `debug`.
    func test_matchesAFunctionPassedByName_aSuperCall_andAnEntryWithAnOptionalChain() throws {
        let removed = try removedStatements(
            in: """
            func finish(_ lines: [String]) {
                lines.forEach(log)
                lines.forEach(log(_:))
                lines.forEach(Logger.log(_:))
                super.log("x")
                logger?.debug("y")
                send(level: .debug)
                lines.forEach(printer.log)
            }
            """,
            excludeCalls: ["log", "logger?.debug", "debug"]
        )

        XCTAssertEqual(removed, ["send(level: .debug)", "lines.forEach(printer.log)"])
    }

    // Tests rarely take an assertion's failing path, so removing one nearly always survives.
    func test_neverRemovesAnAssertion() throws {
        let removed = try removedStatements(
            in: """
            func update(_ value: Int) {
                assert(value > 0)
                assertionFailure("unexpected")
                precondition(value < 10)
                preconditionFailure("unreachable")
                store(value)
            }
            """
        )

        XCTAssertEqual(removed, ["store(value)"])
    }
}
