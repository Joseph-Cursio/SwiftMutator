@testable import muterCore
import XCTest

/// Compiles the generated code of RemoveSideEffects' mutants in the shapes where removing a call can leave code that
/// doesn't build: a call that never returns, a value, a result builder's part (#112). Each test checks which lines
/// have the operator's mutants, so a fixture can't pass by holding none.
final class RemovedCallShapesTests: GeneratedCodeTestCase {
    /// Code whose last statements are calls that never return, in each place a removal visits, and calls that can be
    /// removed before them, each on a line whose comment names the place.
    private static let usage = """
        func usage() -> Never {
            while true {}
        }

        func record(_ arguments: [String]) {}

        func check(_ arguments: [String]) -> Int {
            guard arguments.count > 1 else {
                record(arguments) // in the guard
                usage()
            }
            return arguments.count
        }

        func value(_ arguments: [String]) -> Int {
            record(arguments) // in the function
            usage()
        }

        func parse(_ arguments: [String]) -> Int {
            guard arguments.count > 2 else {
                do {
                    record(arguments) // in the do
                    usage()
                }
            }
            return arguments.count
        }

        func labeled(_ arguments: [String]) -> Int {
            guard arguments.count > 3 else {
                outer: do {
                    record(arguments) // in the labeled do
                    usage()
                }
            }
            return arguments.count
        }

        func helped(_ arguments: [String]) -> Int {
            record(arguments) // before a local function
            usage()
            func helper() {}
        }

        enum Command { case help, serve }

        func start() throws {}

        func run(_ command: Command) -> Int32 {
            switch command {
            case .help:
                return 0
            case .serve:
                do {
                    try start() // under a try, in a switch
                    record([]) // in a case
                    usage()
                } catch {
                    return 1
                }
            }
        }

        func retry(_ arguments: [String]) -> Int {
            do {
                try start() // under a try before a return
                return 0
            } catch {
                do {
                    record(arguments) // in a catch
                    usage()
                }
            }
        }

        func branch(_ arguments: [String]) -> Int {
            if arguments.isEmpty {
                return 0
            } else if arguments.count > 1 {
                do {
                    record(arguments) // in an else if
                    usage()
                }
            } else {
                return 1
            }
        }

        struct Holder {
            var value: Int {
                do {
                    record([]) // in a getter
                    usage()
                }
            }

            var explicit: Int {
                get {
                    do {
                        record([]) // in an explicit getter
                        usage()
                    }
                }
            }

            let make = { () -> Int in
                do {
                    record([]) // in a closure
                    usage()
                }
            }
        }

        func platform(_ arguments: [String]) -> Int {
            #if canImport(Darwin)
            do {
                record(arguments) // in a #if
                usage()
            }
            #else
            return 0
            #endif
        }

        func pick(_ command: Command) -> Int {
            switch command {
            #if canImport(Darwin)
            case .help:
                do {
                    record([]) // in a conditional case
                    usage()
                }
            #endif
            default:
                return 0
            }
        }

        func before(_ arguments: [String]) -> Int {
            guard arguments.count > 4 else {
                record(arguments) // before a #if
                usage()
                #if os(Linux)
                record(arguments)
                #endif
            }
            return 0
        }

        func trailed(_ arguments: [String]) -> Int {
            do {
                record(arguments) // in a do ahead of a #if
                usage()
            }
            #if DEBUG
            func helper() {}
            #endif
        }

        func notify(_ arguments: [String]) -> Swift.Void {
            record(arguments) // the last of a Void function
        }
    """

    /// RemoveSideEffects removed the call to a function that never returns at the end of a `guard` body or of a
    /// function that returns a value, and left code that falls through: "'guard' body must not fall through" and
    /// "missing return in global function expected to return 'Int'". Only a full build finds the first; a type check
    /// doesn't (#112). The calls before it are still removed.
    func test_theGeneratedCodeBuildsWithoutACallThatNeverReturns() throws {
        let compiled = try compileMutated(["Usage.swift": Self.usage])

        let places = [
            "in the guard", "in the function", "in the do", "in the labeled do", "before a local function", "in a case",
            "in a catch", "in an else if", "in a getter", "in an explicit getter", "in a closure", "in a #if",
            "in a conditional case", "before a #if", "in a do ahead of a #if", "the last of a Void function",
            "under a try, in a switch", "under a try before a return",
        ]
        let removals = compiled.mutants(in: "Usage.swift").filter { $0.mutationOperatorId == .removeSideEffects }
        XCTAssertEqual(removals.count, places.count, "only the calls to record(_:) and start()")
        for place in places {
            XCTAssertEqual(
                compiled.operators(in: "Usage.swift", onTheLineHolding: place),
                [.removeSideEffects],
                place
            )
        }
    }

