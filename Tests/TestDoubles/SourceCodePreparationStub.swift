@testable import muterCore

// A test sets it up before the run, and discovery, which prepares several files at once, only reads it.
final class SourceCodePreparationSub: @unchecked Sendable {
    var sourceCodeToReturn: ((String) -> PreparedSourceCode?)?

    func prepare(_ file: String) -> PreparedSourceCode? {
        sourceCodeToReturn?(file)
    }
}
