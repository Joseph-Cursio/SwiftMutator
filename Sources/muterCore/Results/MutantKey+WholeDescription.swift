import Foundation

extension MutantKey {
    /// The key `text` spells whole, as `description` prints one; nil for anything that leaves out its column or
    /// operator, as a `MutantReference` may.
    init?(wholeDescription text: String) {
        guard let reference = try? MutantReference.parse(text),
              let column = reference.column,
              let mutationOperatorId = reference.mutationOperatorId
        else { return nil }
        self.init(
            path: reference.path,
            mutationOperatorId: mutationOperatorId,
            line: reference.line,
            column: column,
            occurrence: reference.occurrence ?? 0
        )
    }
}
