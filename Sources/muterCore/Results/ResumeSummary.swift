import Foundation

/// What a resumed run says before it tests anything: how many of its results file's results still hold, how many
/// mutants are left to test and why, how its discovery differs from the last session's, and what changed that it let
/// through.
struct ResumeSummary: Equatable {
    /// The results file.
    let path: String
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

    /// How many mutants this run discovered: each is either kept or tested.
    var discovered: Int {
        reused + toTest
    }
}

extension ResumeSummary {
    /// The summary of `plan`, made for the resume of `resume`, which let the changed files `waived` through, by a run
    /// that gathered `coverage` in the project copy at `mutatedProject`.
    init(_ resume: ResumeState, _ plan: ResumePlan, waived: [String], coverage: Coverage, in mutatedProject: URL) {
        self.init(
            path: resume.path,
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
            notices: resume.notices
        )
    }
}
