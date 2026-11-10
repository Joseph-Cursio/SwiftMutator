import Foundation
import SwiftSyntax

/// How a mutant's run is recorded: its result line, its outcome in the session, its log and its events.
extension PerformMutationTesting {
    /// What a session's runs are recorded against: the run's state, the effective configuration they ran with, whose
    /// baseline may have made failed-test lines unreliable, and the session that keeps their outcomes and lines.
    struct RunContext {
        let state: AnyMutationTestState
        let configuration: MuterConfiguration
        let session: TestingSession

        /// The same context, for runs with `configuration`, such as the property reruns' filtered one.
        func with(_ configuration: MuterConfiguration) -> Self {
            Self(state: state, configuration: configuration, session: session)
        }
    }

    /// Records `finished`, the run of `job`'s mutant (`keep`), sends its events, and aborts after
    /// `buildErrorsThreshold` build errors in a row, not counting a mutant that an earlier session recorded as one
    /// (`TestingSession.earlierBuildErrors`). The outcome is kept before the abort, so mutation testing that stops
    /// there still has it. The run of the one mutant `--mutant` tests also sends what the end of the run prints of it.
    func record(
        _ finished: FinishedRun,
        of job: MutantJob,
        in context: RunContext,
        buildErrors: inout Int
    ) throws {
        let (outcome, mutationLog) = try keep(
            finished, of: job, rerun: nil, in: context
        )

        events.send(.newMutationTestOutcomeAvailable(outcome))

        events.send(.newTestLogAvailable(mutationLog))

        if context.state.selectedMutant != nil {
            events.send(
                .oneMutantTested(OneMutantRun(
                    key: context.session.keys[finished.index],
                    switchID: job.schema.id,
                    snapshot: job.schema.snapshot,
                    change: change(
                        of: job.schema, key: context.session.keys[finished.index], in: outcome, state: context.state
                    ),
                    outcome: outcome.testSuiteOutcome,
                    killingTests: outcome.killingTests,
                    seconds: finished.seconds,
                    timeoutSeconds: context.configuration.testSuiteTimeout,
                    testLog: finished.run.testLog,
                    logPath: context.state.loggingDirectory.isEmpty
                        ? nil
                        : context.state.loggingDirectory.appendingPathComponent(mutationLog.keptFileName),
                    mutatedProject: context.state.mutatedProjectDirectoryURL.path,
                    buildSystem: context.configuration.buildSystem,
                    testCommand: [context.configuration.testCommandExecutable]
                        + context.configuration.testCommandArguments
                ))
            )
        }

        if finished.run.outcome != .buildError {
            buildErrors = 0
        } else if !context.session.earlierBuildErrors.contains(finished.index) {
            buildErrors += 1
        }
        if buildErrors >= buildErrorsThreshold {
            throw MuterError.mutationTestingAborted(reason: .tooManyBuildErrors)
        }
        try noteActivation(of: finished, in: context)
    }

    /// Records `finished`, the run that tested `job`'s timed-out mutant again (`keep`), counts it in `tally`, and sends
    /// its event. Never its outcome's or its log's events, which would count the mutant in the progress again, and
    /// never toward the build errors in a row: a build error here says nothing of the mutants before it.
    func recordRerun(
        _ finished: FinishedRun,
        of job: MutantJob,
        tally: inout TimeoutRerunTally,
        in context: RunContext
    ) throws {
        // Whichever run showed its block ran: a rerun that passes without showing it doesn't undo the first's. Once a
        // session's runs show they can say, one that says nothing didn't reach mutated code, as in
        // `rerunRunsNotShownToReachTheirCode`, which then tests a kill this comes to, as it failed unproven.
        if finished.run.activated != nil { context.session.activationShown = true }
        var settled = finished
        if context.session.outcomes[finished.index]?.activated == true {
            settled.run.activated = true
        } else if context.session.activationShown {
            settled.run.activated = finished.run.activated ?? false
        }
        if settled.run.activated != true, [.failed, .runtimeError].contains(finished.run.outcome) {
            context.session.killsNotShownToRunTheirCode.append(finished.index)
        }
        let (outcome, mutationLog) = try keep(
            settled,
            of: job,
            rerun: MutantResult.Rerun(because: MutantResult.Rerun.timeout, workers: tally.reruns.workers),
            in: context
        )
        tally.add(outcome.testSuiteOutcome)
        events.send(
            .timeoutRerunFinished(TimeoutRerun(
                rerun: outcome,
                log: mutationLog,
                seconds: finished.seconds,
                number: tally.rerun,
                count: tally.reruns.count
            ))
        )
    }

