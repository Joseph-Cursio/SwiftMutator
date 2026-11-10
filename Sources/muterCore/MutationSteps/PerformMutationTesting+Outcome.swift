import Foundation
import SwiftSyntax

/// The outcome a session reports, at its end or once it stops early.
extension PerformMutationTesting {
    /// Sends what mutation testing that stopped early tested, and the results a resumed session kept, for the partial
    /// report and the summary, once the baseline has passed. Before then there is nothing to report, and an abort says
    /// why.
    func sendEarlyEnd(
        of session: TestingSession,
        _ reason: ResultsEnd.Reason,
        detail: String?,
        state: AnyMutationTestState,
        testDuration: TimeInterval
    ) {
        guard session.baselinePassed else { return }
        var outcome = MutationTestOutcome(
            mutations: session.outcomesInJobOrder,
            coverage: state.projectCoverage.limited(
                to: state.changeSelection,
                inCopyAt: state.mutatedProjectDirectoryURL
            ),
            coverageSkipped: state.runOptions.skipCoverage,
            testDuration: testDuration,
            newVersion: state.newVersion,
            since: state.changeSelection,
            shards: state.shardSelection?.scopeAlone,
            sample: state.sampleSelection,
            // As `report` of the results file judges it: a run can stop after its last mutant's result.
            sampleIsCutShort: session.outcomesInJobOrder.count < session.keys.count,
            mutant: state.selectedMutant?.description,
            suspectTestThresholds: state.muterConfiguration.suspectTestThresholds,
            failUnder: state.muterConfiguration.failUnder,
            propertyTests: state.muterConfiguration.propertyTests ?? [],
            reports: state.muterConfiguration.reportRequests(in: state.projectDirectoryURL),
            triage: Self.triageFile(of: state),
            controlRuns: Self.controlRuns(of: session, state: state),
            projectPath: state.projectDirectoryURL.path,
            mutatedProjectPath: state.mutatedProjectDirectoryURL.path,
            sourceDigests: Self.sourceDigests(of: state),
            run: Self.runDetails(of: session, state: state)
        )
        Self.addBaseline(of: state, to: &outcome)
        events.send(
            .mutationTestingEndedEarly(EarlyEnd(
                reason: reason,
                detail: detail,
                outcome: outcome,
                discovered: session.keys.count,
                reused: session.reused,
                leftOut: session.leftOut
            ))
        )
    }

    /// Gives `outcome` what the end of the run compares its survivors with, and saves them by: `--baseline`'s file, as
    /// loaded when the run started (`LoadBaselineFile`), `--max-new-survivors` and `--max-score-drop`, and
    /// `--max-doubtful-kills`, which needs no file; the run's scope, which a baseline
    /// file records, as `report` of the results file has it from their header; and its `--files-to-mutate`, of which
    /// no file is written; and the mutants of code no test ran, which a baseline file records as survivors. With
    /// `--baseline`'s file, the mutants the run left out, which its entries for them are paired with.
    static func addBaseline(of state: AnyMutationTestState, to outcome: inout MutationTestOutcome) {
        outcome.baseline = state.baselineFile
        if state.baselineFile != nil {
            outcome.unselectedMutants = state.unselectedMutants
        }
        // With `--skip-coverage` every mutant is made, so none is left for not being covered.
        outcome.uncoveredMutants = state.uncoveredMutants ?? (state.runOptions.skipCoverage ? [] : nil)
        outcome.maxNewSurvivors = state.runOptions.maxNewSurvivors ?? 0
        outcome.maxScoreDrop = state.runOptions.maxScoreDrop
        outcome.maxDoubtfulKills = state.runOptions.maxDoubtfulKills
        outcome.baselineScope = LoadBaselineFile.scope(of: state)
        outcome.filesToMutate = state.filesToMutate
    }

    /// The project's triage file, as it is when the report is made, so a label given during a long run shows. Checked
    /// as the run starts (`LoadConfiguration`), so one that broke since costs only its labels, never the run's report.
    static func triageFile(of state: AnyMutationTestState) -> TriageFile? {
        let path = TriageFile.path(in: state.projectDirectoryURL.path)
        do {
            return try TriageFile.load(at: path, using: dependency(\.fileManager))
        } catch {
            dependency(\.errorPrinter)("⚠️ The report shows no triage labels: \(error)")
            return nil
        }
    }

    /// Each project file's SHA-256 as it was tested, by its path in the project, which the reports check a file
    /// against before showing a mutant's line from it: the project tree's, or for a run of a test plan, whose tree is
    /// its rewritten copy, what the plan recorded of the project when it was made. nil for a plan in format 0, which
    /// records nothing.
    static func sourceDigests(of state: AnyMutationTestState) -> [String: String]? {
        guard let plan = state.testPlan else { return state.projectTree?.files }
        // A file with mutants that is a symbolic link is recorded by what its link's file held.
        return plan.sources.map { $0.files.merging(plan.linkedFiles ?? [:]) { _, linked in linked } }
    }

    /// Where `session`'s results came from, once its header is written to its results file: that file, with the
    /// headers of the sessions a resumed run's file holds before it. nil once a write to the file has failed: the file
    /// then lacks some of the session's results, and the run no longer names it.
    static func runDetails(of session: TestingSession, state: AnyMutationTestState) -> RunDetails? {
        guard !session.saidResultsUnwritable, let header = session.header, let path = session.resultsPath else {
            return nil
        }
        let earlier = state.resumeState.map { $0.isReuse ? [] : $0.recorded.headers } ?? []
        return RunDetails(of: [(path, earlier + [header])])
    }
}
