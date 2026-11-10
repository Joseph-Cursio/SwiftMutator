@testable import muterCore
import XCTest

extension GeneratedEnvironmentCacheTests {
    /// The compiler takes a `#sourceLocation(file:line:)` that opens a location again, but not a `#sourceLocation()`
    /// that closes one when none is open. Each mutant's branch held a copy of the list, so after the first branch
    /// closed the location, every later branch closed it again and failed to compile. Each function here but the
    /// last closes one: in its own list, after a statement on the same line, in a closure, a `case`, a type, a list
    /// with a switch of its own, a multi-line string, a call the list's first mutant removes, a `case` whose line
    /// ends in a comment, a result builder, and before a block comment that code follows on the next line. The last
    /// opens one and closes it in an `#if` clause of a type's members, which swift-syntax parses as unexpected text.
    func test_theGeneratedCodeBuildsAroundSourceLocationDirectives() throws {
        _ = try compileMutatedCheck(alongside: [
            "Located.swift": Self.sourceLocationDirectivesCode,
        ])
    }

    private static let sourceLocationDirectivesCode = """
    #sourceLocation(file: "Located.swift.gyb", line: 1)
    func closed(_ items: [Int]) -> Int {
        let count = items.count > 1 ? 1 : items.count
    #sourceLocation()
        return count
    }
    #sourceLocation(file: "Located.swift.gyb", line: 10)
    func closedAfterAStatement(_ items: [Int]) -> Int {
        let count = items.count > 1 ? 1 : items.count; #sourceLocation()
        return count
    }
    #sourceLocation(file: "Located.swift.gyb", line: 20)
    func closedInAClosure(_ items: [Int]) -> Int {
        let count = items.count > 1 ? 1 : items.count
        let run = { () -> Int in
    #sourceLocation()
            return count
        }
        return run()
    }
    #sourceLocation(file: "Located.swift.gyb", line: 30)
    func closedInACase(_ items: [Int]) -> Int {
        let count = items.count > 1 ? 1 : items.count
        switch count {
        case 1:
    #sourceLocation()
        default:
            return 0
        }
        return count
    }
    #sourceLocation(file: "Located.swift.gyb", line: 40)
    func closedInAType(_ items: [Int]) -> Int {
        let count = items.count > 1 ? 1 : items.count
        struct Box {
            let value = 1
    #sourceLocation()
        }
        return count + Box().value
    }
    #sourceLocation(file: "Located.swift.gyb", line: 50)
    func closedInASwitchOfItsOwn(_ items: [Int]) -> Int {
        let count = items.count > 1 ? 1 : items.count
        if count > 0 {
            let other = count < 5 ? 3 : 4
    #sourceLocation()
            return other
        }
        return count
    }
    #sourceLocation(file: "Located.swift.gyb", line: 60)
    func closedInAMultiLineString(_ items: [Int]) -> String {
        \"""
        \\({ () -> Int in let count = items.count > 1 ? 1 : items.count; return count
        #sourceLocation()
        }())
        \"""
    }
    #sourceLocation(file: "Located.swift.gyb", line: 70)
    func closedInARemovedCall(_ log: (() -> Void) -> Void, _ note: () -> Void) {
        do {
            log {
    #sourceLocation()
            }
            note()
        }
    }
    #sourceLocation(file: "Located.swift.gyb", line: 80)
    func closedAfterACaseLabelsComment(_ items: [Int]) -> Int {
        let count = items.count > 1 ? 1 : items.count
        switch count {
        case 1: // nothing to do
    #sourceLocation()
        default:
            return 0
        }
        return count
    }
    @resultBuilder enum Joined {
        static func buildBlock(_ parts: String...) -> String { parts.joined() }
        static func buildEither(first part: String) -> String { part }
        static func buildEither(second part: String) -> String { part }
    }
    func joined(@Joined _ make: () -> String) -> String { make() }
    #sourceLocation(file: "Located.swift.gyb", line: 90)
    func closedInABuilder(_ items: [Int]) -> String {
        let count = items.count > 1 ? 1 : items.count
        return joined {
            switch count {
            case 1:
    #sourceLocation()
            default:
                "other"
            }
        }
    }
    #sourceLocation(file: "Located.swift.gyb", line: 100)
    func closedBeforeABlockComment(_ items: [Int]) -> Int {
        let count = items.count > 1 ? 1 : items.count
    #sourceLocation() /* a note that runs
    onto the next line */ let other = count < 3
        return other ? count : 0
    }
    func pairedInATypesIf(_ items: [Int]) -> Int {
        let count = items.count > 1 ? 1 : items.count
    #sourceLocation(file: "Located.swift.gyb", line: 110)
        struct Box {
            #if true
            let value = 1
    #sourceLocation()
            #endif
        }
        return count + Box().value
    }
    """
}
