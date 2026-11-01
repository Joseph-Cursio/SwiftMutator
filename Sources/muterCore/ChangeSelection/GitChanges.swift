import Foundation

/// Why `--since` couldn't choose the files to mutate. Printed as it is, as each says what to do.
enum ChangeSelectionError: Error, Equatable, CustomStringConvertible {
    /// The project isn't in a git repository, or is in a folder its repository ignores.
    case notARepository(project: String)
    case unknownRef(String)
    /// HEAD names no commit yet.
    case noCommits
    /// The ref and HEAD share no history git has, as in a shallow clone.
    case noMergeBase(ref: String)
    /// Swift files with unresolved merge conflicts.
    case unmerged(paths: [String])
    /// git failed, or couldn't be run.
    case gitFailed(arguments: [String], errors: String)
    /// A chosen file changed between being compared with the merge base and being copied.
    case changedDuringTheRun(path: String)

    var description: String {
        switch self {
        case let .notARepository(project):
            return """
            --since needs the project in a git repository that doesn't ignore it, and \(project) isn't.
            """
        case let .unknownRef(ref):
            return """
            --since: git doesn't know \(ref) here. In a shallow clone, as CI checks out by default, fetch it first, \
            or fetch the whole history (actions/checkout's fetch-depth: 0).
            """
        case .noCommits:
            return "--since: HEAD names no commit yet, so there is nothing to compare the working tree with."
        case let .noMergeBase(ref):
            return """
            --since: \(ref) and HEAD have no common commit git knows. In a shallow clone, fetch more history \
            (actions/checkout's fetch-depth: 0).
            """
        case let .unmerged(paths):
            return "--since: resolve the merge conflicts in \(paths.joined(separator: ", ")) first."
        case let .gitFailed(arguments, errors):
            let trimmed = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            return "--since: git \(arguments.joined(separator: " ")) failed" + (trimmed.isEmpty ? "." : ": \(trimmed)")
        case let .changedDuringTheRun(path):
            return """
            --since: \(path) changed after SwiftMutator compared it with the merge base, so its mutants' lines \
            couldn't be trusted. Run again.
            """
        }
    }
}

/// What changed in a project since a ref, as git sees it: always in the project itself, never its copy, whose files
/// SwiftMutator rewrites.
enum GitChanges {
    typealias Git = @Sendable (_ arguments: [String], _ directory: URL) async -> CommandResult?

    /// The Swift files of the project at `project` that changed since the merge base of `ref` and HEAD: in the working
    /// tree, so uncommitted changes count, and new files git doesn't ignore too; with `changedLines`, the lines too.
    /// Settings that change what `git diff` prints, such as `diff.external` or `diff.relative`, are overridden. A
    /// symbolic link isn't chosen: git compares the path it holds, not the code it leads to.
    static func select(
        since ref: String,
        changedLines: Bool,
        in project: URL,
        git: @escaping Git = { await GitFileListing.git($0, in: $1) }
    ) async -> Result<ChangeSelection, ChangeSelectionError> {
        let repository = Repository(project: project, git: git)
        do {
            let (commit, mergeBase) = try await repository.mergeBase(of: ref)
            var files: [ChangedFile] = []
            for entry in try await repository.changedSwiftFiles(since: mergeBase) {
                let url = project.appendingPathComponent(entry.path)
                // Before the diff: a save after this makes the copy differ from it, which discovery refuses, so the
                // lines can't be of other text than the copy's. A link, or a file removed but not with git, has none.
                guard let sha256 = digest(of: url) else { continue }
                var lines: [LineRange]?
                var deletionsAfter: [Int]?
                if changedLines, let paths = entry.comparedPaths {
                    (lines, deletionsAfter) = try await repository.hunks(of: paths, since: mergeBase)
                }
                files.append(ChangedFile(
                    path: spelledAsOnDisk(entry.path, in: project).precomposedStringWithCanonicalMapping,
                    lines: lines,
                    deletionsAfter: deletionsAfter,
                    sha256: sha256
                ))
            }
            return .success(ChangeSelection(
                ref: ref,
                commit: commit,
                mergeBase: mergeBase,
                changedLines: changedLines,
                files: files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) },
                foldersNotCompared: try await repository.foldersOfTheirOwn()
            ))
        } catch let error as ChangeSelectionError {
            return .failure(error)
        } catch {
            return .failure(.gitFailed(arguments: [], errors: "\(error)"))
        }
    }

    /// What every `git diff` here is given, whatever the repository's or the user's settings: paths relative to the
    /// project, renames found, submodules left out, and no external diff, text conversion or color.
    fileprivate static let diffOptions = [
        "--relative", "--find-renames", "--ignore-submodules=all", "--no-ext-diff", "--no-textconv", "--no-color",
    ]

    /// The file's SHA-256, or nil if it isn't a file.
    private static func digest(of url: URL) -> String? {
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        guard type == .typeRegular else { return nil }
        return FileDigest.sha256(of: url)
    }

    /// `path` in `project` as the disk spells it, which discovery lists. git gives a file renamed only in case, without
    /// `git mv`, its old name, and a disk that ignores case finds it by either. Each part of the path that the disk has
    /// in another case, and in only one, takes the disk's; any other stays as git gave it.
    static func spelledAsOnDisk(_ path: String, in project: URL) -> String {
        var folder = project
        var parts: [String] = []
        for part in path.split(separator: "/").map(String.init) {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let spelled: String
            if entries.contains(part) {
                spelled = part
            } else {
                let matches = entries.filter { $0.lowercased() == part.lowercased() }
                spelled = matches.count == 1 ? matches[0] : part
            }
            parts.append(spelled)
            folder.appendPathComponent(spelled)
        }
        return parts.joined(separator: "/")
    }
}

