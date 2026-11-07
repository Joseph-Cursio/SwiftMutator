@testable import muterCore
import SnapshotTesting
import SwiftSyntax
import TestingExtensions
import XCTest

final class RemoveSideEffectsOperatorTests: MuterTestCase {
    private lazy var sourceWithSideEffects = fixtureSource(
        at: "\(fixturesDirectory)/MutationExamples/SideEffect/sampleWithSideEffects.swift"
    )

    func test_visitor() throws {
        let visitor = RemoveSideEffectsOperator.Visitor(
            sourceCodeInfo: sourceWithSideEffects
        )

        visitor.walk(sourceWithSideEffects.code)

        let actualSchemata = visitor.schemataMappings

        assertMutationPositions(
            actualSchemata, [
                MutationPosition(utf8Offset: 80, line: 3, column: 27),
                // Line 10 ends a function that returns an `Int`, so only a call that never returns can be there.
                MutationPosition(utf8Offset: 423, line: 20, column: 62),
                // Lines 30 and 31 declare variables whose string literal contains `_ = `. They used to
                // be removed on that text alone; a declaration is not a side effect to remove.
                MutationPosition(utf8Offset: 906, line: 39, column: 6),
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
        file: StaticString = #filePath,
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

    // Only a call that never returns can end a `guard` body or a function that returns a value, and the
    // project's own, as `usage()`, isn't on the deny-list. Removing it leaves a body that falls through, which
    // doesn't compile, and fails the build every mutant shares. The calls before it are removed as usual.
    func test_keepsTheLastStatement_whereControlMustNotFallThrough() throws {
        let removed = try removedStatements(
            in: """
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
        )

        XCTAssertEqual(removed, [
            "record(arguments)",
            "record(arguments)",
            "record(message)",
            "record(arguments)",
            "usage()",
            "record(arguments)",
            "send(arguments)",
        ])
    }

    // Each statement of a result builder's body is a part of its value, not a call that never returns. A protocol can
    // make a function or a getter of a `some` type one without a mark, as `ViewModifier` does `body(content:)`.
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
                }
            }

            struct Row: View {
                var body: some View {
                    do {
                        Text("a")
                        Text("b")
                    }
                }
            }
            """
        )

        XCTAssertEqual(removed, [
            "sink.note(\"one\")", "sink.note(\"two\")", "content.padding()", "Divider()", "Text(\"a\")", "Text(\"b\")",
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

    // Removing a call on a lock can leave a later call waiting for good, which ends as a timeout. Only four types
    // were known, by a variable made before its use and called by its bare name.
    func test_neverRemovesACallOnALock() throws {
        let removed = try removedStatements(
            in: """
            final class Store {
                func update() {
                    self.lock.lock()
                    write()
                    lock.unlock()
                    semaphore.signal()
                    group.enter()
                    queue.async { self.group.leave() }
                    os_unfair_lock_lock(&unfair)
                    os_unfair_lock_unlock(&unfair)
                    _ = waiter?.wait(timeout: .now())
                    allocated.lock()
                    counter.withLock { $0 += 1 }
                }

                private let lock = NSLock()
                private let semaphore: DispatchSemaphore
                private let group = Foundation.DispatchGroup()
                private var unfair = os_unfair_lock()
                private var waiter: DispatchSemaphore?
                private let allocated = OSAllocatedUnfairLock()
                private let counter = Mutex(0)
            }
            """
        )

        XCTAssertEqual(removed, ["write()", "counter.withLock { $0 += 1 }"])
    }

    // A lock is known by its initializer though its annotation names a protocol, by a generic type, as a static
    // property called after `Self.` or its type, and as a parameter. `withLock` takes no lock that removing it leaves
    // taken, so it's removed, as `Mutex`'s is.
    func test_neverRemovesACallOnALock_declaredOrCalledAnyOtherWay() throws {
        let removed = try removedStatements(
            in: """
            final class Cache {
                private let lock: NSLocking = NSRecursiveLock()
                private let unfair: OSAllocatedUnfairLock<Void>
                private let made = OSAllocatedUnfairLock<()>()
                private static let shared = NSLock()
                private let ready: Optional<DispatchSemaphore> = nil

                func update(_ group: DispatchGroup) {
                    lock.lock()
                    unfair.unlock()
                    made.lock()
                    Self.shared.lock()
                    Cache.shared.unlock()
                    group.leave()
                    ready?.signal()
                    run { (done: DispatchSemaphore) in done.signal() }
                    lock.withLock { store() }
                }
            }
            """
        )

        XCTAssertEqual(removed, ["lock.withLock { store() }"])
    }

    // A lock's method passed by name runs later, as `group.leave` does once the work is done.
    func test_neverRemovesALocksMethodPassedByName() throws {
        let removed = try removedStatements(
            in: """
            final class Loader {
                private let group = DispatchGroup()

                func load() {
                    queue.async(execute: group.leave)
                    queue.async(execute: refresh)
                    actions.append(self.group.leave)
                    handlers.append(contentsOf: [group.leave])
                    register(group.debugDescription)
                    print2("\\(self.group.hash)")
                }
            }
            """
        )

        XCTAssertEqual(removed, [
            "queue.async(execute: refresh)", "register(group.debugDescription)", "print2(\"\\(self.group.hash)\")",
        ])
    }

    /// What each mutant removes, in the source's order.
    private func removedStatements(in code: String, excludeCalls: [String] = []) throws -> [String] {
        let source = try sourceCode(code)
        let visitor = RemoveSideEffectsOperator.Visitor(
            configuration: MuterConfiguration(excludeCallList: excludeCalls),
            sourceCodeInfo: .init(path: "/path/to/file", code: source)
        )

        visitor.walk(source)

        return visitor.schemataMappings.mutationSchemata
            .sorted { $0.position.utf8Offset < $1.position.utf8Offset }
            .map(\.snapshot.before)
    }
}
