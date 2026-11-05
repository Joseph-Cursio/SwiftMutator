import ArgumentParser
import Foundation

struct Run: RunCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Performs mutation testing for the Swift project contained within the current directory."
    )

    // First, so the help lists --files-to-mutate and --operators before the rest.
    @OptionGroup var selection: MutantSelectionArguments

    @Option(
        name: .customLong("since"),
        help: ArgumentHelp(
            "Only mutate the Swift files changed since the merge base of this git ref and HEAD: committed, "
                + "uncommitted, and new files git doesn't ignore. The excludes and the coverage filter still apply.",
            valueName: "ref"
        )
    )
    var since: String?

    @Flag(
        name: .customLong("changed-lines"),
        help: "With --since, only mutate code on the lines the change added or changed."
    )
    var changedLines = false

    @Option(
        name: .customLong("shard"),
        help: ArgumentHelp(
            "Only test shard k of n, such as 1/2: n runs, on as many machines, test each mutant once between them. "
                + "A mutant's shard follows from where it is. swift-mutator report merges their results files.",
            valueName: "k/n"
        ),
        transform: { text in
            guard let shard = Shard(text) else {
                throw ValidationError(
                    "give two whole numbers k/n with 1 ≤ k ≤ n ≤ \(Shard.largestCount), such as 1/2."
                )
            }
            return shard
        }
    )
    var shard: Shard?

    @Option(
        name: .customLong("sample"),
        help: ArgumentHelp(
            "Only test a sample of about N of the mutants discovered, as for a trend between whole runs. "
                + "The reports give how far the score may be from a whole run's.",
            valueName: "N"
        ),
        transform: { text in
            guard text.allSatisfy({ ("0"..."9").contains($0) }), let size = Int(text), size >= 1 else {
                throw ValidationError("give a whole number of mutants, 1 or more, such as 500.")
            }
            return size
        }
    )
    var sample: Int?

    @Option(
        name: .customLong("seed"),
        help: ArgumentHelp(
            "With --sample, the seed that chooses the sample: the same seed chooses the same mutants anywhere. "
                + "Without it, SwiftMutator chooses one and says which.",
            valueName: "S"
        ),
        transform: { text in
            guard text.allSatisfy({ ("0"..."9").contains($0) }), let seed = UInt64(text) else {
                throw ValidationError("give a whole number, 0 or more, such as 1234.")
            }
            return seed
        }
    )
    var seed: UInt64?

    // After the options that choose mutants, of which it is the narrowest.
    @OptionGroup var lone: MutantArguments

    @OptionGroup var options: RunArguments
    @OptionGroup var testing: TestingArguments
    @OptionGroup var reportOptions: ReportArguments

    // After the option groups, so these and the ones below come last in the help. Not in `RunArguments`, which
    // `mutate-without-running` shares.
    @OptionGroup var resuming: ResumeArguments

    @Option(
        name: .customLong("reuse"),
        help: ArgumentHelp(
            "Start a new run from an earlier run's results file, or the log folder of any of its sessions, "
                + "finished or not. Only mutants without a result that still holds are tested, and the new run "
                + "writes a results file of its own.",
            valueName: "results"
        )
    )
    var reuse: URL?

    @Option(
        name: .customLong("reuse-ignoring"),
        help: ArgumentHelp(
            "With --reuse, reuse results although project files matching this glob changed; * also matches /. "
                + "Test files are never waived. Repeatable.",
            valueName: "glob"
        )
    )
    var reuseIgnoring: [String] = []

    @Flag(
        name: .customLong("force-reuse"),
        help: "With --reuse, reuse results although SwiftMutator, the toolchain or the SDK changed."
    )
    var forceReuse = false

    init() {}

    /// The options the command line gives the run. Without `--seed`, a `--sample` gets a seed chosen afresh each time,
    /// so `run()` asks once. `--mutant` skips coverage, which only leaves files and code out of discovery. It leaves
    /// the files and the operators alone, the configuration's too: its path may be the end of one, and a wrong operator
    /// is refused with the mutants near its place, whatever their operators, so every file is discovered with every
    /// operator, and `SelectMutant` picks the mutant.
    var runOptions: Run.Options {
        Run.Options(
            filesToMutate: selection.filesToMutate,
            since: since,
            changedLinesOnly: changedLines,
            // 1/1 is the whole run.
            shard: shard?.count == 1 ? nil : shard,
            sample: sample.map { Sample(size: $0, seed: seed ?? Sample.chooseSeed(), seedIsChosen: seed == nil) },
            reportFormat: reportOptions.reportFormat,
            reportURL: reportOptions.reportURL,
            mutationOperatorsList: selection.mutationOperatorsList,
            operatorsAreNamed: selection.operatorsAreNamed,
            skipOperators: selection.skippedOperators,
            skipCoverage: options.skipCoverage || lone.mutant != nil,
            skipUpdateCheck: options.skipUpdateCheck,
            verbose: options.verbose,
            configurationURL: options.configurationURL,
            workers: testing.workers,
            timeout: testing.timeout,
            failUnder: reportOptions.failUnder,
            propertyTests: reportOptions.propertyTestGlobs,
            resumeURL: resuming.resume,
            reuseURL: reuse,
            // Only one of each pair can be given: `validate()` ties each to its own option.
            resumeIgnoring: resuming.resume == nil ? reuseIgnoring : resuming.resumeIgnoring,
            forceResume: resuming.resume == nil ? forceReuse : resuming.forceResume,
            mutant: lone.mutant
        )
    }

    func run() async throws {
        try await run(with: runOptions)
    }

    /// `--resume` continues a run's own results file and `--reuse` starts a new one, so only one can be given.
    /// `--reuse-ignoring` and `--force-reuse` only say what a reuse may reuse, as `--resume-ignoring` and
    /// `--force-resume` say what a resume may (`ResumeArguments`). `--since` chooses the files itself, and
    /// `--changed-lines` narrows its choice. `--seed` only says which sample `--sample` takes, and the shards of a
    /// sampled split, and a resume of a sample, need it to take the same one: a seed SwiftMutator chose would differ.
    /// `--mutant` names its mutant alone, so no other option that chooses mutants, nor one that continues a run, can
    /// be given with it.
    func validate() throws {
        if since != nil, !selection.filesToMutate.isEmpty {
            throw ValidationError("--since and --files-to-mutate can't be given together.")
        }
        if since == nil, changedLines {
            throw ValidationError("--changed-lines only applies with --since.")
        }
        // No ref starts with a dash, and git would read one that did as an option.
        if since?.hasPrefix("-") == true {
            throw ValidationError("--since takes a git ref, such as main or origin/main, not an option.")
        }
        try validateSample()
        try validateMutant()
        if resuming.resume != nil, reuse != nil {
            throw ValidationError("--resume and --reuse can't be given together.")
        }
        if reuse == nil {
            if !reuseIgnoring.isEmpty {
                throw ValidationError("--reuse-ignoring only applies with --reuse.")
            }
            if forceReuse {
                throw ValidationError("--force-reuse only applies with --reuse.")
            }
        }
    }
}

private extension Run {
    func validateMutant() throws {
        guard lone.mutant != nil else { return }
        let others: [(option: String, isGiven: Bool)] = [
            ("--operators", !selection.operators.isEmpty),
            ("--skip-operators", !selection.skipOperators.isEmpty),
            ("--files-to-mutate", !selection.filesToMutate.isEmpty),
            ("--since", since != nil),
            // 1/1 is the whole run.
            ("--shard", (shard?.count ?? 1) > 1),
            ("--sample", sample != nil),
            ("--resume", resuming.resume != nil),
            ("--reuse", reuse != nil),
        ]
        if let other = others.first(where: \.isGiven) {
            throw ValidationError("--mutant can't be given with \(other.option).")
        }
    }

    func validateSample() throws {
        if seed != nil, sample == nil {
            throw ValidationError("--seed only applies with --sample.")
        }
        guard sample != nil, seed == nil else { return }
        if let shard, shard.count > 1 {
            throw ValidationError("--sample with --shard needs --seed, so that every shard takes the same sample.")
        }
        if resuming.resume != nil {
            throw ValidationError(
                "--sample with --resume needs the sample's --seed, which the Continue line gives, and the results "
                    + "file's header records as sample.seed."
            )
        }
    }
}
