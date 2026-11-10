/// What a resumed run says before it tests anything, or a run that reuses an earlier run's results: how many of the
/// results file's results still hold, how many mutants are left to test and why, how its discovery differs from the
/// last session's, and what changed that it let through, or that made a reuse test everything again.
struct ResumeSummary: Equatable {
    /// What chose a run's mutants beyond discovery: its `--since` choice, `--shard` and `--sample`.
    struct Selection {
        var since: ChangeSelection?
        var shard: Shard?
        var sample: Sample?
    }

    /// The results file.
    let path: String
    /// Whether the run reuses the file's results in a file of its own (`--reuse`), rather than resuming its run.
    var isReuse = false
    /// How many recorded results still hold, and are kept rather than tested again.
    let reused: Int
    /// How many mutants are left to test, which the progress bar or the progress lines count.
    let toTest: Int
    /// How many of `toTest` are tested for each reason; a reason with none is absent.
    let retestedBecause: [ResumePlan.Reason: Int]
    /// How many recorded results no longer count because this run doesn't discover their mutants.
    let noLongerDiscovered: Int
    /// How many recorded results no longer count because this run's sample leaves out their mutants.
    var outsideTheSample = 0
    /// Whether this run tests a sample that leaves some mutants out: then how many mutants it tests is the sample's
    /// count, which a change can move as new mutants rank into the sample, not what discovery found.
    var sampleIsPartial = false
    /// Only in a reuse of another sample, or of none: `selectionChange` says why this run's sample doesn't hold the
    /// earlier results, which `outsideTheSample` then needn't.
    var sampleChanged = false
    /// How many mutants the last session discovered.
    let discoveredBefore: Int
    /// How this run's coverage differs from the last session's, which may say why their mutants differ.
    let coverageChange: ResumeCheck.CoverageChange?
    /// The build and toolchain differences `--force-resume` let through, by their names in the header's `provenance`.
    let forced: [String]
    /// The changed project files `--resume-ignoring` let through, by their paths.
    let waived: [String]
    /// The test plan's copy, when the run tests a plan: `waived` are then the copy's files, by their paths relative to
    /// it, as a resume of a plan compares the copy, not the project.
    var testPlanCopy: String?
    /// A sentence for each change no result depends on.
    let notices: [String]
    /// A reuse's changed files other than test files that no `--reuse-ignoring` glob let through: they make it test
    /// every mutant again.
    var otherFilesChanged: [ProjectTree.FileChange] = []
    /// How many test files a reuse found changed, added or removed.
    var testFilesChanged = 0
    /// Only in a reuse whose `--since` choice, `--shard` or `--sample` differs from the earlier run's: why the two
    /// discover other mutants, which is then said in place of a warning that they do.
    var selectionChange: String?

    /// How many mutants this run discovered: each is either kept or tested.
    var discovered: Int {
        reused + toTest
    }
}