    /// Writes `finished`'s result, the run of `job`'s mutant, or its `rerun`, to the results file, keeps its outcome in
    /// `session`, and returns it with its log, kept under the name the line gives it by moving the file the run wrote,
    /// or discarded when the line names none (`keptLogName`). The result is written first, so it is on disk before
    /// anything else happens. `configuration` is the effective one, whose baseline may have made failed-test lines
    /// unreliable. A run on a simulator that is gone is never recorded, and aborts mutation testing
    /// (`abortingIfTheSimulatorIsGone`). A run the simulator failed to launch before this one is sent only once this
    /// one's result is written (`sendingTheRunTheSimulatorFailedToLaunch`); its log is kept whatever this one's is.
    func keep(
        _ finished: FinishedRun,
        of job: MutantJob,
        rerun: MutantResult.Rerun?,
        in context: RunContext
    ) throws -> (outcome: MutationTestOutcome.Mutation, log: MutationTestLog) {
        // The failed tests are worked out here, not in `write`'s autoclosure: the outcome needs them without a results
        // file, or after a failed write. One scan of the log serves both.
        let failures = MutantResult.failedTests(of: finished.run, ignoring: context.configuration.failedTestLookalikes)
        let key = context.session.keys[finished.index]
        var outcome = Self.outcome(
            finished.run.outcome,
            of: job,
            state: context.state,
            killingTests: .init(failures, endedBy: finished.run.ending),
            key: key,
            durationSeconds: MutantResult.recordedSeconds(finished.seconds),
            activated: finished.run.activated
        )
        outcome.rerun = rerun
        let log = switch rerun?.because {
        case nil: MutationTestLog.keptFileName(for: key)

        // A kill can be tested again for not showing its code ran, and then for this, each with a log of its own.
        case MutantResult.Rerun.onlySuspectTestsFailed: MutationTestLog.suspectRerunFileName(for: key)
        default: MutationTestLog.rerunFileName(for: key)
        }
        let keptLog = Self.keptLogName(
            log, of: finished, failures: failures, configuration: context.configuration, state: context.state
        )
        try abortingIfTheSimulatorIsGone(
            in: finished,
            logName: log,
            configuration: context.configuration,
            state: context.state
        )
        write(
            MutantResult(
                key: key,
                schema: job.schema,
                finished: finished,
                failures: failures,
                session: context.session.number,
                finishedAt: now(),
                log: keptLog,
                fileSHA256: context.state.projectTree?.files[key.path],
                rerun: rerun
            ),
            in: context.session,
            isAMutant: true
        )
        context.session.outcomes[finished.index] = outcome
        // Before any event, so a log the console names, such as `--mutant`'s, is there.
        fileManager.keepLog(
            finished.run.testLog, writtenTo: finished.output, by: ioDelegate, named: keptLog, state: context.state
        )
        sendingTheRunTheSimulatorFailedToLaunch(before: finished, of: outcome, logName: log, state: context.state)

        let mutationLog = MutationTestLog(
            mutationPoint: outcome.point,
            testLog: finished.run.testLog,
            timePerBuildTestCycle: .none,
            remainingMutationPointsCount: .none,
            keptFileName: log
        )
        return (outcome, mutationLog)
    }

    /// If the simulator failed to launch the run before `finished`, keeps its log beside `logName`, `finished`'s, and
    /// sends that run with `outcome`, `finished`'s. Called once `finished`'s result is written, so the results file has
    /// its line before the console says the mutant ran again or the first run's log is kept. The log is kept from
    /// its text: the run in its place wrote over its file.
    private func sendingTheRunTheSimulatorFailedToLaunch(
        before finished: FinishedRun,
        of outcome: MutationTestOutcome.Mutation,
        logName: String,
        state: AnyMutationTestState
    ) {
        guard let failure = finished.launchFailure else { return }
        fileManager.keepLog(failure.testLog, named: MutationTestLog.launchFailedFileName(for: logName), state: state)
        let log = MutationTestLog(
            mutationPoint: outcome.point,
            testLog: failure.testLog,
            timePerBuildTestCycle: .none,
            remainingMutationPointsCount: .none,
            keptFileName: MutationTestLog.launchFailedFileName(for: logName)
        )
        events.send(
            .runRepeatedAfterLaunchFailure(RepeatedRun(
                mutant: outcome, worker: finished.worker, line: failure.line, log: log
            ))
        )
    }
}