    private static let bodies = """
        func usage() -> Never {
            while true {}
        }

        func record(_ value: Int) {}
        func describe(_ value: Int) -> String { String(value) }
        func twice(_ value: Int) -> Int { value }
        func start() throws {}
        func refresh() async {}

        class Base {
            init(_ value: Int) {}
        }

        final class Store: Base {
            var count = 0 {
                willSet {
                    record(newValue) // in a willSet
                }
                didSet {
                    record(count) // in a didSet
                }
            }

            var doubled: Int {
                get { count }
                set {
                    record(newValue) // in a setter
                }
            }

            var total: Int {
                twice(count) // a getter's value
            }

            init() {
                record(0) // in an initializer
                super.init(0) // the superclass's initializer
                count = 1
            }

            convenience init(_ count: Int, _ extra: Int) {
                self.init() // the initializer it delegates to
                record(count) // after a delegated initializer
                self.count = extra
            }

            deinit {
                record(0) // in a deinitializer
            }
        }

        func throwing() throws {
            try start() // under a try
            record(1)
        }

        func waiting() async {
            await refresh() // under an await
        }

        func closures(_ values: [Int]) -> [Int] {
            let doubled = values.map { value in
                twice(value) // the one statement of a closure
            }
            let logged = { (value: Int) -> Void in
                record(value) // the one statement of a Void closure
            }
            let checked = values.map { value in
                record(value) // before a closure's value
                return twice(value)
            }
            let ended: (Int) -> Int = { value in
                if value.isMultiple(of: 2) {
                    return value
                }
                record(value) // before a closure's last call
                usage() // the last call of a closure that returns a value
            }
            let choose = { (flag: Bool) in
                if flag {
                    describe(3) // a branch of a closure's one if
                } else {
                    describe(4)
                }
            }
            return doubled + checked + values.map(ended) + [values.map(logged).count, choose(true).count]
        }

        func expressions(_ flag: Bool, _ number: Int) -> String {
            let label = if flag {
                describe(1) // a branch of an if expression
            } else {
                describe(2)
            }
            let name = switch number {
            case 0:
                describe(0) // a case of a switch expression
            default:
                describe(number)
            }
            return label + name
        }

        func handle(_ number: Int) {
            defer {
                record(2) // in a defer
            }
            switch number {
            case 0:
                record(0) // the one statement of a case
            default:
                record(number)
                record(1) // a case's second statement
            }
            if number.isMultiple(of: 3) {
                record(3) // in an if
            } else {
                record(4) // in an else
            }
        }

        func caught() {
            do {
                try start() // beside a catch
            } catch {
                record(5) // in a catch
            }
        }

        struct Failure: Error {}
        enum Kind { case small, big }

        func size(_ number: Int) throws -> Int {
            let size = switch number {
            case 0: 1
            default:
                record(number) // before a throw in a switch expression
                throw Failure()
            }
            return size
        }

        func classify(_ number: Int) throws -> Kind {
            switch number {
            case 0: .small
            default:
                record(number) // before a throw in a function's switch
                throw Failure()
            }
        }

        func make() throws -> Int { 1 }

        func loaded() -> Int {
            let value: Int
            do {
                value = try make()
            } catch {
                usage() // the call a constant relies on
            }
            return value
        }

        func sized(_ number: Int) -> Int {
            let size: Int
            switch number {
            case 0: size = 1
            default: usage() // the call a case's constant relies on
            }
            return size
        }

        struct Settings {
            let level: Int

            init(_ text: String) {
                usage() // an initializer's one statement
            }

            init(level text: String) {
                switch text {
                case "low": level = 0
                default: usage() // a case of an initializer
                }
            }

            init(flag: Bool) {
                if flag {
                    level = 0
                } else {
                    usage() // an else of an initializer
                }
            }

            init(arguments: [String]) {
                if let first = arguments.first, let value = Int(first) {
                    level = value
                    return
                }
                do {
                    record(0) // a do's first call, in init
                    usage() // a do's last call, in init
                }
            }

            init(port text: String) {
                if let value = Int(text) {
                    level = value
                    return
                }
                record(0) // ahead of an initializer's end
                usage() // an initializer's last call
            }
        }

        func numbers(_ number: Int) -> some Equatable {
            switch number {
            case 0: return 1
            default:
                record(number) // before a some function's case end
                usage() // the end of a some function's case
            }
        }

        struct Holder {
            var all: some Equatable {
                if Bool.random() {
                    return 1
                }
                record(1) // ahead of a some getter's end
                usage() // a some getter's last call
            }
        }

        func hidden(_ flag: Bool) throws -> Int {
            if flag {
                1
            } else {
                record(0) // before a throw, #if after
                throw Failure()
            }
            #if compiler(<5.0)
            func helper() {}
            #endif
        }

        func chosen(_ flag: Bool) -> Int {
            let value: Int
            if flag {
                value = 1
            } else {
                usage() // the call an else's constant relies on
            }
            return value
        }

        func flagged(_ number: Int) throws -> Int {
            #if swift(>=5.9)
            switch number {
            case 0: 1
            default:
                record(number) // before a throw in a switch in a #if
                throw Failure()
            }
            #else
            0
            #endif
        }

        func typed() -> Int {
            let failing: () -> Int = {
                record(5) // before a typed closure's last call
                usage() // the last call of a typed closure
            }
            let computed: Int = {
                record(6) // before a called closure's last call
                usage() // the last call of a called closure
            }()
            let inferred = { (value: Int) in
                if value.isMultiple(of: 3) {
                    return value
                }
                record(value) // before an inferred closure's last call
                usage() // the last call of an inferred closure
            }
            return failing() + computed + inferred(1)
        }

        @resultBuilder enum LineBuilder {
            static func buildBlock(_ parts: [String]...) -> [String] { parts.flatMap { $0 } }
            static func buildExpression(_ part: String) -> [String] { [part] }
            static func buildEither(first: [String]) -> [String] { first }
            static func buildEither(second: [String]) -> [String] { second }
        }

        func note(_ text: String) -> String { text }

        @LineBuilder func lines(_ number: Int) -> [String] {
            note("start")
            switch number {
            case 0:
                note("zero") // the one statement of a builder's case
            default:
                note("other")
            }
        }
    """

