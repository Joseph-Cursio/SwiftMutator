@testable import muterCore
import XCTest

extension RemovedCallShapesTests {
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
}
