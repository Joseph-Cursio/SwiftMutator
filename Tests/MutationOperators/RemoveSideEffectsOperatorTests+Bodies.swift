@testable import muterCore
import SwiftSyntax
import TestingExtensions

extension RemoveSideEffectsOperatorTests {
    func test_removesACallUnderTryOrAwait() throws {
        let removed = try removedStatements(
            in: """
            func load() async throws {
                try validate()
                await refresh()
                try await save()
                try? cleanUp()
                _ = try compute()
            }
            """
        )

        XCTAssertEqual(
            removed, ["try validate()", "await refresh()", "try await save()", "try? cleanUp()", "_ = try compute()"]
        )
    }

    // A function that holds a loop, a `guard` or a `do` loses its own calls too, as each body is a place of its own.
    func test_removesACallFromEveryBody() throws {
        let removed = try removedStatements(in: storeWithACallInEveryKindOfBody)

        XCTAssertEqual(removed, [
            "notify(count)", "load()", "unload()", "prepare()", "handle(item)", "log(item)", "handle(item)",
            "items.forEach { item in log(item) handle(item) }", "warn()", "proceed()", "reset()", "finish()",
            "try commit()", "report(error)",
        ])
    }

    /// A class whose property observer, initializer, deinitializer and every body of one function each make a call.
    private var storeWithACallInEveryKindOfBody: String {
        """
        final class Store {
            var count = 0 {
                didSet { notify(count) }
            }

            init() {
                load()
                count = 1
            }

            deinit {
                unload()
            }

            func run(_ items: [Int]) {
                guard !items.isEmpty else {
                    return
                }
                prepare()
                for item in items {
                    handle(item)
                }
                items.forEach { item in
                    log(item)
                    handle(item)
                }
                if items.isEmpty {
                    warn()
                } else {
                    proceed()
                }
                switch items.count {
                case 0:
                    reset()
                default:
                    break
                }
                defer {
                    finish()
                }
                do {
                    try commit()
                } catch {
                    report(error)
                }
            }
        }
        """
    }

    // A case can't be empty, so the one statement of one gives way to `do {}`, which a result builder takes, as it
    // doesn't take `break`.
    func test_leavesADoNothing_inACaseItEmpties() throws {
        let source = try sourceCode("""
        func handle(_ number: Int) {
            switch number {
            case 0: reset()
            default:
                // the rest
                log(number)
            }
        }
        """)
        let visitor = RemoveSideEffectsOperator.Visitor(sourceCodeInfo: .init(path: "/path/to/file", code: source))

        visitor.walk(source)

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.syntaxMutation.description), [
            "do {}",
            "\n        // the rest\n        do {}",
        ])
    }

    // An initializer that delegates must call the one it delegates to.
    func test_neverRemovesTheInitializerAnInitializerDelegatesTo() throws {
        let removed = try removedStatements(
            in: """
            final class Child: Parent {
                init() {
                    setUp()
                    super.init()
                    ready = true
                }

                convenience init(name: String) {
                    self.init()
                    configure(name)
                    self.name = name
                }

                required init(from decoder: Decoder) throws {
                    try super.init(from: decoder)
                }
            }
            """
        )

        XCTAssertEqual(removed, ["setUp()", "configure(name)"])
    }

    // The one statement of a closure whose type isn't written, of a getter, or of a branch of an `if` or `switch`
    // that is a value, can be that value: removing it leaves none.
    func test_keepsTheOneStatementThatIsAValue() throws {
        let removed = try removedStatements(
            in: """
            func values(_ items: [Int]) -> [Int] {
                let mapped = items.map { transform($0) }
                let logged = items.map { (item: Int) -> Void in log(item) }
                let label = if items.isEmpty { describe(0) } else { describe(1) }
                let name = switch items.count { case 0: describe(0) default: describe(1) }
                let chosen = items.map { item in if item > 0 { describe(item) } else { describe(0) } }
                return mapped
            }

            var total: Int { compute() }

            @ListBuilder var parts: [String] { part() }
            """
        )

        XCTAssertEqual(removed, ["log(item)"])
    }

    // A closure that returns a value can end only in a call that never returns, as a function can. One that returns
    // nothing, whose type isn't written, can end in any call.
    func test_keepsTheLastCallOfAClosureThatReturnsAValue() throws {
        let removed = try removedStatements(
            in: """
            func make() {
                let pick = { (value: Int) in
                    if value > 0 {
                        return value
                    }
                    record(value)
                    usage()
                }
                let run = {
                    record(1)
                    usage()
                }
                use(pick, run)
            }
            """
        )

        XCTAssertEqual(removed, ["record(value)", "record(1)", "usage()", "use(pick, run)"])
    }

    // An `if` or `switch` with a branch of several statements that doesn't end in `throw` is a statement, so its
    // branches lose their calls, though it's the one statement of a closure whose type isn't written.
    func test_removesFromTheBranchesOfAClosuresOneIf_thatIsAStatement() throws {
        let removed = try removedStatements(
            in: """
            func run(_ items: [Int]) {
                items.forEach { item in
                    if item > 0 {
                        log(item)
                        save(item)
                    } else {
                        discard(item)
                    }
                }
            }
            """
        )

        XCTAssertEqual(removed, [
            "log(item)", "save(item)", "discard(item)",
            "items.forEach { item in if item > 0 { log(item) save(item) } else { discard(item) } }",
        ])
    }

    // Outside a result builder, a capitalised name says nothing: a C function is called for its effect.
    func test_removesACallToACapitalisedFunction_outsideABuilder() throws {
        let removed = try removedStatements(
            in: """
            func reset(_ query: CFDictionary) {
                SecItemDelete(query)
                DispatchQueue(label: "q").async { work() }
                Task { await refresh() }
            }
            """
        )

        XCTAssertEqual(removed, [
            "SecItemDelete(query)", "DispatchQueue(label: \"q\").async { work() }", "Task { await refresh() }",
        ])
    }
}
