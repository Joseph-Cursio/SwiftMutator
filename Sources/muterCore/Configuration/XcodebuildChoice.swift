/// What an xcodebuild test command opens, builds and tests on, given apart from its `arguments`: by the `workspace`,
/// `project`, `scheme` and `destination` keys, or by the `--workspace`, `--project`, `--scheme` and `--destination`
/// flags. `LoadConfiguration` writes them into the test command's arguments
/// (`MuterConfiguration.choosingXcodebuildOptions(_:in:)`), so every later step reads them there.
struct XcodebuildChoice: Equatable, Sendable {
    /// The workspace, as `-workspace` takes it, relative to the project's folder, so the run opens the one in the copy
    /// it mutates.
    var workspace: String?
    /// The project, as `-project` takes it, relative to the project's folder, as `workspace` is.
    var project: String?
    /// The scheme, as `-scheme` takes it.
    var scheme: String?
    /// Each destination, as `-destination` takes it, in order: mutants are tested on the first. nil when none is given,
    /// never empty.
    var destinations: [String]?

    init(workspace: String? = nil, project: String? = nil, scheme: String? = nil, destinations: [String]? = nil) {
        self.workspace = workspace
        self.project = project
        self.scheme = scheme
        self.destinations = destinations?.isEmpty == true ? nil : destinations
    }

    /// Whether nothing is given.
    var isEmpty: Bool {
        workspace == nil && project == nil && scheme == nil && destinations == nil
    }

    /// The option and the path of the workspace, else the project, as `-workspace App.xcworkspace`; nil for neither.
    var container: (option: String, path: String)? {
        if let workspace {
            return ("-workspace", workspace)
        }
        return project.map { ("-project", $0) }
    }
}
