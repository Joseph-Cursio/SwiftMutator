@testable import muterCore
import SnapshotTesting
import SwiftSyntax
import TestingExtensions
import XCTest

extension RemoveSideEffectsOperatorTests {
    // Only a call that never returns can end a `guard` body or a function that returns a value, and the
    // project's own, as `usage()`, isn't on the deny-list. Removing it leaves a body that falls through, which
    // doesn't compile, and fails the build every mutant shares. The calls before it are removed as usual.
    func test_keepsTheLastStatement_whereControlMustNotFallThrough() throws {
        let removed = try removedStatements(in: functionsEndingInACallThatMayReturn)

        XCTAssertEqual(removed, [
            "record(arguments)",
            "record(arguments)",
            "record(message)",
            "try validate(arguments)",
            "record(arguments)",
            "usage()",
            "record(arguments)",
            "send(arguments)",
        ])
    }

    /// Functions ending in a call that may return, where falling through would or wouldn't compile.
    private var functionsEndingInACallThatMayReturn: String {
        """
        func check(_ arguments: [String]) -> Int {
            guard arguments.count > 1 else {
                record(arguments)
                usage()
            }
            return arguments.count
        }

        func value(_ arguments: [String]) -> Int {
            record(arguments)
            usage()
        }

        func fail(_ message: String) -> Never {
            record(message)
            stop(message)
        }

        func parse(_ arguments: [String]) -> Int {
            do {
                try validate(arguments)
                usage()
            }
        }

        func notify(_ arguments: [String]) {
            record(arguments)
            usage()
        }

        func retry(_ arguments: [String]) -> Int {
            do {
                record(arguments)
                send(arguments)
            }
            return 0
        }
        """
    }

    // Each statement of a result builder's body is a part of its value, not a call that never returns. A protocol can
    // make a function or a getter of a `some` type one without a mark, as `ViewModifier` does `body(content:)`. A part
    // that is a value of a type, as `Divider()`, `Text("a")` and `Label.styled("a")` are, isn't a side effect, and is
    // never removed there.
    func test_removesTheLastStatementOfAResultBuilder() throws {
        let removed = try removedStatements(
            in: """
            @ListBuilder
            func items(_ sink: Sink) -> [String] {
                sink.note("one")
                sink.note("two")
            }

            struct Separated: ViewModifier {
                func body(content: Content) -> some View {
                    content.padding()
                    Divider()
                    separator(content)
                }
            }

            struct Row: View {
                var body: some View {
                    do {
                        Text("a")
                        Label.styled("a")
                        Text(title.uppercased()).bold()
                        Image("x").resizable().frame(width: 1)
                        label("a")
                        label("b")
                    }
                }
            }
            """
        )

        XCTAssertEqual(removed, [
            "sink.note(\"one\")", "sink.note(\"two\")", "content.padding()", "separator(content)", "label(\"a\")",
            "label(\"b\")",
        ])
    }

    // A `#if` may end the code in one build and not in another: on macOS, `#if os(Linux)` holds nothing, and
    // `usage()` ends the guard. So the statement before a `#if` that ends the code is kept, though here
    // `record(flag)` could go. A `#if` holding only declarations is skipped as they are.
    func test_keepsTheStatementBeforeAnIfConfigThatEndsTheCode() throws {
        let removed = try removedStatements(
            in: """
            func value(_ flag: Bool) -> Int {
                record(flag)
                #if DEBUG
                return 1
                #else
                return 2
                #endif
            }

            func check(_ ok: Bool) {
                guard ok else {
                    record(ok)
                    usage()
                    #if os(Linux)
                    flush()
                    #endif
                }
            }

            func usageOnly() -> Int {
                record(0)
                usage()
                #if DEBUG
                func trace() {}
                #endif
            }
            """
        )

        XCTAssertEqual(removed, ["record(ok)", "record(0)"])
    }
}
