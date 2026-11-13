@testable import muterCore

/// Each event's name and payload, for tests that pick sent events out by name. Both switches are exhaustive, so a new
/// event needs a name here.
extension RunEvent {
    enum Name {
        case muterLaunched
        case updateCheckStarted
        case updateCheckFinished
        case configurationKeysUnknown
        case configurationWorkedOut
        case changesSelected
        case logFoldersPruned
        case projectCopyStarted
        case projectCopySkippedVanishedFiles
        case projectCopyFinished
        case codeOutsideTheProjectBuilt
        case projectCodeNamedByAbsolutePath
        case swiftLintPhasesTurnedOff
        case projectCoverageDiscoveryStarted
        case projectCoverageDiscoveryFinished
        case projectCoverageTestsFailed
        case sourceFileDiscoveryStarted
        case packageSourceFilesUnavailable
        case buildConditionsUnavailable
        case filesToMutateUnmatched
        case sourceFileDiscoveryFinished
        case mutationsDiscoveryStarted
        case mutationsDiscoveryFinished
        case mutantsSelected
        case mutantsDropped
        case resumePlanned
        case mutationTestingStarted
        case mutantRunsStarted
        case stillTesting
        case workersChosen
        case stopAtFirstFailureTurnedOff
        case testBundlesNotRunDirectly
        case timedTestRunStopped
        case stoppedRunRecorded
        case workersShareUserDefaults
        case testBundlesWroteInTheProject
        case buildingAgainWithoutMutants
        case buildingAgainWithSwitchesInAClosure
        case stoppedTakingOutMutants
        case mutantsLeftOutOfTheBuild
        case controlRunFinished
        case activationNotShown
        case unprovenRunsRerunStarted
        case unprovenRunRerun
        case unprovenRunsRerunFinished
        case suspectKillRerunsSkipped
        case suspectKillRerunsStarted
        case suspectKillRerun
        case suspectKillRerunsFinished
        case timeoutRerunsStarted
        case timeoutRerunFinished
        case timeoutRerunsFinished
        case propertyRerunsStarted
        case propertyRerunsFinished
        case propertyRerunsSkipped
        case propertySurvivorRerunsStarted
        case propertySurvivorRerunsFinished
        case propertySurvivorRerunsSkipped
        case exampleRerunsStarted
        case exampleRerunsFinished
        case exampleRerunsSkipped
        case runRepeatedAfterLaunchFailure
        case baselineRepeatedAfterLaunchFailure
        case oneMutantTested
        case mutationTestingFinished
        case mutationTestingEndedEarly
        case newMutationTestOutcomeAvailable
        case newTestLogAvailable
        case resultsFileCreated
        case resultsFileUnavailable
        case testPlanFileCreated
        case muterMutationTestPlanLoaded
        case testPlanSourcesUnchecked
        case testPlanSourcesDiffer
        case testPlanUntestedFilesChanged
        case testPlanChangesWaived
        case testPlanCopyEdited
        case testPlanCopyResolutionChanged
    }

