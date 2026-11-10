/// The command that continues a stopped run: SwiftMutator as it was started, resuming from the run's results file.
enum ResumeHint {
    /// `swift-mutator`, then `arguments` without an earlier `--resume` and its value, or `--force-resume`, then
    /// `--resume` and `resultsFile`, each quoted only where a shell would split it.
    ///
    /// A resumed session's results file is the one this run continues, or a log folder of one of its sessions, so
    /// `resultsFile` replaces it. The header of a session `--force-resume` let through records the build and toolchain
    /// it ran with, so the next session needs no force. `--resume-ignoring` stays: changed files a session's results
    /// don't depend on are as likely to change again before the next one. So does a test plan's path, which a resume of
    /// its run names again, and `--plan-ignoring`, which every session's check of the project needs.
    ///
    /// A run that reused an earlier run's results wrote `resultsFile` itself, so `--reuse` and its value go, and so
    /// does `--force-reuse`: its header records the build as it tested with it. Each `--reuse-ignoring` becomes a
    /// `--resume-ignoring` with the same glob, for the same reason `--resume-ignoring` stays.
    ///
    /// `--since`'s ref is replaced by `sinceMergeBase`, the commit the run compared the working tree with: a branch
    /// that moved since, as `origin/main` does after a fetch, would choose other files, and the resume be refused.
    ///
    /// `chosenSeed`, the seed SwiftMutator chose for a `--sample` given no `--seed`, is given as `--seed`: a resume
    /// would otherwise choose another, and take another sample.
    static func command(
        continuing arguments: [String],
        from resultsFile: String,
        since sinceMergeBase: String? = nil,
        chosenSeed: UInt64? = nil
    ) -> String {
        var rewriter = KeptArguments(sinceMergeBase: sinceMergeBase)
        for argument in arguments {
            rewriter.take(argument)
        }
        var kept = rewriter.kept
        if let chosenSeed {
            kept += ["--seed", String(chosenSeed)]
        }
        return (["swift-mutator"] + kept.map(Logger.shellWord) + ["--resume", Logger.shellQuoted(resultsFile)])
            .joined(separator: " ")
    }

    /// The arguments `command(continuing:from:since:chosenSeed:)` keeps, as it goes through them in order.
    private struct KeptArguments {
        let sinceMergeBase: String?
        var kept: [String] = []
        var skipsValue = false
        var waives = false
        var replacesRef = false

        /// Takes `argument`: drops it, replaces it, or keeps it.
        mutating func take(_ argument: String) {
            guard !takesValueOrSince(argument), !takesResumeOrReuse(argument) else { return }
            kept.append(argument)
        }

        /// Whether `argument` was taken as the value of the one before it, or as `--since`, whose ref is replaced.
        private mutating func takesValueOrSince(_ argument: String) -> Bool {
            if skipsValue {
                skipsValue = false
                return true
            }
            if replacesRef {
                replacesRef = false
                kept.append(sinceMergeBase ?? argument)
                return true
            }
            if argument == "--since" {
                replacesRef = true
                kept.append(argument)
                return true
            }
            if argument.hasPrefix("--since="), let sinceMergeBase {
                kept.append("--since=" + sinceMergeBase)
                return true
            }
            return false
        }

        /// Whether `argument` was taken as a resume's or a reuse's, which the next resume drops or rewrites.
        private mutating func takesResumeOrReuse(_ argument: String) -> Bool {
            if waives {
                waives = false
                kept += ["--resume-ignoring", argument]
                return true
            }
            if argument == "--resume" || argument == "--reuse" {
                skipsValue = true
                return true
            }
            if argument == "--reuse-ignoring" {
                waives = true
                return true
            }
            if argument.hasPrefix("--reuse-ignoring=") {
                kept.append("--resume-ignoring=" + argument.dropFirst("--reuse-ignoring=".count))
                return true
            }
            return ["--resume=", "--reuse="].contains(where: argument.hasPrefix)
                || ["--force-resume", "--force-reuse"].contains(argument)
        }
    }
}
