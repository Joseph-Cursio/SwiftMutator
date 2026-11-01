import Foundation

/// A `--since` run with nothing left to mutate. Not a failure: SwiftMutator says why and exits with 0, writing no
/// report or results file, so a CI job on a change that touches no Swift code passes.
struct NothingToMutate: Error, Equatable, CustomStringConvertible {
    enum Reason: Equatable {
        /// No Swift file changed.
        case noSwiftFileChanged
        /// Every changed Swift file is excluded, by the defaults or the configuration's `exclude`.
        case everyFileExcluded(count: Int)
        /// No target compiles any of the changed files that weren't excluded.
        case noTargetCompiles(count: Int)
        /// None of the changed files that weren't excluded is one discovery would mutate: no target compiles it, or
        /// it has no coverage, or too little.
        case noFileDiscovered(count: Int)
        /// No operator mutates any code in the changed files that discovery kept, as in a change to declarations.
        case noMutantInChangedFiles(count: Int)
        /// With `--changed-lines`: no mutant is on a line the change added or changed.
        case noMutantOnChangedLines
    }

    let reason: Reason
    let selection: ChangeSelection

    var description: String {
        let since = "since the merge base of \(selection.ref) and HEAD (\(selection.shortMergeBase))"
        let why: String
        switch reason {
        case .noSwiftFileChanged:
            why = "No Swift file changed \(since)"
        case let .everyFileExcluded(count):
            why = "\(files(count)) changed \(since), and the excludes leave out \(count == 1 ? "it" : "every one")"
        case let .noTargetCompiles(count):
            why = "\(files(count)) changed \(since), and no target compiles \(count == 1 ? "it" : "any of them")"
        case let .noFileDiscovered(count):
            why = "\(files(count)) changed \(since), and discovery leaves out \(count == 1 ? "it" : "every one"): "
                + "no target compiles \(count == 1 ? "it" : "them"), or the tests don't cover \(count == 1 ? "it" : "them")"
        case let .noMutantInChangedFiles(count):
            why = "\(files(count)) changed \(since), and no operator mutates any code in "
                + (count == 1 ? "it" : "them")
        case .noMutantOnChangedLines:
            why = "No mutant is on a line added or changed \(since)"
        }
        return "ℹ️ \(why), so there is nothing to mutate."
    }

    private func files(_ count: Int) -> String {
        count == 1 ? "1 Swift file" : "\(count) Swift files"
    }
}
