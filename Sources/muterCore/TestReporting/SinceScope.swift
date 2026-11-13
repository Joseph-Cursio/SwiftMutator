/// The part of the project a `--since` run mutated, as its reports say.
struct SinceScope: Codable, Equatable {
    let ref: String
    let mergeBase: String
    let changedLines: Bool

    init(_ selection: ChangeSelection) {
        ref = selection.ref
        mergeBase = selection.mergeBase
        changedLines = selection.changedLines
    }

    /// "Only the code changed since the merge base of main and HEAD (abc1234) was mutated."
    var sentence: String {
        "Only the \(changedLines ? "lines" : "files") changed since the merge base of \(ref) and HEAD "
            + "(\(mergeBase.prefix(7))) were mutated."
    }
}
