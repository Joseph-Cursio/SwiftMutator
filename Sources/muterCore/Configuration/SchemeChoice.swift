/// The scheme `init` wrote, of those `xcodebuild -list` named.
struct SchemeChoice: Equatable {
    let chosen: String
    /// Every scheme listed, in the order listed; empty when none was.
    let listed: [String]
    /// The workspace's or project's name, which a scheme of that name is taken for.
    let containerName: String

    /// Whether it is a guess worth saying: there was no scheme to take, or several, and none named after the
    /// workspace or project.
    var isAGuess: Bool {
        listed.isEmpty || listed.count > 1 && chosen != containerName
    }

    /// The scheme named after the workspace or project, else the only one, else the first listed. With none listed,
    /// the workspace's or project's name, as `init` guessed before it listed them.
    init(listed: [String], containerName: String) {
        self.listed = listed
        self.containerName = containerName
        chosen = listed.contains(containerName) ? containerName : listed.first ?? containerName
    }
}
