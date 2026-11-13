/// One reason a run can't be resumed, and what would let it be.
enum ResumeRefusal: Equatable, CustomStringConvertible {
    /// Another process holds the results file's lock: `holder`, if its record shows which. Without a record, the
    /// file's last session's process and host, if it has one, which may not be the holder.
    case inUse(holder: ResultsFileError.Holder?, lastProcess: Int32?, lastHost: String?)
    /// A configuration key that some outcome depends on.
    case configurationChanged(ResumeCheck.Difference)
    /// A new time limit, where the file doesn't record the limit each of its results was tested under, so none is
    /// known to be long enough: one that `--reuse` kept was tested under the earlier run's.
    case timeLimitUnknown(ResumeCheck.Difference)
    /// The run stopped before its first mutant, as the file's record says, so it has no result to resume or reuse.
    case stoppedBeforeFirstMutant(ResultsStopped)
    /// `operators`, `filesToMutate`, `skipCoverage` or what `--since` chose: which mutants are tested.
    case selectionChanged(ResumeCheck.Difference)
    /// What identifies the SwiftMutator build, the toolchain or the SDK, which `--force-resume` lets through.
    case needsForce(ResumeCheck.Difference)
    /// Project files that changed, and that no `--resume-ignoring` glob matches.
    case filesChanged([ProjectTree.FileChange])
    /// Files of the test plan's copy, at `copy`, that changed since the last session tested it, and that no
    /// `--resume-ignoring` glob matches.
    case copyChanged([ProjectTree.FileChange], copy: String)
    /// One of the two runs tested a test plan and the other didn't: the recorded one if `recordedUsedOne`.
    case testPlanRun(recordedUsedOne: Bool)
    /// The test plan's SHA-256, `testPlan.sha256`, differs from the one the last session tested.
    case testPlanChanged(ResumeCheck.Difference)
    /// The last session tested a test plan, and was written by a SwiftMutator that didn't record which.
    case testPlanNotRecorded
    /// The last session was written by a SwiftMutator from before `--resume`, which recorded no project files.
    case noProjectTree
    /// `-o` names the results file itself.
    case reportWouldReplaceTheResultsFile(String)
    /// One of the other reports names the results file itself: `--report`'s if `isTheFlags`, and else the
    /// configuration's `reports:`.
    case otherReportWouldReplaceTheResultsFile(ReportRequest, isTheFlags: Bool)
    /// `--write-baseline` names the results file itself, which saving the baseline file at the end would replace.
    case baselineFileWouldReplaceTheResultsFile(String)

    /// How many changed files are named, each with a `--resume-ignoring` flag; the rest are counted.
    static let changedFilesNamed = 10

    var description: String {
        describe(reusing: false)
    }

    /// The reason, naming `--reuse`'s flags if `reusing`, and `--resume`'s otherwise.
    func describe(reusing: Bool) -> String {
        switch self {
        case .stoppedBeforeFirstMutant, .inUse:
            runDescription(reusing: reusing)

        case .configurationChanged, .timeLimitUnknown, .selectionChanged, .needsForce:
            changeDescription(reusing: reusing)

        case .filesChanged, .copyChanged, .testPlanRun, .testPlanChanged, .testPlanNotRecorded, .noProjectTree:
            projectDescription(reusing: reusing)

        case .reportWouldReplaceTheResultsFile, .otherReportWouldReplaceTheResultsFile,
             .baselineFileWouldReplaceTheResultsFile:
            replacementDescription
        }
    }

    /// `describe(reusing:)` for a run that stopped before its first mutant, or whose file another run holds.
    private func runDescription(reusing: Bool) -> String {
        switch self {
        case let .stoppedBeforeFirstMutant(stopped):
            let next = stopped.resuming.map { "--resume \(Logger.shellQuoted($0)), the run it was resuming" }
                ?? (reusing ? "start a run without --reuse" : "start a new run, without --resume")
            return (["its run \(stopped.stoppedClause)."] + stopped.detailLines + ["Fix that, then \(next)."])
                .joined(separator: "\n")

        case let .inUse(.running(holder), _, _):
            return "another SwiftMutator run, \(holder), holds its lock. Wait for that run to end, or stop it, then "
                + "resume again."

        case let .inUse(.unchecked(holder), _, _):
            return "another SwiftMutator run holds its lock: by its record, \(holder), which this host can't check."

        case let .inUse(nil, process, host):
            var writer = process.map { " by process \($0)" } ?? ""
            if let host, !host.isEmpty {
                writer += " on \(host)"
            }
            guard !writer.isEmpty else { return "another SwiftMutator run holds its lock." }
            return "another SwiftMutator run holds its lock, and doesn't say which. The file's last session was "
                + "written\(writer), but that run may not be the one: a resume holds the lock before it writes a "
                + "session of its own."

        default:
            preconditionFailure("\(self) is neither a stopped run nor a file in use")
        }
    }

