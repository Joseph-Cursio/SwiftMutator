import Foundation

/// What a resumed run says before it tests anything, or a run that reuses an earlier run's results: how many of the
/// results file's results still hold, how many mutants are left to test and why, how its discovery differs from the
/// last session's, and what changed that it let through, or that made a reuse test everything again.
struct ResumeSummary: Equatable {
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
    /// How many mutants the last session discovered.
    let discoveredBefore: Int
    /// How this run's coverage differs from the last session's, which may say why their mutants differ.
    let coverageChange: ResumeCheck.CoverageChange?
    /// The build and toolchain differences `--force-resume` let through, by their names in the header's `provenance`.
    let forced: [String]
    /// The changed project files `--resume-ignoring` let through, by their paths.
    let waived: [String]
    /// A sentence for each change no result depends on.
    let notices: [String]
    /// A reuse's changed files other than test files that no `--reuse-ignoring` glob let through: they make it test
    /// every mutant again.
    var otherFilesChanged: [ProjectTree.FileChange] = []
    /// How many test files a reuse found changed, added or removed.
    var testFilesChanged = 0
    /// Only in a reuse whose `--since` choice differs from the earlier run's: why the two discover other mutants, which
    /// is then said in place of a warning that they do.
    var selectionChange: String?

    /// How many mutants this run discovered: each is either kept or tested.
    var discovered: Int {
        reused + toTest
    }
}

extension ResumeSummary {
    /// The summary of `plan`, made for the resume of `resume`, which let the changed files `waived` through, by a run
    /// that gathered `coverage` in the project copy at `mutatedProject`. A reuse passes what changed (`changes`).
    init(
        _ resume: ResumeState,
        _ plan: ResumePlan,
        waived: [String],
        coverage: Coverage,
        in mutatedProject: URL,
        reusing changes: [Int: ReuseChanges]? = nil,
        since selection: ChangeSelection? = nil
    ) {
        let all = changes.map { Array($0.values) } ?? []
        let otherFiles = Dictionary(
            all.flatMap(\.otherFiles).map { ($0.path, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let testFiles = Set(all.flatMap(\.testFiles).map(\.path))
        self.init(
            path: resume.path,
            isReuse: resume.isReuse,
            reused: plan.reused.count,
            toTest: plan.toRun.count,
            retestedBecause: plan.retestedBecause,
            noLongerDiscovered: plan.noLongerDiscovered,
            discoveredBefore: resume.lastHeader.mutantsDiscovered,
            coverageChange: ResumeCheck.coverageChange(
                from: resume.lastHeader.coverage,
                in: URL(fileURLWithPath: resume.lastHeader.mutatedProjectPath, isDirectory: true),
                to: CoverageSummary(coverage),
                in: mutatedProject
            ),
            forced: resume.forced,
            waived: waived,
            notices: resume.notices,
            otherFilesChanged: otherFiles.values.sorted { $0.path < $1.path },
            testFilesChanged: testFiles.count,
            selectionChange: resume.isReuse ? Self.selectionChange(from: resume.lastHeader.since, to: selection) : nil
        )
    }

    /// Why a reuse whose `--since` choice is `current` discovers other mutants than the earlier run, whose choice was
    /// `earlier`; nil when the two chose the same, or neither chose.
    static func selectionChange(from earlier: ChangeSelection?, to current: ChangeSelection?) -> String? {
        func same(_ one: ChangeSelection, _ other: ChangeSelection) -> Bool {
            one.mergeBase == other.mergeBase && one.changedLines == other.changedLines
                && one.files.map(\.path) == other.files.map(\.path)
        }
        switch (earlier, current) {
        case (nil, nil):
            return nil
        case let (earlier?, current?) where same(earlier, current):
            return nil
        case let (_, current?):
            return "This run mutates only what changed since the merge base of \(current.ref) and HEAD "
                + "(\(current.shortMergeBase)), so no earlier result of another mutant is reused."
        case let (earlier?, nil):
            return "That run mutated only what changed since the merge base of \(earlier.ref) and HEAD "
                + "(\(earlier.shortMergeBase)), so this run's other mutants have no earlier result."
        }
    }
}
