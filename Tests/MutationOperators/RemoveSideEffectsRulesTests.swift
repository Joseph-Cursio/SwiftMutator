@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

/// Which statements RemoveSideEffects removes, by what they call and where they are.
final class RemoveSideEffectsRulesTests: XCTestCase {
    private func removed(_ code: String, excludeCalls: [String] = []) -> [String] {
        let source = SourceCodeInfo(path: "/path/to/file.swift", code: Parser.parse(source: code))
        let visitor = RemoveSideEffectsOperator.Visitor(
            configuration: MuterConfiguration(excludeCallList: excludeCalls),
            sourceCodeInfo: source
        )
        visitor.walk(source.code)
        return visitor.schemataMappings.mutationSchemata
            .sorted { $0.position < $1.position }
            .map(\.snapshot.before)
    }

    /// The statements removed from a function with `statement` in it, of `statement` and a neighbour.
    private func isRemoved(_ statement: String, excludeCalls: [String] = []) -> Bool {
        removed("func f() {\n    other()\n    \(statement)\n}", excludeCalls: excludeCalls).contains {
            $0.hasSuffix(statement)
        }
    }

    // MARK: Called names

    func test_aCallIsKept_byItsName_notByItsText() {
        for statement in ["printer.flush()", "exitEditing()", "editor.exit()", "foo.print(x)", "blueprint()"] {
            XCTAssertTrue(isRemoved(statement), statement)
        }
        for statement in ["print(x)", "Swift.print(x)", "exit(0)", "Foundation.exit(0)", "`print`(x)"] {
            XCTAssertFalse(isRemoved(statement), statement)
        }
    }

