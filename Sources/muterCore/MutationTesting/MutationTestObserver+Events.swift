extension MutationTestObserver {
    /// Reports `event` as it happens, by the part of the run it is about.
    func handle(_ event: RunEvent) {
        switch event {
        case .muterLaunched, .updateCheckStarted, .updateCheckFinished, .configurationKeysUnknown,
             .configurationWorkedOut, .changesSelected, .logFoldersPruned, .projectCopyStarted:
            handleLaunchEvent(event)

        case .projectCopySkippedVanishedFiles, .projectCopyFinished, .codeOutsideTheProjectBuilt,
             .projectCodeNamedByAbsolutePath, .swiftLintPhasesTurnedOff, .projectCoverageDiscoveryStarted,
             .projectCoverageDiscoveryFinished, .projectCoverageTestsFailed:
            handleProjectCopyEvent(event)

        case .sourceFileDiscoveryStarted, .packageSourceFilesUnavailable, .filesToMutateUnmatched,
             .buildConditionsUnavailable, .sourceFileDiscoveryFinished, .mutationsDiscoveryStarted,
             .mutationsDiscoveryFinished, .mutantsSelected:
            handleDiscoveryEvent(event)

        case .mutantsDropped, .resumePlanned, .mutationTestingStarted, .mutantRunsStarted, .stillTesting,
             .workersChosen, .stopAtFirstFailureTurnedOff, .testBundlesNotRunDirectly:
            handleTestingStartEvent(event)

        case .timedTestRunStopped, .stoppedRunRecorded, .workersShareUserDefaults, .testBundlesWroteInTheProject,
             .buildingAgainWithoutMutants, .buildingAgainWithSwitchesInAClosure, .stoppedTakingOutMutants,
             .mutantsLeftOutOfTheBuild:
            handleRunEvent(event)

        case .activationNotShown, .unprovenRunsRerunStarted, .unprovenRunRerun, .unprovenRunsRerunFinished,
             .suspectKillRerunsSkipped, .suspectKillRerunsStarted, .suspectKillRerun, .suspectKillRerunsFinished:
            handleUnprovenAndSuspectRerunEvent(event)

        case .timeoutRerunsStarted, .timeoutRerunFinished, .timeoutRerunsFinished, .propertyRerunsStarted,
             .propertyRerunsFinished, .propertyRerunsSkipped, .runRepeatedAfterLaunchFailure,
             .baselineRepeatedAfterLaunchFailure:
            handleRepeatedRunEvent(event)

        case .controlRunFinished, .oneMutantTested, .mutationTestingFinished, .mutationTestingEndedEarly,
             .newMutationTestOutcomeAvailable, .newTestLogAvailable, .resultsFileCreated, .resultsFileUnavailable:
            handleResultEvent(event)

        case .testPlanFileCreated, .muterMutationTestPlanLoaded, .testPlanSourcesUnchecked, .testPlanSourcesDiffer,
             .testPlanUntestedFilesChanged, .testPlanChangesWaived, .testPlanCopyEdited,
             .testPlanCopyResolutionChanged:
            handleTestPlanEvent(event)
        }
    }

    /// What the events of the run's start say: the launch, the update check, the configuration, `--since`'s
    /// choice, the pruned log folders and the start of the project's copy.
    private func handleLaunchEvent(_ event: RunEvent) {
        switch event {
        case .muterLaunched:
            logger.launched()

        case .updateCheckStarted:
            logger.updateCheckStarted()

        case let .updateCheckFinished(newVersion):
            logger.updateCheckFinished(newVersion: newVersion)

        case let .configurationKeysUnknown(keys, file):
            logger.configurationKeysUnknown(keys, file: file)

        case let .configurationWorkedOut(generated, missing):
            logger.configurationWorkedOut(generated, missing: missing)

        case let .changesSelected(selection):
            sinceMergeBase = selection.mergeBase
            logger.changesSelected(selection, verbose: runOptions.verbose)

        case let .logFoldersPruned(pruning):
            logger.logFoldersPruned(pruning)

        case .projectCopyStarted:
            logger.projectCopyStarted()

        default:
            break
        }
    }

    /// What the events about the project's copy say, once it is made (`LoggerProjectCopyNotices.swift`), and those
    /// about its coverage.
    private func handleProjectCopyEvent(_ event: RunEvent) {
        switch event {
        case let .projectCopySkippedVanishedFiles(paths):
            logger.projectCopySkippedVanishedFiles(paths)

        case let .projectCopyFinished(destinationPath):
            logger.projectCopyFinished(destinationPath: destinationPath)

        case let .codeOutsideTheProjectBuilt(paths):
            logger.codeOutsideTheProjectBuilt(paths)

        case let .projectCodeNamedByAbsolutePath(paths):
            logger.projectCodeNamedByAbsolutePath(paths)

        case let .swiftLintPhasesTurnedOff(phases):
            logger.swiftLintPhasesTurnedOff(phases)

        case .projectCoverageDiscoveryStarted:
            logger.projectCoverageDiscoveryStarted()

        case let .projectCoverageDiscoveryFinished(failure):
            logger.projectCoverageDiscoveryFinished(failureReason: failure?.reason, log: failure?.log)

        case let .projectCoverageTestsFailed(failed):
            logger.projectCoverageTestsFailed(failed)

        default:
            break
        }
    }

    /// What the events of discovery say: the source files, the mutants, and those `--sample` or `--shard` chose.
    private func handleDiscoveryEvent(_ event: RunEvent) {
        switch event {
        case .sourceFileDiscoveryStarted: logger.sourceFileDiscoveryStarted()

        case let .packageSourceFilesUnavailable(reason): logger.packageSourceFilesUnavailable(reason: reason)

        case let .filesToMutateUnmatched(entries): logger.filesToMutateUnmatched(entries)

        case let .buildConditionsUnavailable(reason): logger.buildConditionsUnavailable(reason: reason)

        case let .sourceFileDiscoveryFinished(sourceFileCandidates):
            logger.sourceFileDiscoveryFinished(sourceFileCandidates: sourceFileCandidates, verbose: runOptions.verbose)

        case .mutationsDiscoveryStarted:
            logger.mutationsDiscoveryStarted()

        case let .mutationsDiscoveryFinished(mappings):
            logger.mutationsDiscoveryFinished(mutations: mappings, verbose: runOptions.verbose)

        case let .mutantsSelected(sample, shard, mappings):
            logger.mutationsDiscoveryFinished(
                mutations: mappings,
                verbose: runOptions.verbose,
                sample: sample.map { (selection: $0, seedIsChosen: runOptions.sample?.seedIsChosen ?? false) },
                shard: shard
            )

        default:
            break
        }
    }

    /// What the events as mutation testing starts say: the mutants dropped or resumed, the workers, and how the
    /// runs are made.
    private func handleTestingStartEvent(_ event: RunEvent) {
        switch event {
        case let .mutantsDropped(dropped):
            logger.mutantsDropped(dropped, verbose: runOptions.verbose)

        case let .resumePlanned(summary):
            logger.resumePlanned(summary)

        case .mutationTestingStarted:
            logger.mutationTestingStarted()

        case .mutantRunsStarted:
            logger.mutantRunsStarted()

        case let .stillTesting(still):
            logger.stillTesting(still)

        case let .workersChosen(choice):
            choice.sentence.map(logger.print)

        case let .stopAtFirstFailureTurnedOff(reason):
            logger.stopAtFirstFailureTurnedOff(reason: reason)

        case let .testBundlesNotRunDirectly(reason):
            logger.testBundlesNotRunDirectly(reason: reason)

        default:
            break
        }
    }

    /// What the events about the test runs and the mutants' build say.
    private func handleRunEvent(_ event: RunEvent) {
        switch event {
        case let .timedTestRunStopped(seconds, log):
            logger.timedTestRunStopped(seconds: seconds, log: log)

        case let .stoppedRunRecorded(path):
            logger.stoppedRunRecorded(path: path)

        case .workersShareUserDefaults:
            logger.workersShareUserDefaults()

        case let .testBundlesWroteInTheProject(path):
            logger.testBundlesWroteInTheProject(path: path)

        case let .buildingAgainWithoutMutants(count):
            logger.buildingAgainWithoutMutants(count: count)

        case let .buildingAgainWithSwitchesInAClosure(count):
            logger.buildingAgainWithSwitchesInAClosure(count: count)

        case let .stoppedTakingOutMutants(builds):
            logger.stoppedTakingOutMutants(afterBuilds: builds)

        case let .mutantsLeftOutOfTheBuild(leftOut):
            logger.mutantsLeftOutOfTheBuild(leftOut)

        default:
            break
        }
    }

    /// What the events about the runs that showed no activation, and the reruns of unproven and suspect kills, say.
    private func handleUnprovenAndSuspectRerunEvent(_ event: RunEvent) {
        switch event {
        case let .activationNotShown(runs):
            logger.activationNotShown(runs: runs)

        case let .unprovenRunsRerunStarted(count):
            logger.unprovenRunsRerunStarted(count: count)

        case let .unprovenRunRerun(mutation, changed):
            // As a timeout's: a verdict that didn't change is no news, and the logger's outcome counts the progress.
            reportRerun(mutation, ifChanged: changed)

        case let .unprovenRunsRerunFinished(tally):
            logger.unprovenRunsRerunFinished(tally)

        case let .suspectKillRerunsSkipped(log):
            logger.suspectKillRerunsSkipped(log: log)

        case let .suspectKillRerunsStarted(reruns):
            logger.suspectKillRerunsStarted(reruns)

        case let .suspectKillRerun(mutation, changed):
            // As a timeout's: a verdict that didn't change is no news, and the logger's outcome counts the progress.
            reportRerun(mutation, ifChanged: changed)

        case let .suspectKillRerunsFinished(tally):
            logger.suspectKillRerunsFinished(tally)

        default:
            break
        }
    }

    /// What the events about the timeout and property reruns, and the runs repeated after a failed launch, say.
    private func handleRepeatedRunEvent(_ event: RunEvent) {
        switch event {
        case let .timeoutRerunsStarted(reruns):
            logger.timeoutRerunsStarted(reruns)

        case let .timeoutRerunFinished(rerun):
            // A verdict that didn't change is no news. Never the logger's outcome or log, which count the progress
            // again.
            reportRerun(rerun.rerun, ifChanged: rerun.changed)
            logger.timeoutRerunFinished(rerun)

        case let .timeoutRerunsFinished(tally):
            logger.timeoutRerunsFinished(tally)

        case let .propertyRerunsStarted(reruns):
            logger.propertyRerunsStarted(reruns)

        case let .propertyRerunsFinished(tally):
            logger.propertyRerunsFinished(tally)

        case let .propertyRerunsSkipped(reason, log):
            logger.propertyRerunsSkipped(reason: reason, log: log)

        case let .runRepeatedAfterLaunchFailure(repeated):
            logger.runRepeatedAfterLaunchFailure(repeated)

        case let .baselineRepeatedAfterLaunchFailure(line, log):
            logger.baselineRepeatedAfterLaunchFailure(line: line, keptFileName: log.keptFileName)

        default:
            break
        }
    }

    /// What the events about the control runs, the mutants' outcomes and logs, the results file and the run's end
    /// say.
    private func handleResultEvent(_ event: RunEvent) {
        switch event {
        case let .controlRunFinished(control):
            logger.controlRunFinished(control)

        case let .oneMutantTested(run):
            oneMutantRun = run

        case let .mutationTestingFinished(outcome):
            mutationTestingFinished(outcome)

        case let .mutationTestingEndedEarly(earlyEnd):
            mutationTestingEndedEarly(earlyEnd)

        case let .newMutationTestOutcomeAvailable(mutation):
            runOptions.reportOptions.reporter.newMutationTestOutcomeAvailable(
                outcomeWithFlush: MutationOutcomeWithFlush(mutation: mutation, fflush: flushStdOut)
            )
            logger.newMutationTestOutcomeAvailable(mutation: mutation)

        case let .newTestLogAvailable(mutationTestLog):
            logger.newMutationTestLogAvailable(mutationTestLog: mutationTestLog)

        case let .resultsFileCreated(path):
            resultsFilePath = path
            logger.resultsFileCreated(atPath: path)

        case let .resultsFileUnavailable(reason):
            // The file, if there is one, lacks every result after the failed write, so the end of the run doesn't name
            // it.
            resultsFilePath = nil
            logger.resultsFileUnavailable(reason: reason)

        default:
            break
        }
    }

    /// What a test plan's events say, as they're made or checked.
    private func handleTestPlanEvent(_ event: RunEvent) {
        switch event {
        case let .testPlanFileCreated(created):
            logger.testPlanFileCreated(created)

        case .muterMutationTestPlanLoaded:
            logger.muterMutationTestPlanLoaded()

        case .testPlanSourcesUnchecked:
            logger.testPlanSourcesUnchecked()

        case let .testPlanSourcesDiffer(changes):
            logger.testPlanSourcesDiffer(changes)

        case let .testPlanUntestedFilesChanged(changes):
            logger.testPlanUntestedFilesChanged(changes)

        case let .testPlanChangesWaived(paths):
            logger.testPlanChangesWaived(paths)

        case let .testPlanCopyEdited(paths):
            logger.testPlanCopyEdited(paths)

        case let .testPlanCopyResolutionChanged(changes):
            logger.testPlanCopyResolutionChanged(changes)

        default:
            break
        }
    }

    /// Tells the reporter of a rerun's verdict, `mutation`, if it `changed`.
    private func reportRerun(_ mutation: MutationTestOutcome.Mutation, ifChanged changed: Bool) {
        guard changed else { return }
        runOptions.reportOptions.reporter.newMutationTestOutcomeAvailable(
            outcomeWithFlush: MutationOutcomeWithFlush(mutation: mutation, fflush: flushStdOut)
        )
    }
}
