import Foundation

/// A resumed session's project tree, as what changed since the tree of the session it resumed, whose `treeSHA256` it
/// names: a project's every hash in each session's header made it about 205 KB longer on SwiftProjectLint, where the
/// files seldom change between sessions.
struct ProjectTreeDelta: Codable, Equatable {
    /// The `treeSHA256` of the tree it was recorded against: the last session's.
    let baseTreeSHA256: String
    let listedBy: ProjectTree.Listing
    let excluded: [String]
    /// Each file added or changed since, with its SHA-256, as `ProjectTree.files` has it.
    let files: [String: String]
    /// The paths of the files removed since, sorted.
    let removed: [String]
    /// The `treeSHA256` of the tree it makes.
    let treeSHA256: String
}
