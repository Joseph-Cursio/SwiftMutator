import Foundation

/// A mutant discovery found but can't test: its switch has nowhere to go in the build every mutant shares, or its code
/// isn't in the build at all. It is in no mapping, so without this nothing would say a report covers less code than it
/// seems to.
struct DroppedMutant: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// At a file's or a type's top level, in code that can hold no switch: a macro alone, an attribute's arguments,
        /// a `guard let` or `guard case`, a value that starts with `#line`, or a non-escaping function's default.
        case noPlaceForASwitch
        /// In a block nested in a `some` body with mutants of its own, or in a builder closure in a value with mutants
        /// of its own, where a nested switch could change the type of one branch of the `if` expression around it.
        case nestedInAnOpaqueBody
        /// In an `#if` branch the build leaves out, so no test can reach it, and it could only survive.
        case inInactiveIfConfig
    }

    /// Relative to the project.
    let path: String
    let mutationOperatorId: MutationOperator.Id
    let position: MutationPosition
    let snapshot: MutationOperator.Snapshot
    /// The lines of the code it changes, which `--changed-lines` checks.
    let lines: ClosedRange<Int>?
    let reason: Reason

    /// `Sources/App/main.swift:9:19 RelationalOperatorReplacement (changed > to !=): nested in …`
    var line: String {
        let change = snapshot.description.isEmpty ? "" : " (\(snapshot.description))"
        let why = switch reason {
        case .noPlaceForASwitch: "in code at a file's or a type's top level that can hold no switch"
        case .nestedInAnOpaqueBody: "nested in a `some` body or a value that has mutants of its own"
        case .inInactiveIfConfig: "in an `#if` branch this build doesn't compile"
        }
        return "\(path):\(position.line):\(position.column) \(mutationOperatorId.rawValue)\(change): \(why)"
    }
}
