@testable import muterCore
import XCTest

/// Compiles the generated code of RemoveSideEffects' mutants in the shapes where removing a call can leave code that
/// doesn't build: a call that never returns, a value, a result builder's part (#112). Each test checks which lines
/// have the operator's mutants, so a fixture can't pass by holding none.
final class RemovedCallShapesTests: GeneratedCodeTestCase {
    /// Without ReplaceReturnValue: its empty value in place of `return doubled + ...` leaves the local `doubled`
    /// never used, which warns, and these files compile with warnings as errors. Its own shapes compile in
    /// GeneratedCodeShapesTests.
    override var operatorsToDiscoverWith: MutationOperatorList {
        super.operatorsToDiscoverWith.filter { $0 != .replaceReturnValue }
    }

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
}