    /// `describe(reusing:)` for a change to the configuration, the selection, or the build and toolchain.
    private func changeDescription(reusing: Bool) -> String {
        switch self {
        case let .configurationChanged(difference) where difference.name == ResumeCheck.timeLimitKey:
            return "\(difference.name) \(difference.change(absent: "not set")). A time limit shorter than a "
                + "session's, or none, needs a new run: one at least as long as every session's only tests timeouts "
                + "again."

        case let .configurationChanged(difference):
            return "\(difference.name) \(difference.change(absent: "not set")). "
                + "A configuration change needs a new run."

        case let .timeLimitUnknown(difference):
            return "\(difference.name) \(difference.change(absent: "not set")). The file doesn't record the time "
                + "limit every result was tested under, as for one --reuse kept, so a new limit needs a new run."

        case let .selectionChanged(difference):
            return "\(difference.name) \(difference.change(absent: "not set")). "
                + "A change to which mutants are tested needs a new run."

        case let .needsForce(difference):
            let subject = "\(ResumeCheck.subject(of: difference.name)) (\(difference.name))"
            let change = difference.was == nil && difference.isNow == nil
                ? "is unknown, so it may have changed"
                : difference.change(absent: "unknown")
            return "\(subject) \(change). \(reusing ? "--force-reuse" : "--force-resume") reuses the results anyway."

        default:
            preconditionFailure("\(self) is no change to the configuration, the selection or the build")
        }
    }

    /// `describe(reusing:)` for changed files, or a test plan that doesn't match, or a session without a project tree.
    private func projectDescription(reusing: Bool) -> String {
        switch self {
        case let .filesChanged(changes):
            return Self.describe(changes, of: ("project file", "project files"), changedSince: "the run stopped")

        case let .copyChanged(changes, copy):
            return Self.describe(
                changes,
                of: ("file of the test plan's copy, \(copy),", "files of the test plan's copy, \(copy),"),
                changedSince: "the run's last session, as a fix by hand would"
            )

        case .testPlanRun(recordedUsedOne: true):
            return "The file's run tested a test plan, so "
                + (reusing ? "its results can't be reused: " : "")
                + "only `swift-mutator run-without-mutating` with that plan and --resume can continue it."

        case .testPlanRun(recordedUsedOne: false):
            return "The file's run didn't test a test plan, so `swift-mutator run-without-mutating` can't continue "
                + "it: `swift-mutator run` with --resume can."

        case let .testPlanChanged(difference):
            return "\(difference.name) \(difference.change(absent: "unknown")): the test plan was made again or "
                + "edited, so its mutants may not be the ones the results are for. A new run is needed: "
                + "`swift-mutator run-without-mutating` without --resume."

        case .testPlanNotRecorded:
            return "The file's last session tested a test plan with a SwiftMutator that recorded nothing to check it "
                + "by. A new run is needed: `swift-mutator run-without-mutating` without --resume."

        case .noProjectTree:
            return "The file's last session recorded no project files, as SwiftMutator didn't before --resume, "
                + "so nothing shows that they haven't changed. A new run is needed."

        default:
            preconditionFailure("\(self) is no change to the project or its test plan")
        }
    }

    /// `describe(reusing:)` for a report or a baseline file that would replace the results file.
    private var replacementDescription: String {
        switch self {
        case let .reportWouldReplaceTheResultsFile(path):
            return "-o \(Logger.shellQuoted(path)) is the results file itself, which the report would replace. "
                + "Write the report to another file."

        case let .otherReportWouldReplaceTheResultsFile(request, isTheFlags):
            let named = isTheFlags
                ? "--report \(Logger.shellQuoted(request.description)) is"
                : "reports: names \(Logger.shellQuoted(request.description)),"
            return "\(named) the results file itself, which the report would replace. Save that report to another file."

        case let .baselineFileWouldReplaceTheResultsFile(path):
            return "--write-baseline \(Logger.shellQuoted(path)) is the results file itself, which the baseline file "
                + "would replace. Save the baseline file to another file."

        default:
            preconditionFailure("\(self) would replace no results file")
        }
    }

    /// A `--resume-ignoring` glob that matches `path` alone, as `partition(by:)` reads globs: `*`, `?`, `[` and `\`
    /// escaped with a backslash.
    static func glob(matching path: String) -> String {
        var glob = ""
        for character in path {
            if "*?[\\".contains(character) {
                glob.append("\\")
            }
            glob.append(character)
        }
        return glob
    }

    /// The changed files, up to `changedFilesNamed` of them by name, and the flags that would let those through,
    /// ready to paste. `noun` names one of them, and several, such as "project file" and "project files", and `since`
    /// says when they changed.
    private static func describe(
        _ changes: [ProjectTree.FileChange],
        of noun: (one: String, many: String),
        changedSince since: String
    ) -> String {
        let named = changes.prefix(changedFilesNamed)
        let others = changes.count - named.count
        let one = changes.count == 1
        let files = named.map { "\($0.path) (\($0.kind.rawValue))" }.joined(separator: ", ")
            + (others > 0 ? ", and \(others) more" : "")
        let flags = named.map { "--resume-ignoring " + Logger.shellQuoted(glob(matching: $0.path)) }
            .joined(separator: " ")
            + (others > 0 ? ", plus globs for the other \(others)" : "")
        return [
            "\(changes.count) \(one ? noun.one : noun.many) changed since \(since): \(files).",
            "If \(one ? "it" : "they") can't change any test's result: \(flags)",
            "Mutants in a changed source file are tested again either way.",
        ].joined(separator: "\n")
    }
}
