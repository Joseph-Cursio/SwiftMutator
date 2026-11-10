import Foundation
import SwiftSyntax

/// What a session keeps of a resumed or reused run's results, and the header that says so.
extension PerformMutationTesting {
    /// Every discovered mutant, in job order: file by file as discovery mapped them, and in each file in its order.
    static func jobs(of state: AnyMutationTestState) -> [MutantJob] {
        state.mutationMapping.flatMap { mutationMap in
            mutationMap.mutationSchemata.map { MutantJob(fileName: mutationMap.fileName, schema: $0) }
        }
    }

    /// Which of the results file's results a resumed or reused run keeps for `jobs`, keyed by `keys`, and which jobs it
    /// tests; every job, for a run that does neither.
    static func plan(of jobs: [MutantJob], keyedBy keys: [MutantKey], state: AnyMutationTestState) -> ResumePlan {
        state.resumeState.map { resume in
            ResumePlan.make(
                keys: keys,
                snapshots: jobs.map(\.schema.snapshot),
                recorded: resume.recorded.latest,
                fileHashes: state.projectTree?.files ?? [:],
                workers: ResumePlan.workers(of: resume.recorded.headers),
                limits: ResumePlan.limits(of: resume.recorded.headers),
                limit: state.muterConfiguration.testSuiteTimeout,
                reusing: resume.isReuse ? state.reuseChanges : nil,
                leftOut: state.keysLeftOutOfTheSample,
                sessionsShowingNoCode: ResumePlan.showingNoCode(resume.recorded.sessions)
            )
        } ?? .everything(jobs.count)
    }

    /// The results `plan` keeps, by job index: as recorded for a resume, and for a reuse as the new results file
    /// records them (`MutantResult.reused`), each in its job's place, with where it was tested and what was let
    /// through since, and with a log only if this run would keep one for it.
    func keptResults(_ plan: ResumePlan, of jobs: [MutantJob], state: AnyMutationTestState) -> [Int: MutantResult] {
        guard let resume = state.resumeState, resume.isReuse else { return plan.reused }
        return plan.reused.reduce(into: [:]) { kept, entry in
            let schema = jobs[entry.key].schema
            kept[entry.key] = entry.value.reused(
                from: resume.path,
                headers: resume.recorded.headers,
                in: 1,
                utf8Offset: schema.position.utf8Offset,
                switchID: schema.id,
                // What this run let through since the session that tested it, not since another session.
                despiteChanges: state.reuseChanges?[entry.value.session]?.waived.isEmpty == false
                    || !resume.forced.isEmpty,
                keepingLog: Self.keepsLog(of: entry.value, reusedBy: state)
            )
        }
    }

    /// Keeps each of the `reused` results' outcomes in `session` by job index, built from its job as `record` builds a
    /// tested one's, with the tests its line names, and sends it to the reporter, so the Xcode format warns of every
    /// survivor. Never sends a test log, and comes before the baseline's log, so no progress bar or lines count it.
    func keepReused(
        _ reused: [Int: MutantResult],
        of jobs: [MutantJob],
        in session: TestingSession,
        state: AnyMutationTestState
    ) {
        // A resume keeps the property reruns its file records for the results it keeps; a reuse's are another file's,
        // which this one doesn't hold, so its session runs them again.
        let reruns = state.resumeState.flatMap { $0.isReuse ? nil : $0.recorded.propertyReruns } ?? [:]
        for (index, result) in reused.sorted(by: { $0.key < $1.key }) {
            var outcome = Self.outcome(
                result.outcome,
                of: jobs[index],
                state: state,
                killingTests: .init(result),
                reusedFrom: result.reusedFrom,
                key: result.key,
                durationSeconds: result.durationSeconds,
                activated: result.activated
            )
            outcome.propertyRerun = reruns[result.key]?.rerun
            outcome.rerun = result.rerun
            session.outcomes[index] = outcome
            session.reused += 1
            events.send(.newMutationTestOutcomeAvailable(outcome))
        }
    }

    /// The session's header, for testing `plan.toRun` of the jobs `session.keys` are of, with `configuration`, the
    /// effective one, on `workers` workers. A resumed session's says what it kept, and what its resume let through. A
    /// reuse's says whether any line it copies names no log.
    func header(
        of session: TestingSession,
        _ plan: ResumePlan,
        state: AnyMutationTestState,
        configuration: MuterConfiguration,
        baselineSeconds: Double?,
        testRunSeconds: Double? = nil,
        workers: Int
    ) async -> ResultsHeader {
        let resume = state.resumeState
        // A resume's was probed before the copy, and what was checked is what is recorded.
        let sessionProvenance = if let recorded = resume?.provenance {
            recorded
        } else {
            await provenance(state.muterConfiguration)
        }
        return ResultsHeader(
            session: session.number,
            startedAt: session.startedAt,
            state: state,
            logDirectory: state.loggingDirectory,
            configuration: configuration,
            baselineSeconds: baselineSeconds,
            testRunSeconds: testRunSeconds,
            workers: workers,
            mutantsDiscovered: session.keys.count,
            mutantsToTest: plan.toRun.count,
            provenance: sessionProvenance,
            mutantsReused: resume == nil ? nil : plan.reused.count,
            waived: resume == nil ? nil : state.resumeWaived,
            forced: resume?.forced,
            reusedFrom: resume?.isReuse == true ? resume?.path : nil,
            copyingLinesWithoutLogs: Self.copiesLinesWithoutLogs(plan, state: state)
        )
    }
}