    var name: Name {
        switch self {
        case .muterLaunched: .muterLaunched
        case .updateCheckStarted: .updateCheckStarted
        case .updateCheckFinished: .updateCheckFinished
        case .configurationKeysUnknown: .configurationKeysUnknown
        case .configurationWorkedOut: .configurationWorkedOut
        case .changesSelected: .changesSelected
        case .logFoldersPruned: .logFoldersPruned
        case .projectCopyStarted: .projectCopyStarted
        case .projectCopySkippedVanishedFiles: .projectCopySkippedVanishedFiles
        case .projectCopyFinished: .projectCopyFinished
        case .codeOutsideTheProjectBuilt: .codeOutsideTheProjectBuilt
        case .projectCodeNamedByAbsolutePath: .projectCodeNamedByAbsolutePath
        case .swiftLintPhasesTurnedOff: .swiftLintPhasesTurnedOff
        case .projectCoverageDiscoveryStarted: .projectCoverageDiscoveryStarted
        case .projectCoverageDiscoveryFinished: .projectCoverageDiscoveryFinished
        case .projectCoverageTestsFailed: .projectCoverageTestsFailed
        case .sourceFileDiscoveryStarted: .sourceFileDiscoveryStarted
        case .packageSourceFilesUnavailable: .packageSourceFilesUnavailable
        case .buildConditionsUnavailable: .buildConditionsUnavailable
        case .filesToMutateUnmatched: .filesToMutateUnmatched
        case .sourceFileDiscoveryFinished: .sourceFileDiscoveryFinished
        case .mutationsDiscoveryStarted: .mutationsDiscoveryStarted
        case .mutationsDiscoveryFinished: .mutationsDiscoveryFinished
        case .mutantsSelected: .mutantsSelected
        case .mutantsDropped: .mutantsDropped
        case .resumePlanned: .resumePlanned
        case .mutationTestingStarted: .mutationTestingStarted
        case .mutantRunsStarted: .mutantRunsStarted
        case .stillTesting: .stillTesting
        case .workersChosen: .workersChosen
        case .stopAtFirstFailureTurnedOff: .stopAtFirstFailureTurnedOff
        case .testBundlesNotRunDirectly: .testBundlesNotRunDirectly
        case .timedTestRunStopped: .timedTestRunStopped
        case .stoppedRunRecorded: .stoppedRunRecorded
        case .workersShareUserDefaults: .workersShareUserDefaults
        case .testBundlesWroteInTheProject: .testBundlesWroteInTheProject
        case .buildingAgainWithoutMutants: .buildingAgainWithoutMutants
        case .buildingAgainWithSwitchesInAClosure: .buildingAgainWithSwitchesInAClosure
        case .stoppedTakingOutMutants: .stoppedTakingOutMutants
        case .mutantsLeftOutOfTheBuild: .mutantsLeftOutOfTheBuild
        case .controlRunFinished: .controlRunFinished
        case .activationNotShown: .activationNotShown
        case .unprovenRunsRerunStarted: .unprovenRunsRerunStarted
        case .unprovenRunRerun: .unprovenRunRerun
        case .unprovenRunsRerunFinished: .unprovenRunsRerunFinished
        case .suspectKillRerunsSkipped: .suspectKillRerunsSkipped
        case .suspectKillRerunsStarted: .suspectKillRerunsStarted
        case .suspectKillRerun: .suspectKillRerun
        case .suspectKillRerunsFinished: .suspectKillRerunsFinished
        case .timeoutRerunsStarted: .timeoutRerunsStarted
        case .timeoutRerunFinished: .timeoutRerunFinished
        case .timeoutRerunsFinished: .timeoutRerunsFinished
        case .propertyRerunsStarted: .propertyRerunsStarted
        case .propertyRerunsFinished: .propertyRerunsFinished
        case .propertyRerunsSkipped: .propertyRerunsSkipped
        case .propertySurvivorRerunsStarted: .propertySurvivorRerunsStarted
        case .propertySurvivorRerunsFinished: .propertySurvivorRerunsFinished
        case .propertySurvivorRerunsSkipped: .propertySurvivorRerunsSkipped
        case .exampleRerunsStarted: .exampleRerunsStarted
        case .exampleRerunsFinished: .exampleRerunsFinished
        case .exampleRerunsSkipped: .exampleRerunsSkipped
        case .runRepeatedAfterLaunchFailure: .runRepeatedAfterLaunchFailure
        case .baselineRepeatedAfterLaunchFailure: .baselineRepeatedAfterLaunchFailure
        case .oneMutantTested: .oneMutantTested
        case .mutationTestingFinished: .mutationTestingFinished
        case .mutationTestingEndedEarly: .mutationTestingEndedEarly
        case .newMutationTestOutcomeAvailable: .newMutationTestOutcomeAvailable
        case .newTestLogAvailable: .newTestLogAvailable
        case .resultsFileCreated: .resultsFileCreated
        case .resultsFileUnavailable: .resultsFileUnavailable
        case .testPlanFileCreated: .testPlanFileCreated
        case .muterMutationTestPlanLoaded: .muterMutationTestPlanLoaded
        case .testPlanSourcesUnchecked: .testPlanSourcesUnchecked
        case .testPlanSourcesDiffer: .testPlanSourcesDiffer
        case .testPlanUntestedFilesChanged: .testPlanUntestedFilesChanged
        case .testPlanChangesWaived: .testPlanChangesWaived
        case .testPlanCopyEdited: .testPlanCopyEdited
        case .testPlanCopyResolutionChanged: .testPlanCopyResolutionChanged
        }
    }

