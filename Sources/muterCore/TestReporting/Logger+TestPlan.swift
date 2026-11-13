/// What the Logger says about a mutation test plan: creating it, loading it, and how its sources compare with the
/// project's.
extension Logger {
    /// What the plan holds, that its copy can be fixed by hand, how to test it, and that a later run removes the copy.
    func testPlanFileCreated(_ created: TestPlanCreated) {
        let mutants = created.mutants == 1 ? "1 mutant" : "\(created.mutants) mutants"
        let files = created.files == 1 ? "1 file" : "\(created.files) files"
        let operators = created.operators.map {
            ($0.count == 1 ? "operator " : "operators ") + Self.listed($0)
        } ?? "every operator"
        print("💾 Mutation test plan created: \(created.path) (\(mutants) in \(files), \(operators))")
        print("✏️ You can fix its copy, \(created.mutatedProject), by hand before testing it.")
        print("▶️ Test it: swift-mutator run-without-mutating \(Self.shellWord(created.path))")
        print(
            "⚠️ A later `swift-mutator run` or `mutate-without-running` of this project removes that copy, and any fix "
                + "in it."
        )
    }

    func configurationFileCreated(atPath path: String?) {
        if let path {
            print("💾 Configuration file created at: \(path)")
        }
    }

    /// Says which scheme the configuration `init` wrote tests, when that is a guess: `xcodebuild -list` named none, or
    /// several and none after the workspace or project.
    func schemeGuessed(_ scheme: SchemeChoice?) {
        guard let scheme, scheme.isAGuess else {
            return
        }

        let file = MuterConfiguration.fileNameWithExtension
        if scheme.listed.isEmpty {
            print(
                "⚠️ xcodebuild -list named no scheme, so the arguments take `-scheme \(scheme.chosen)`, the "
                    + "workspace's or project's name. Check it in \(file)."
            )
        } else {
            print(
                "⚠️ No scheme is named after \(scheme.containerName), so the arguments take `-scheme "
                    + "\(scheme.chosen)`, the first of \(scheme.listed.joined(separator: ", ")). Change it in \(file) "
                    + "if another one runs your tests."
            )
        }
    }

    /// Says which of Xcode's trust checks the configuration `init` wrote skips, as each lets a plugin or macro run that
    /// no one approved, so that someone who doesn't trust that code takes the argument out.
    func trustChecksSkipped(_ checks: [XcodebuildTrustCheck]) {
        guard !checks.isEmpty else {
            return
        }

        let subjects = checks.map(\.subject).joined(separator: " and ")
        let arguments = checks.map { "`\($0.skippingArgument)`" }.joined(separator: " and ")
        let argumentsNamed = checks.count == 1 ? "the argument" : "the arguments"
        print(
            "⚠️ The project seems to use \(subjects), so the arguments include \(arguments): xcodebuild then runs "
                + "them without asking anyone to trust them first, which a run with no one at the Mac, as on CI, "
                + "needs. Take \(argumentsNamed) out of \(MuterConfiguration.fileNameWithExtension) if you don't "
                + "trust that code."
        )
    }

    func muterMutationTestPlanLoaded() {
        print("⬆️ SwiftMutator mutation test plan loaded")
    }

    func testPlanSourcesUnchecked() {
        print(
            "⚠️ The test plan was made by a SwiftMutator from before plans recorded the project's files, so it isn't "
                + "checked against them. Make it again with `swift-mutator mutate-without-running` to have it checked."
        )
    }

    /// "2 project files the plan doesn't mutate changed since …: Package.resolved (changed), …", up to
    /// `ResumeRefusal.changedFilesNamed` of them by name.
    func testPlanSourcesDiffer(_ changes: [ProjectTree.FileChange]) {
        let one = changes.count == 1
        let them = one ? "it" : "them"
        let was = one ? "it was" : "they were"
        print(
            "⚠️ \(changes.count) project file\(one ? "" : "s") the plan doesn't mutate changed since "
                + "`swift-mutator mutate-without-running` made it: \(Self.named(changes)). The plan's copy holds "
                + "\(them) as \(was), so its mutants are tested with \(them) as \(was). Make the plan again to test "
                + "with \(them) as \(one ? "it is" : "they are") now."
        )
    }

    /// "1 file with the plan's other mutants, which this run doesn't test, changed since …: Sources/Max.swift
    /// (changed). …", up to `ResumeRefusal.changedFilesNamed` of them by name.
    func testPlanUntestedFilesChanged(_ changes: [ProjectTree.FileChange]) {
        let one = changes.count == 1
        print(
            "⚠️ \(changes.count) file\(one ? "" : "s") with the plan's other mutants, which this run doesn't test, "
                + "changed since `swift-mutator mutate-without-running` made it: \(Self.named(changes)). A run that "
                + "tests those mutants refuses the plan, unless --plan-ignoring lets the "
                + "change\(one ? "" : "s") through."
        )
    }

    /// Each change's path and kind, up to `ResumeRefusal.changedFilesNamed` of them, and how many more there are.
    static func named(_ changes: [ProjectTree.FileChange]) -> String {
        let named = changes.prefix(ResumeRefusal.changedFilesNamed)
        let others = changes.count - named.count
        return named.map { "\($0.path) (\($0.kind.rawValue))" }.joined(separator: ", ")
            + (others > 0 ? ", and \(others) more" : "")
    }

    /// "The plan is tested although 1 file it mutates changed since it was made (--plan-ignoring): …", up to
    /// `ResumeRefusal.changedFilesNamed` of them by name.
    func testPlanChangesWaived(_ paths: [String]) {
        let named = paths.prefix(ResumeRefusal.changedFilesNamed)
        let others = paths.count - named.count
        let files = paths.count == 1 ? "1 file it mutates" : "\(paths.count) files it mutates"
        print(
            "ℹ️ The plan is tested although \(files) changed since it was made (--plan-ignoring): "
                + named.joined(separator: ", ") + (others > 0 ? ", and \(others) more" : "")
                + ". \(paths.count == 1 ? "Its" : "Their") mutants are tested in the copy as it is."
        )
    }

    /// "1 file of the plan's copy differs from what … wrote, and is tested as it is now: …", up to
    /// `ResumeRefusal.changedFilesNamed` of them by name.
    func testPlanCopyEdited(_ paths: [String]) {
        let named = paths.prefix(ResumeRefusal.changedFilesNamed)
        let others = paths.count - named.count
        let one = paths.count == 1
        print(
            "✏️ \(paths.count) file\(one ? "" : "s") of the plan's copy "
                + "\(one ? "differs" : "differ") from what `swift-mutator mutate-without-running` wrote, and "
                + "\(one ? "is" : "are") tested as \(one ? "it is" : "they are") now: "
                + named.joined(separator: ", ") + (others > 0 ? ", and \(others) more" : "")
        )
    }

    /// "1 dependency resolution file of the plan's copy changed since the run's last session: Package.resolved
    /// (added). …", up to `ResumeRefusal.changedFilesNamed` of them by name.
    func testPlanCopyResolutionChanged(_ changes: [ProjectTree.FileChange]) {
        let one = changes.count == 1
        print(
            "⚠️ \(changes.count) dependency resolution file\(one ? "" : "s") of the plan's copy changed since the "
                + "run's last session: \(Self.named(changes)). The project the plan was made from had "
                + "\(one ? "no such file" : "none of them"), so the copy's own build wrote \(one ? "it" : "them"), "
                + "and the results are reused. To test every mutant with the dependencies as they are resolved now, "
                + "start the run again without --resume."
        )
    }
}