    func test_aCommentOrAStringThatNamesACall_keepsNothing() {
        XCTAssertEqual(
            removed("func f() {\n    // print the state\n    reload()\n}"),
            ["// print the state\n    reload()".inlined]
        )
        XCTAssertTrue(isRemoved(#"track("exit")"#))
    }

    func test_aDiscardedCallIsKept_byItsName() {
        for statement in ["_ = print(x)", "_ = exit(0)", "let _ = fatalError(\"x\")"] {
            XCTAssertFalse(isRemoved(statement), statement)
        }
        XCTAssertTrue(isRemoved("_ = printer.flush()"))
    }

    func test_aCallInsideAStatement_keepsIt() {
        for statement in ["items.forEach { print($0) }", "foo(print(x))", "queue.async { exit(0) }"] {
            XCTAssertFalse(isRemoved(statement), statement)
        }
    }

    func test_callsThatOnlyCheckOrReport_areKept() {
        for name in RemoveSideEffectsOperator.Visitor.alwaysExcludedCalls {
            XCTAssertFalse(isRemoved("\(name)(x)"), name)
        }
        let statements = [
            "MainActor.assertIsolated()", "self.preconditionIsolated()", "await Task.yield()",
            "lines.reserveCapacity(count)",
        ]
        for statement in statements {
            XCTAssertFalse(isRemoved(statement), statement)
        }
    }

    func test_excludeCalls_matchesWholeNames() {
        let kept: [(entry: String, statement: String)] = [
            ("log", "log()"),
            ("log", "log.debug()"),
            ("log", "Logger.log()"),
            ("exit", "editor.exit()"),
            ("Logger.log", "Logger.log()"),
            ("log.debug", "self.log.debug()"),
            ("self.log", "log()"),
            ("log()", "log()"),
            ("logger", "logger.debug()"),
        ]
        for (entry, statement) in kept {
            XCTAssertFalse(isRemoved(statement, excludeCalls: [entry]), "\(entry) keeps \(statement)")
        }
        let removedByTheirNames: [(entry: String, statement: String)] = [
            ("log", "logger.debug()"),
            ("log", "catalog.reload()"),
            ("DDLog", "DDLogInfo()"),
            ("Logger.log", "log()"),
        ]
        for (entry, statement) in removedByTheirNames {
            XCTAssertTrue(isRemoved(statement, excludeCalls: [entry]), "\(entry) doesn't keep \(statement)")
        }
    }

    // MARK: try and await

    func test_aCallUnderTryOrAwait_isRemoved() {
        for statement in ["try save()", "try? a()", "try! b()", "await c()", "try await d()", "try _ = e()"] {
            XCTAssertTrue(isRemoved(statement), statement)
        }
        for statement in ["try print(x)", "await exit(0)", "try foo() + 1", "try a.b = foo()"] {
            XCTAssertFalse(isRemoved(statement), statement)
        }
    }

    // MARK: Locks

    func test_aCallOnALock_isKept_wheneverAndHoweverItIsDeclared() {
        let declarations = [
            "let lock = NSLock()",
            "let lock = Foundation.NSLock()",
            "let lock: NSLock",
            "var lock: NSLock?",
            "let lock = DispatchSemaphore(value: 0)",
            "let lock = DispatchGroup()",
            "let lock = NSCondition.init()",
        ]
        for declaration in declarations {
            let body = "func f() {\n        other()\n        self.lock.wait()\n    }"
            let after = "struct S {\n    \(body)\n    \(declaration)\n}"
            XCTAssertEqual(removed(after), ["other()"], declaration)
            let before = "struct S {\n    \(declaration)\n    func f() {\n        lock.signal(); other()\n    }\n}"
            XCTAssertEqual(removed(before), ["other()"], declaration)
        }
    }

    func test_aLockGivenAsAParameterOrMadeInTheSameBody_isKept() {
        XCTAssertEqual(removed("func f(s: DispatchSemaphore) {\n    s.wait()\n    other()\n}"), ["other()"])
        XCTAssertEqual(removed("func f() {\n    let s = NSLock()\n    s.bump()\n    other()\n}"), ["other()"])
    }

    func test_aLockFunctionOrALocksOwnNames_areKept() {
        for statement in [
            "os_unfair_lock_lock(&l)", "pthread_mutex_unlock(&m)", "thing.lock()", "unlock()", "x.tryLock()",
            "_ = semaphore.signal()", "queue.async { lock.unlock() }", "continuation.resume()",
        ] {
            let code = "let semaphore = DispatchSemaphore(value: 0)\nfunc f() {\n    other()\n    \(statement)\n}"
            XCTAssertEqual(removed(code), ["other()"], statement)
        }
    }

    func test_withLock_isRemoved_asItTakesItsBodyWithIt() {
        XCTAssertTrue(isRemoved("lock.withLock { update() }"))
        XCTAssertFalse(isRemoved("lock.withLock { other.unlock() }"))
    }

    // MARK: Where a statement is

    func test_everyStatementOfABodyThatEndsFreely_isRemoved() {
        let bodies = [
            "func f() { %@ }",
            "func f() -> Void { %@ }",
            "func f() -> () { %@ }",
            "func f() { for x in xs { %@ } }",
            "func f() { while c { %@ } }",
            "func f() { repeat { %@ } while c }",
            "func f() { if c { %@ } }",
            "func f() { if c { x() } else { %@ } }",
            "func f() { if c { x() } else if d { %@ } }",
            "func f() { switch c { case 1: %@ default: break } }",
            "func f() { do { %@ } }",
            "func f() { do { try y() } catch { %@ } }",
            "func f() { defer { %@ } }",
            "deinit { %@ }",
            "var x: Int { get { 1 } set { %@ } }",
            "var x: Int = 1 { didSet { %@ } }",
            "var x: Int = 1 { willSet { %@ } }",
            "var x: Void { %@ }",
            "let c: () -> Void = { () -> Void in %@ }",
        ]
        for body in bodies {
            let code = body.replacingOccurrences(of: "%@", with: "work()")
            XCTAssertTrue(removed(code).contains("work()"), code)
        }
    }

    func test_theFunctionsOwnCalls_areRemoved_besideALoopOrAGuard() {
        let code = """
        func f(_ xs: [Int]) {
            first()
            for x in xs { use(x) }
            guard !xs.isEmpty else { return }
            last()
        }
        """
        XCTAssertEqual(removed(code), ["first()", "use(x)", "last()"])
    }

    func test_theLastStatement_ofWhatMustNotFallThrough_isKept() {
        let bodies = [
            "func f() -> Int { %@ }",
            "func f() -> Int { x(); %@ }",
            "func f() -> Never { %@ }",
            "func f() { guard c else { %@ } }",
            "func f() -> Int { if c { %@ } else { return 1 } }",
            "func f() -> Int { if c { return 1 } else if d { return 2 } else { %@ } }",
            "func f() -> Int { switch c { case 1: %@ default: return 1 } }",
            "func f() -> Int { do { return try y() } catch { %@ } }",
            "func f() -> Int { do { %@ } }",
            "func f() { guard c else { if d { return } else { %@ } } }",
            "func f() { guard c else { switch d { case 1: return default: %@ } } }",
            "func f() -> Int { l: if c { %@ } else { return 1 } }",
            "var x: Int { %@ }",
            "var x: Int { get { %@ } }",
            "subscript(i: Int) -> Int { %@ }",
            "let c: () -> Int = { () -> Int in %@ }",
            """
            func f() -> Int {
                #if DEBUG
                if c { %@ } else { return 1 }
                #else
                return 2
                #endif
            }
            """,
            """
            func f() -> Int {
                switch c {
                #if DEBUG
                case 1: %@
                #endif
                default: return 1
                }
            }
            """,
        ]
        for body in bodies {
            let code = body.replacingOccurrences(of: "%@", with: "work()")
            XCTAssertFalse(removed(code).contains("work()"), code)
        }
    }

    func test_aStatementBeforeTheEnd_ofWhatMustNotFallThrough_isRemoved() {
        XCTAssertEqual(
            removed("func f() -> Int {\n    a()\n    if c { b(); d() }\n    return 1\n}"),
            ["a()", "b();", "d()"]
        )
        XCTAssertEqual(removed("func f() {\n    guard c else {\n        a()\n        return\n    }\n}"), ["a()"])
        XCTAssertEqual(removed("func f() -> Int { if c { a(); never() } else { return 1 } }"), ["a();"])
    }

    func test_aBranchOfAValue_isKept() {
        for body in [
            "let x = if c { work() } else { 1 }",
            "func f() -> Int { return if c { work() } else { 1 } }",
            "let x = switch c { case 1: work() default: 1 }",
        ] {
            XCTAssertEqual(removed(body), [], body)
        }
    }

    func test_aResultBuildersLastStatement_isRemoved_butNotItsOnlyOne() {
        XCTAssertEqual(removed("@ListBuilder func f() -> [Int] {\n    a()\n    b()\n}"), ["a()", "b()"])
        XCTAssertEqual(removed("@ListBuilder func f() -> [Int] {\n    a()\n}"), [])
    }

    func test_superInitAndSelfInit_areKept_andCallsAroundThem_removed() {
        let code = """
        class A: B {
            override init() {
                before()
                super.init()
                after()
            }
            convenience init(x: Int) {
                self.init()
            }
            required init(from decoder: Decoder) throws {
                try super.init(from: decoder)
            }
        }
        """
        XCTAssertEqual(removed(code), ["before()", "after()"])
    }

    // MARK: Closures

    func test_aClosuresOnlyStatement_isRemoved_onlyInACallKnownToIgnoreItsValue() {
        for statement in [
            "xs.forEach { work() }",
            "Task { await work() }",
            "Task.detached { work() }",
            "queue.async { work() }",
            "queue.asyncAfter(deadline: d) { work() }",
            "queue.sync { work() }",
            "lock.withLock { work() }",
            "Button(\"a\") { work() }",
            "Button(\"a\", action: { work() })",
            "try await withTaskCancellationHandler { work() } onCancel: { other() }",
        ] {
            let code = "func f() {\n    \(statement)\n}"
            XCTAssertTrue(removed(code).contains { $0.hasSuffix("work()") }, statement)
        }
    }

    func test_aClosuresOnlyStatement_isKept_whereItMayBeItsValue() {
        for statement in [
            "xs.map { work() }",
            "let c: () -> Void = { work() }",
            "register(Foo.self) { work() }",
            "let c = { work() }",
            "let t = Task { work() }",
            "_ = Task { work() }",
            "Task<Int, Never> { work() }",
            "run { work() }",
            "xs.sorted { work() }",
            "Button { x() } label: { work() }",
        ] {
            let code = "func f() {\n    \(statement)\n}"
            XCTAssertFalse(removed(code).contains("work()"), statement)
        }
        // The `Task` is the value of what is around it.
        XCTAssertFalse(removed("func f() -> Task<Int, Never> {\n    Task { work() }\n}").contains("work()"))
        XCTAssertFalse(removed("func f() {\n    xs.map { x in Task { work() } }\n}").contains("work()"))
    }

    func test_aClosuresStatements_areRemoved_whenThereAreSeveral() {
        XCTAssertEqual(removed("let c = {\n    a()\n    b()\n}"), ["a()", "b()"])
        XCTAssertEqual(removed("let c = {\n    a()\n    return 1\n}"), ["a()"])
    }

    func test_whatBuildsAValue_inAClosureOrAGetter_isKept() {
        XCTAssertEqual(removed("let v = VStack {\n    Text(\"a\").font(.x)\n    Spacer()\n    row()\n}"), ["row()"])
        XCTAssertEqual(removed("var body: some Scene {\n    WindowGroup { }\n    Settings { }\n}"), [])
        XCTAssertEqual(removed("let v = VStack {\n    if c {\n        Text(\"a\")\n        row()\n    }\n}"), ["row()"])
    }

    func test_aCapitalizedCall_isRemoved_elsewhere() {
        XCTAssertEqual(removed("func f() {\n    Server(port: 1).start()\n}"), ["Server(port: 1).start()"])
        XCTAssertEqual(
            removed("let c = {\n    for x in xs {\n        Server(port: x).start()\n        y()\n    }\n}"),
            ["Server(port: x).start()", "y()"]
        )
        XCTAssertEqual(
            removed("let c = {\n    DispatchQueue.main.flush()\n    y()\n}").first,
            "DispatchQueue.main.flush()"
        )
    }

    func test_aListInAMacrosArguments_isLeftAlone() {
        XCTAssertEqual(removed("func f() {\n    #expect { for x in xs { work(x) } }\n}"), [])
    }

    func test_anOpaqueBodysOwnStatements_areLeft_toKeepTheMutantsInItsNestedLists() {
        let code = "func f() -> some View {\n    a()\n    for x in xs { work(x) }\n    return Text(\"a\")\n}"
        XCTAssertEqual(removed(code), ["work(x)"])
    }

    func test_eachListIsVisitedOnce() {
        let code = """
        func f() {
            do {
                for x in xs {
                    guard c else {
                        a()
                        return
                    }
                    while d { b() }
                }
            } catch {
                c()
            }
        }
        """
        XCTAssertEqual(removed(code), ["a()", "b()", "c()"])
    }

    func test_aFileItsTopLevelAndAnIfConfigClause_areLeftAlone() {
        XCTAssertEqual(removed("work()\n"), [])
        XCTAssertEqual(removed("func f() -> Int {\n    #if DEBUG\n    work()\n    #endif\n    return 1\n}"), [])
    }

    // MARK: What a value may hang on

    // With the clause off, `name(x)` is the closure's value, and removing it changes the type other files read.
    func test_aStatementBesideAnIfConfig_isStillAClosuresOnlyOne() {
        let value = "let a = xs.map { x in\n    #if os(Linux)\n    prep(x)\n    #endif\n    name(x)\n}"
        XCTAssertEqual(removed(value), [])
        let ignored = "queue.async {\n        #if DEBUG\n        a()\n        #endif\n        b()\n    }"
        XCTAssertEqual(
            removed("func f() {\n    \(ignored)\n}"),
            ["b()", "queue.async { #if DEBUG a() #endif b() }"]
        )
    }

    func test_aCallInAnIfConfigClause_mayBeTheValueOfWhatsAroundIt() {
        let value = "var v: Int {\n    #if DEBUG\n    lock.withLock { value() }\n    #else\n    0\n    #endif\n}"
        XCTAssertEqual(removed(value), [])
        XCTAssertEqual(removed("func f() {\n    #if DEBUG\n    queue.async { work() }\n    #endif\n}"), ["work()"])
    }

    func test_aClosureWithASignOfGivingAValue_keepsItsLastStatement() {
        let declared = "let db: Database = {\n    log()\n    do { return try Database() } catch { die(error) }\n}()"
        XCTAssertEqual(removed(declared), ["log()"])
        XCTAssertEqual(removed("let f: () -> Int = {\n    log()\n    usage()\n}"), ["log()"])
        let branches = "let g: (Bool) -> Int = { c in\n    log()\n    if c { return 1 } else { usage() }\n}"
        XCTAssertEqual(removed(branches), ["log()"])
        XCTAssertEqual(removed("let h = {\n    a()\n    let k = { return 1 }\n    b()\n}"), ["a()", "b()"])
    }

    func test_anOnlyStatementThatStandsInForWhatABodyMustDo_isKept() {
        let initializer = "class C {\n    required init?(coder: NSCoder) {\n        notImplemented()\n    }\n}"
        XCTAssertEqual(removed(initializer), [])
        XCTAssertEqual(removed("struct S {\n    init() {\n        a()\n        b()\n    }\n}"), ["a()", "b()"])
        XCTAssertEqual(removed("var x: Int {\n    get { y }\n    _modify {\n        usage()\n    }\n}"), [])
    }

    func test_anOnlyStatementOfAClosure_isKeptThroughAnIf() {
        let code = "func g(_ xs: [Int]) -> [Int] {\n    xs.map { x in if x > 0 { value() } else { 1 } }\n}"
        XCTAssertEqual(removed(code), [])
    }

    func test_whatABuilderFunctionMakes_isKept() {
        XCTAssertEqual(removed("@SceneBuilder func s() -> some Scene {\n    WindowGroup { }\n    Settings { }\n}"), [])
        XCTAssertEqual(removed("@ViewBuilder func r() -> some View {\n    Text(\"a\")\n    Text(\"b\").tag(1)\n}"), [])
    }

    func test_aButtonsLabel_isKept_howeverItIsWritten() {
        let buttons = ["Button(action: { act() }) { makeLabel() }", "Button(action: { act() }, label: { makeLabel() })"]
        for button in buttons {
            XCTAssertEqual(removed("VStack {\n    \(button)\n    Text(\"b\")\n}"), ["act()"], button)
        }
    }

    // MARK: Receivers

    func test_aCallOnAValueWithNoName_isNotOneOnNoValue() {
        for statement in ["handle(.exit(0))", #""hello".print()"#, "(a ?? b).exit()"] {
            XCTAssertTrue(isRemoved(statement), statement)
        }
    }

    func test_aFunctionPassedByName_countsAsCalled() {
        XCTAssertFalse(isRemoved("queue.async(execute: lock.unlock)"))
        XCTAssertFalse(isRemoved("items.forEach(log)", excludeCalls: ["log"]))
        XCTAssertTrue(isRemoved("style(.lock)"))
    }

    func test_moreWaysOfNamingALock_keepItsCalls() {
        let closure = "func f() {\n    run { (s: DispatchSemaphore) in\n        other()\n        s.signal()\n    }\n}"
        XCTAssertEqual(removed(closure), ["other()"])
        XCTAssertEqual(removed("func g(s: inout DispatchSemaphore) {\n    other()\n    s.signal()\n}"), ["other()"])
        XCTAssertFalse(isRemoved("continuations.removeFirst().resume()"))
        XCTAssertFalse(isRemoved("os_unfair_lock_assert_owner(&l)"))
    }
}
