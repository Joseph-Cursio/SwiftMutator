/// What the Logger says about the project's copy: that it is being made and where it went, the files that vanished
/// meanwhile, what its build uses from outside it, what an absolute path makes it build from the project, and the
/// SwiftLint it turned off.
extension Logger {
    /// "ℹ️ Your project's build uses code outside its folder…", then up to 5 of `paths`, then how to mutate that code
    /// too. A notice, not a warning: the project builds and tests as it would anyway.
    func codeOutsideTheProjectBuilt(_ paths: [String]) {
        let shown = paths.prefix(5).map { "  \($0)" }
        let more = paths.count > shown.count ? ["  … and \(paths.count - shown.count) more"] : []
        let lines = [
            "ℹ️ Your project's build uses code outside its folder, which SwiftMutator doesn't copy, so it is built "
                + "from where it is and gets no mutants:",
        ]
            + shown + more
            + [
                "Mutants are made only in the folder SwiftMutator runs in. To mutate that code too, run SwiftMutator "
                    + "from a folder that holds both, such as your repository's root, with \("arguments".bold) naming "
                    + "the project there, or move the code into the project.",
            ]
        print(lines.joined(separator: "\n"))
    }

    /// "⚠️ Your project names code in its own folder by an absolute path…", then up to 5 of `paths`, then how to make
    /// the copy build its own. A warning: the run goes ahead, but every mutant in that code survives.
    func projectCodeNamedByAbsolutePath(_ paths: [String]) {
        let shown = paths.prefix(5).map { "  \($0)" }
        let more = paths.count > shown.count ? ["  … and \(paths.count - shown.count) more"] : []
        let lines = [
            "⚠️ Your project names code in its own folder by an absolute path, which SwiftMutator's copy names too, so "
                + "the copy builds that code from your project, unmutated, and every mutant in it survives:",
        ]
            + shown + more
            + [
                "Name it by a relative path in your workspace or manifest instead, so that the copy builds its own.",
            ]
        print(lines.joined(separator: "\n"))
    }

    /// The build phases of the copy whose SwiftLint was turned off, each by its project, name and targets, and the key
    /// that keeps it on; then those that name SwiftLint in a way that wasn't turned off, and the project files that
    /// couldn't be read. `:` still opens a turned-off command's redirections, and a `tee` after it still runs, so a
    /// report SwiftLint wrote, which a later command may read, is an empty file.
    func swiftLintPhasesTurnedOff(_ phases: SwiftLintPhases) {
        var lines: [String] = []
        if !phases.turnedOff.isEmpty {
            let count = phases.turnedOff.count == 1 ? "1 build phase" : "\(phases.turnedOff.count) build phases"
            lines.append(
                "🔇 Turned SwiftLint off in \(count) of the copy, as each mutated file turns its rules off anyway. "
                    + "Only the command that runs it is skipped, so the rest of the script still runs, and a report it "
                    + "writes is left empty:"
            )
            lines += phases.turnedOff.map { "  \($0.shown)" }
            lines.append("\("keepSwiftLintPhases: true".bold) keeps it running there.")
        }
        if !phases.leftRunning.isEmpty {
            let count = phases.leftRunning.count == 1
                ? "1 build phase of the copy names" : "\(phases.leftRunning.count) build phases of the copy name"
            lines.append("⚠️ \(count) SwiftLint in no command SwiftMutator could turn off, so it may still run there:")
            lines += phases.leftRunning.map { "  \($0.shown)" }
        }
        lines += phases.unreadProjects.map { project in
            "⚠️ Couldn't read or write \(project) in the copy, which names SwiftLint, so its build phases may still "
                + "run it."
        }
        print(lines.joined(separator: "\n"))
    }

    func projectCopyStarted() {
        print("✂️ Copying your project to a temporary directory for testing...")
    }

    func projectCopySkippedVanishedFiles(_ paths: [String]) {
        let shown = paths.prefix(5).map { "  \($0)" }
        let more = paths.count > shown.count ? ["  … and \(paths.count - shown.count) more"] : []
        print(
            (["⚠️ Skipped \(paths.count) file(s) that disappeared while your project was being copied:"] + shown + more)
                .joined(separator: "\n")
        )
    }

    func projectCopyFinished(destinationPath: String) {
        print(
            """
            ✅ Finished copying your project to a temporary directory for mutation testing.
            You can find your copied project here:

            \(destinationPath.bold)
            """
        )
    }
}
