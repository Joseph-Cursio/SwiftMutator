import Foundation

/// A project's files as git sees them: tracked, and untracked but not ignored, by the project's own ignore files and
/// the user's global ones.
enum GitFileListing {
    /// How many repositories deep nested ones are listed by their own git; deeper ones are walked.
    private static let maximumDepth = 4

    /// `git ls-files` on `directory`, or nil if git fails (no repository, git missing, killed), or if `directory` is in
    /// a folder its repository ignores. A folder entry (a submodule, or an untracked nested repository listed as
    /// `dir/`) is replaced by its own listing, prefixed; failing that, by a walk. Depth 4 at most.
    static func list(in directory: URL) async -> [String]? {
        guard await !isIgnoredByItsRepository(directory) else { return nil }
        return await list(in: directory, depth: 0)
    }

    /// The environment git runs in: `environment` without the variables that name a repository, as a hook's does,
    /// so `-C` alone says which one; without `GIT_DIFF_OPTS`, which would add context to `--since`'s `-U0` diffs; and
    /// without optional locks, so a listing never refreshes the user's index.
    static func environment(_ environment: [String: String]) -> [String: String] {
        var gitEnvironment = environment.filter { !repositoryVariables.contains($0.key) && $0.key != "GIT_DIFF_OPTS" }
        gitEnvironment["GIT_OPTIONAL_LOCKS"] = "0"
        return gitEnvironment
    }

    /// What `git rev-parse --local-env-vars` names.
    private static let repositoryVariables: Set = [
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
        "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
        "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX", "GIT_SHALLOW_FILE",
        "GIT_COMMON_DIR",
    ]

    /// Whether `directory` lies below its repository's top level, in a folder the repository ignores. git lists none of
    /// the untracked files there, and a listing of only the files forced in would leave out every test fixture.
    static func isIgnoredByItsRepository(_ directory: URL) async -> Bool {
        // At the top level `.` reads as ignored when the repository ignores everything, though git lists what it
        // tracks.
        guard let prefix = await run(["rev-parse", "--show-prefix"], in: directory), prefix.status == 0,
              !prefix.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        // Without --no-index, a folder that holds a file forced in doesn't read as ignored.
        return await run(["check-ignore", "-q", "--no-index", "."], in: directory)?.status == 0
    }

    private static func list(in directory: URL, depth: Int) async -> [String]? {
        guard let entries = await listing(in: directory) else { return nil }
        var files: [String] = []
        for entry in entries {
            let path = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            let folder = directory.appendingPathComponent(path)
            guard entry.hasSuffix("/") || isFolder(folder) else {
                files.append(entry)
                continue
            }
            let listing = depth < maximumDepth ? await list(in: folder, depth: depth + 1) : nil
            let inside = listing ?? ProjectTree.walk(folder, keeping: { _ in true }, skippingCheckouts: false)
            files += inside.map { path + "/" + $0 }
        }
        return files
    }

    private static func listing(in directory: URL) async -> [String]? {
        guard let git = await run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: directory),
              git.status == 0
        else { return nil }
        let entries = Set(git.output.split(separator: "\0").map(String.init))
        // The folder is a submodule that isn't checked out: its files aren't git's to list, so it is walked.
        guard !entries.contains("./"), !entries.contains(".") else { return nil }
        return entries.sorted()
    }

    /// git with `arguments`, in `directory`: its exit status and output, or nil if it didn't run or was killed.
    private static func run(_ arguments: [String], in directory: URL) async -> (status: Int32, output: String)? {
        await git(arguments, in: directory).map { ($0.status, $0.output) }
    }

    /// git with `arguments`, in `directory`, in `environment(_:)`: how it ended, or nil if it didn't run or was killed.
    static func git(_ arguments: [String], in directory: URL) async -> CommandResult? {
        let git = Foundation.Process()
        git.environment = environment(ProcessInfo.processInfo.environment)
        guard let result = await git.runCommand(url: "/usr/bin/git", arguments: ["-C", directory.path] + arguments),
              !result.endedBySignal
        else { return nil }
        return result
    }

    /// A folder, not a symbolic link to one: git lists a link as a file of its own.
    private static func isFolder(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }
}
