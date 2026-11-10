import Foundation

/// Why SwiftMutator won't test a test plan: it might not describe the project, or can't be tested as it is. Nothing was
/// tested.
struct TestPlanRefused: Error, Equatable, CustomStringConvertible {
    /// The plan's path.
    let path: String
    let reason: TestPlanRefusal

    var description: String {
        let reasonText = "\(reason)"
        // A reason of several lines ends in a list or a command, which this sentence doesn't belong to.
        let separator = reasonText.contains("\n") ? "\n" : " "
        return "SwiftMutator won't test the plan \(Logger.shellQuoted(path)): \(reasonText)\(separator)Nothing was tested."
    }
}

/// One reason a test plan isn't tested, and what would let it be.
enum TestPlanRefusal: Equatable, CustomStringConvertible {
    /// The plan is in a format newer than `TestPlanCoding.newestFormatVersion`.
    case newerFormat(found: Int)
    /// None of the `files` files the plan mutates is in `folder`, the folder the run is in, nor any other file the plan
    /// recorded in the folders at the top of the project that hold them, so it isn't the project the plan was made
    /// from. `mutatedProject` is the copy as the plan names it, relative to that project.
    case notThisProject(folder: String, files: Int, mutatedProject: String)
    /// Files the plan mutates that changed in the project since the plan was made, and that no `--plan-ignoring` glob
    /// matches.
    case sourcesChanged([ProjectTree.FileChange])
    /// The plan's copy of the project, at this absolute path, isn't there: it was removed, or moved, or the project
    /// was moved without it.
    case copyMissing(path: String)

    var description: String {
        switch self {
        case let .newerFormat(found):
            return "it is in test plan format \(found), which only a newer SwiftMutator can read. Test it with the "
                + "SwiftMutator that made it, or make it again with `swift-mutator mutate-without-running`."

        case let .notThisProject(folder, files, mutatedProject):
            let none = files == 1
                ? "the file it mutates isn't in \(folder)."
                : "none of the \(files) files it mutates is in \(folder)."
            return none + " Run `swift-mutator run-without-mutating` in the folder of the project the plan was made "
                + "from: the plan finds its copy, \(mutatedProject), from there."

        case let .sourcesChanged(changes):
            return Self.describe(changes)

        case let .copyMissing(path):
            return "its copy of the project isn't at \(path). If the copy was moved, or the project without it, move "
                + "the copy there. A later `swift-mutator run` or `swift-mutator mutate-without-running` of the "
                + "project removes the copy: then make the plan again with `swift-mutator mutate-without-running`."
        }
    }

    /// The changed files, up to `ResumeRefusal.changedFilesNamed` of them by name, and the flags that would let those
    /// through, ready to paste.
    private static func describe(_ changes: [ProjectTree.FileChange]) -> String {
        let named = changes.prefix(ResumeRefusal.changedFilesNamed)
        let others = changes.count - named.count
        let one = changes.count == 1
        let flags = named.map { "--plan-ignoring " + Logger.shellQuoted(ResumeRefusal.glob(matching: $0.path)) }
            .joined(separator: " ")
            + (others > 0 ? ", plus globs for the other \(others)" : "")
        let heading = "\(changes.count) file\(one ? "" : "s") it mutates changed since "
            + "`swift-mutator mutate-without-running` made it:"
        let files = named.map { "  - \($0.path) \(happened(to: $0))" }
            + (others > 0 ? ["  - and \(others) more"] : [])
        let why = "The plan's copy holds \(one ? "it" : "them") as \(one ? "it was" : "they were"), so its mutants' "
            + "places, and the report's lines in \(one ? "this file" : "these files"), would describe code you no "
            + "longer have. Make the plan again, or test the copy as it is with:"
        return ([heading] + files + [why, "  " + flags]).joined(separator: "\n")
    }

    /// "changed", "was added" or "was removed".
    private static func happened(to change: ProjectTree.FileChange) -> String {
        switch change.kind {
        case .changed:
            return "changed"

        case .added:
            return "was added"

        case .removed:
            return "was removed"
        }
    }
}
