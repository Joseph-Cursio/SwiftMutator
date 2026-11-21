/// `--project-folder` names a folder the run couldn't move into, such as one it may not open. `validate()` already
/// refused one that isn't a folder.
struct ProjectFolderRefused: Error, Equatable, CustomStringConvertible {
    /// As the flags made it: absolute.
    let path: String

    var description: String {
        "SwiftMutator couldn't move into the project folder \(path), which --project-folder gives. Check that it "
            + "exists and that you may open it."
    }
}