    /// RemoveSideEffects removes a call from every body, one under `try` or `await` too, but never the one statement
    /// that is the value of a closure, a getter, or a branch of an `if` or `switch` that is a value, nor a call to the
    /// initializer an initializer delegates to. A case it empties gets `do {}`, which a builder takes. A branch of an
    /// `if` or `switch` that is a value isn't touched, as the mutant's switch there makes an `if` statement of it. The
    /// call that may end a branch, a case or a `catch` that definite initialization relies on, an initializer's last
    /// statement, and the last of a closure whose type, call or `return` says it returns a value, are kept (#112).
    func test_theGeneratedCodeBuildsWithACallRemovedFromEveryBody() throws {
        let compiled = try compileMutated(["Bodies.swift": Self.bodies])

        let removed = [
            "in a willSet", "in a didSet", "in a setter", "in an initializer", "after a delegated initializer",
            "in a deinitializer", "under a try", "under an await", "the one statement of a Void closure",
            "before a closure's value", "before a closure's last call", "in a defer", "the one statement of a case",
            "a case's second statement", "in an if", "in an else", "beside a catch", "in a catch",
            "before a typed closure's last call", "before a called closure's last call",
            "the one statement of a builder's case", "ahead of an initializer's end",
            "before an inferred closure's last call", "before a some function's case end",
            "ahead of a some getter's end", "a do's first call, in init",
        ]
        for place in removed {
            XCTAssertEqual(compiled.operators(in: "Bodies.swift", onTheLineHolding: place), [.removeSideEffects], place)
        }
        let kept = [
            "a getter's value", "the superclass's initializer", "the initializer it delegates to",
            "the one statement of a closure", "the last call of a closure that returns a value",
            "a branch of a closure's one if", "a branch of an if expression", "a case of a switch expression",
            "before a throw in a switch expression", "before a throw in a function's switch",
            "the call a constant relies on", "the call a case's constant relies on", "an initializer's one statement",
            "a case of an initializer", "the last call of a typed closure", "the last call of a called closure",
            "an else of an initializer", "an initializer's last call", "the call an else's constant relies on",
            "before a throw in a switch in a #if", "the last call of an inferred closure",
            "the end of a some function's case", "a some getter's last call", "before a throw, #if after",
            "a do's last call, in init",
        ]
        for place in kept {
            XCTAssertEqual(compiled.operators(in: "Bodies.swift", onTheLineHolding: place), [], place)
        }
    }

