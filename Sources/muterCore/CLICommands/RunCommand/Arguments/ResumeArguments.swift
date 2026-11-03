import ArgumentParser
import Foundation

/// How a stopped run is continued from its results file: by `run`, or by `run-without-mutating` for a run that tested a
/// test plan. `--resume-ignoring` and `--force-resume` only say what a resume may reuse.
struct ResumeArguments: ParsableArguments {
    @Option(
        name: .customLong("resume"),
        help: ArgumentHelp(
            "Continue a stopped run from its results file, or the log folder of any of its sessions. "
                + "Only mutants without a result that still holds are tested.",
            valueName: "results"
        )
    )
    var resume: URL?

    @Option(
        name: .customLong("resume-ignoring"),
        help: ArgumentHelp(
            "With --resume, reuse results although project files matching this glob changed; * also matches /. "
                + "Repeatable.",
            valueName: "glob"
        )
    )
    var resumeIgnoring: [String] = []

    @Flag(
        name: .customLong("force-resume"),
        help: "With --resume, reuse results although SwiftMutator, the toolchain or the SDK changed."
    )
    var forceResume = false

    func validate() throws {
        guard resume == nil else { return }
        if !resumeIgnoring.isEmpty {
            throw ValidationError("--resume-ignoring only applies with --resume.")
        }
        if forceResume {
            throw ValidationError("--force-resume only applies with --resume.")
        }
    }
}