    /// The event's payload, or nil if it has none.
    var object: Any? {
        switch self {
        case .muterLaunched, .updateCheckStarted, .projectCopyStarted, .projectCoverageDiscoveryStarted,
             .sourceFileDiscoveryStarted, .mutationsDiscoveryStarted, .mutationTestingStarted, .mutantRunsStarted,
             .workersShareUserDefaults, .muterMutationTestPlanLoaded, .testPlanSourcesUnchecked:
            nil

        case let .testBundlesWroteInTheProject(path): path
        case let .updateCheckFinished(newVersion): newVersion
        case let .buildingAgainWithoutMutants(count): count
        case let .buildingAgainWithSwitchesInAClosure(count): count
        case let .stoppedTakingOutMutants(builds): builds
        case let .mutantsLeftOutOfTheBuild(leftOut): leftOut
        case let .configurationKeysUnknown(keys, file): (keys, file)
        case let .configurationWorkedOut(generated, missing): (generated, missing)
        case let .changesSelected(selection): selection
        case let .logFoldersPruned(pruning): pruning
        case let .projectCopySkippedVanishedFiles(paths): paths
        case let .projectCopyFinished(destinationPath): destinationPath
        case let .codeOutsideTheProjectBuilt(paths): paths
        case let .projectCodeNamedByAbsolutePath(paths): paths
        case let .swiftLintPhasesTurnedOff(phases): phases
        case let .projectCoverageDiscoveryFinished(failure): failure
        case let .projectCoverageTestsFailed(failed): failed
        case let .packageSourceFilesUnavailable(reason): reason
        case let .buildConditionsUnavailable(reason): reason
        case let .filesToMutateUnmatched(entries): entries
        case let .sourceFileDiscoveryFinished(sourceFileCandidates): sourceFileCandidates
        case let .mutationsDiscoveryFinished(mappings): mappings
        case let .mutantsSelected(sample, shard, mappings): (sample, shard, mappings)
        case let .mutantsDropped(dropped): dropped
        case let .resumePlanned(summary): summary
        case let .workersChosen(choice): choice
        case let .stillTesting(still): still
        case let .stopAtFirstFailureTurnedOff(reason): reason
        case let .testBundlesNotRunDirectly(reason): reason
        case let .timedTestRunStopped(seconds, log): (seconds, log)
        case let .stoppedRunRecorded(path): path
        case let .controlRunFinished(control): control
        case let .activationNotShown(runs): runs
        case let .unprovenRunsRerunStarted(count): count
        case let .unprovenRunRerun(mutation, _): mutation
        case let .unprovenRunsRerunFinished(tally): tally
        case let .suspectKillRerunsSkipped(log): log as Any
        case let .suspectKillRerunsStarted(reruns): reruns
        case let .suspectKillRerun(mutation, _): mutation
        case let .suspectKillRerunsFinished(tally): tally
        case let .timeoutRerunsStarted(reruns): reruns
        case let .timeoutRerunFinished(rerun): rerun
        case let .timeoutRerunsFinished(tally): tally
        case let .propertyRerunsStarted(reruns): reruns
        case let .propertyRerunsFinished(tally): tally
        case let .propertyRerunsSkipped(reason, log): (reason, log)
        case let .propertySurvivorRerunsStarted(reruns): reruns
        case let .propertySurvivorRerunsFinished(tally): tally
        case let .propertySurvivorRerunsSkipped(reason, log): (reason, log)
        case let .exampleRerunsStarted(reruns): reruns
        case let .exampleRerunsFinished(tally): tally
        case let .exampleRerunsSkipped(reason, log): (reason, log)
        case let .runRepeatedAfterLaunchFailure(repeated): repeated
        case let .baselineRepeatedAfterLaunchFailure(line, log): (line, log)
        case let .oneMutantTested(run): run
        case let .mutationTestingFinished(outcome): outcome
        case let .mutationTestingEndedEarly(earlyEnd): earlyEnd
        case let .newMutationTestOutcomeAvailable(mutation): mutation
        case let .newTestLogAvailable(mutationTestLog): mutationTestLog
        case let .resultsFileCreated(path): path
        case let .resultsFileUnavailable(reason): reason
        case let .testPlanFileCreated(created): created

        case let .testPlanSourcesDiffer(changes), let .testPlanUntestedFilesChanged(changes),
             let .testPlanCopyResolutionChanged(changes): changes

        case let .testPlanChangesWaived(paths): paths
        case let .testPlanCopyEdited(paths): paths
        }
    }
}