    /// Some result builders take no `if`: an App's `SceneBuilder` and `RegexBuilder`. A mutant's switch in their
    /// bodies doesn't build, so they get no mutant, their lowercase parts included. In a builder that takes an `if`, a
    /// statement that makes a value of a type, as `ProgressView()` in a `ViewBuilder`'s case does, is a part, and is
    /// never removed (#112).
    func test_theGeneratedCodeBuildsInBuildersThatTakeNoIf() throws {
        #if canImport(SwiftUI) && canImport(RegexBuilder)
        let app = """
        import RegexBuilder
        import SwiftUI

        struct Demo: App {
            var body: some Scene {
                WindowGroup { Text("main") } // the main window
                Settings { Text("settings") }
                extraScene() // a scene a function makes
                Group {
                    extraScene() // a scene in a group
                    note()
                }
                Group {
                    extraScene() // a scene in a modified group
                    note()
                }
                .defaultSize(width: 400, height: 300)
            }

            @SceneBuilder
            func extraScene() -> some Scene {
                WindowGroup("Extra") { Text("extra") }
                note() // a lowercase part of a scene function
            }

            func note() -> some Scene {
                WindowGroup("Note") { Text("note") }
            }
        }

        @available(macOS 13, *)
        func separator() -> Regex<Substring> {
            Regex {
                ZeroOrMore(.whitespace) // a regex component
                ","
                CharacterClass.anyOf(";|") // a regex's factory part
                spaces() // a lowercase regex part
                ZeroOrMore(.whitespace)
            }
        }

        @available(macOS 13, *)
        func spaces() -> some RegexComponent {
            ZeroOrMore(.whitespace)
        }

        @available(macOS 13, *)
        @RegexComponentBuilder
        var pair: some RegexComponent {
            spaces() // a lowercase part of a regex getter
            ","
        }

        @available(macOS 13, *)
        @RegexComponentBuilder
        var plain: Regex<Substring> {
            spaces() // a lowercase part of a regex attribute's getter
            ","
        }

        @available(macOS 13, *)
        func matches(_ line: String) -> Bool {
            line.wholeMatch {
                spaces() // a lowercase part of a match
                ","
            } != nil
        }

        struct Rows: View {
            var state: Int

            var body: some View {
                VStack {
                    Text(state > 1 ? "many" : "one")
                    switch state {
                    case 0: ProgressView() // a view in a case
                    default: Text("done")
                    }
                }
            }
        }
        """
        let compiled = try compileMutated(["App.swift": app])

        let places = [
            "the main window", "a regex component", "a view in a case", "a regex's factory part",
            "a scene a function makes", "a lowercase part of a scene function", "a lowercase regex part",
            "a lowercase part of a regex getter", "a lowercase part of a match", "a scene in a group",
            "a scene in a modified group", "a lowercase part of a regex attribute's getter",
        ]
        for place in places {
            XCTAssertEqual(compiled.operators(in: "App.swift", onTheLineHolding: place), [], place)
        }
        XCTAssertEqual(
            compiled.operators(in: "App.swift", onTheLineHolding: "state > 1"),
            [.ror, .relationalBoundary, .swapTernary]
        )
        #else
        throw XCTSkip("SwiftUI and RegexBuilder are only on Apple's platforms")
        #endif
    }
}