/// git in one project, its failures turned into `ChangeSelectionError`s.
private struct Repository {
    let project: URL
    let git: GitChanges.Git

    /// The commit `ref` names and its merge base with HEAD.
    func mergeBase(of ref: String) async throws -> (commit: String, mergeBase: String) {
        // Outside a repository git exits 128 and says so; in a repository's own folder, or a bare one, it says false.
        // Any other failure, such as a repository another user owns, is git's to explain.
        let arguments = ["rev-parse", "--is-inside-work-tree"]
        let inside = try await run(arguments)
        let outside = inside.status == 128 && inside.errors.contains("not a git repository")
        guard inside.status == 0 || outside else { throw failure(inside, arguments) }
        guard inside.status == 0, inside.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true",
              await !GitFileListing.isIgnoredByItsRepository(project)
        else { throw ChangeSelectionError.notARepository(project: project.path) }

        // Before the ref, which wouldn't resolve either.
        guard try await run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]).status == 0 else {
            throw ChangeSelectionError.noCommits
        }
        // `--since` never starts with a dash (`Run.validate`), so it can't be read as an option, and no
        // `--end-of-options` is needed, which rev-parse only takes from git 2.30.
        let resolved = try await run(["rev-parse", "--verify", "--quiet", ref + "^{commit}"])
        guard resolved.status == 0 else { throw ChangeSelectionError.unknownRef(ref) }
        let commit = resolved.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let mergeBase = ["merge-base", commit, "HEAD"]
        let base = try await run(mergeBase)
        guard base.status == 0 else {
            throw base.status == 1 ? ChangeSelectionError.noMergeBase(ref: ref) : failure(base, mergeBase)
        }
        return (commit, base.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The Swift files that differ from `mergeBase` in the working tree, removed ones aside, and the new ones git
    /// doesn't ignore, by git's paths in the project. A file with unresolved conflicts ends the selection: its markers
    /// wouldn't build, and git compares it as an ordinary change.
    func changedSwiftFiles(since mergeBase: String) async throws -> [GitDiffParsing.Entry] {
        let unmerged = try await output(
            ["-c", "core.quotePath=false", "diff", "--name-only", "-z", "--relative", "--diff-filter=U"]
        )
            .split(separator: "\0").map(String.init).filter(\.isSwift)
        guard unmerged.isEmpty else { throw ChangeSelectionError.unmerged(paths: unmerged.sorted()) }

        let changed = try await output(
            ["-c", "core.quotePath=false", "diff", "--name-status", "-z"] + GitChanges.diffOptions
                + [mergeBase, "--"]
        )
        let untracked = try await output(["ls-files", "-z", "--others", "--exclude-standard"])
            .split(separator: "\0").map(String.init)
            // A folder is an untracked repository of its own (`foldersOfTheirOwn`).
            .filter { !$0.hasSuffix("/") }
        return (GitDiffParsing.entries(ofNameStatus: changed).filter { $0.status != .deleted }
            + untracked.map { GitDiffParsing.Entry(status: .added, path: $0) })
            .filter(\.path.isSwift)
    }

    /// The lines of `paths`, one file's, or a renamed one's two, that differ from `mergeBase`.
    func hunks(of paths: [String], since mergeBase: String) async throws -> (lines: [LineRange], deletionsAfter: [Int]) {
        let diff = try await output(
            ["--literal-pathspecs", "diff", "-U0", "-a", "--inter-hunk-context=0", "--diff-algorithm=myers"]
                + GitChanges.diffOptions + [mergeBase, "--"] + paths
        )
        return GitDiffParsing.hunks(ofUnifiedDiff: diff)
    }

    /// The folders in the project that are repositories of their own, whose changes git doesn't compare here:
    /// submodules, and untracked repositories, as a local package checked out in the project can be.
    func foldersOfTheirOwn() async throws -> [String] {
        let untracked = try await output(["ls-files", "-z", "--others", "--exclude-standard"])
            .split(separator: "\0").map(String.init)
            .filter { $0.hasSuffix("/") }
            .map { String($0.dropLast()) }
        // `<mode> <object> <stage>\t<path>`, a submodule's mode being 160000.
        let submodules = try await output(["ls-files", "-z", "--stage"])
            .split(separator: "\0")
            .filter { $0.hasPrefix("160000 ") }
            .compactMap { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) }
        return (untracked + submodules).map(\.precomposedStringWithCanonicalMapping).sorted()
    }

    private func run(_ arguments: [String]) async throws -> CommandResult {
        guard let result = await git(arguments, project) else {
            throw ChangeSelectionError.gitFailed(arguments: arguments, errors: "it couldn't be run")
        }
        return result
    }

    private func output(_ arguments: [String]) async throws -> String {
        let result = try await run(arguments)
        guard result.status == 0 else { throw failure(result, arguments) }
        return result.output
    }

    private func failure(_ result: CommandResult, _ arguments: [String]) -> ChangeSelectionError {
        .gitFailed(arguments: arguments, errors: result.errors)
    }
}

private extension String {
    var isSwift: Bool { hasSuffix(".swift") }
}

private extension GitDiffParsing.Entry {
    /// The paths whose diff gives the entry's changed lines, or nil when every line of it is changed.
    var comparedPaths: [String]? {
        switch status {
        case .modified:
            return [path]
        case let .renamed(from):
            return [from, path]
        case .added, .deleted, .replaced:
            return nil
        }
    }
}
