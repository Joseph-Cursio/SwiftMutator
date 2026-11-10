import Foundation

/// Where a result that a session reused from an earlier run's results file (`--reuse`) was tested, and whether changes
/// were let through on the way: by the reusing session, by any session that resumed the run after it was tested, or by
/// an earlier reuse of it. Each of those sessions' headers says which (`waived`, `forced`).
struct ReusedFrom: Codable, Equatable {
    /// The results file it was tested in, and the session there that tested it.
    let resultsFile: String
    let session: Int
    /// Whether `--resume-ignoring`, `--reuse-ignoring`, `--force-resume` or `--force-reuse` let a change through since
    /// it was tested, which the reports mark; written only when it did (`TrueOrAbsent`).
    @TrueOrAbsent var despiteChanges: Bool
}
