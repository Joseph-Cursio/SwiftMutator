/// What the property survivor reruns came to (`PropertySurvivorReruns`): of the survivors tested again with only the
/// property tests, up to `propertySurvivorReruns` times each, those a property test failed for on some run, those every
/// run passed for, and those a run settled nothing for. Survivors all stay survivors: this changes no score. Counts
/// only, as the JSON report has it; the plain and HTML reports also list the survivors a property told apart
/// (`toldApart(in:)`).
struct PropertySurvivorRerunSummary: Codable, Equatable {
    /// A survivor a property test failed for on a later run: where it is, and on which run of how many.
    struct ToldApart: Equatable {
        let path: String
        let line: Int
        let column: Int
        let mutationOperator: String
        let failedOnRun: Int
        let runs: Int
        /// The first property test the run recorded failing, if it named one.
        let test: String?
    }

    /// How many survivors were tested again.
    let survivorsTestedAgain: Int
    /// How many a property test failed for, or crashed for, on some run.
    let failedOnALaterRun: Int
    /// How many every run passed for.
    let passedEveryRun: Int
    /// How many a run timed out or failed to build for, which settles nothing.
    let unsettled: Int
    /// The most runs any of them was to be given.
    let runs: Int

    /// The summary of `mutations`' property survivor reruns; nil when none was tested again.
    init?(of mutations: [MutationTestOutcome.Mutation]) {
        let reruns = mutations.compactMap(\.propertySurvivorRerun)
        guard !reruns.isEmpty else { return nil }
        survivorsTestedAgain = reruns.count
        failedOnALaterRun = reruns.count { $0.failedOnRun != nil }
        passedEveryRun = reruns.count(where: \.passedEveryRun)
        unsettled = survivorsTestedAgain - failedOnALaterRun - passedEveryRun
        runs = reruns.map(\.runs).max() ?? 0
    }

    /// The survivors of `outcome` a property test failed for on a later run, by place.
    static func toldApart(in outcome: MutationTestOutcome) -> [ToldApart] {
        outcome.mutations.compactMap { mutation -> ToldApart? in
            guard let rerun = mutation.propertySurvivorRerun, let run = rerun.failedOnRun else { return nil }
            return ToldApart(
                path: mutation.relativePath,
                line: mutation.point.position.line,
                column: mutation.point.position.column,
                mutationOperator: mutation.point.mutationOperatorId.rawValue,
                failedOnRun: run,
                runs: rerun.runs,
                test: rerun.killingTests?.tests.first?.name
            )
        }
        .sorted { ($0.path, $0.line, $0.column) < ($1.path, $1.line, $1.column) }
    }

    /// What the reports say of the reruns, a sentence to each line.
    var sentences: [String] {
        let survivors = survivorsTestedAgain == 1 ? "1 survivor" : "\(survivorsTestedAgain) survivors"
        let times = runs == 1 ? "once" : "up to \(runs) times each"
        var lines = [
            "The property tests ran again on their own for \(survivors) whose code ran, \(times), stopping at the "
                + "first failure (propertySurvivorReruns). A property test tries a sample of inputs, so a survivor may "
                + "only have missed the one that tells it apart.",
            "A property test failed on a later run for \(failedOnALaterRun): its law holds the change, and its "
                + "generator rarely reaches an input that shows it, so a generator that tries edge cases would.",
            "Every run passed for \(passedEveryRun): no property reaches the change, or the mutant is equivalent. "
                + "Neither proves which.",
        ]
        if unsettled > 0 {
            lines.append("\(unsettled) timed out or didn't build on a run, which settles nothing.")
        }
        lines.append("They all stay survivors in the score, --fail-under and --baseline.")
        return lines
    }
}
