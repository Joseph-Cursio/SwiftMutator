@testable import muterCore
import XCTest

/// Each event's name and payload, for tests that pick sent events out by name. Both switches are exhaustive, so a new
/// event needs a name here.
extension RunEvent {
    enum Name {
        case muterLaunched
        case updateCheckStarted
        case updateCheckFinished
        case changesSelected
        case projectCopyStarted
        case projectCopySkippedVanishedFiles
        case projectCopyFinished
        case projectCoverageDiscoveryStarted
        case projectCoverageDiscoveryFinished
        case projectCoverageTestsFailed
        case sourceFileDiscoveryStarted
        case packageSourceFilesUnavailable
        case sourceFileDiscoveryFinished
        case mutationsDiscoveryStarted
        case mutationsDiscoveryFinished
        case resumePlanned
        case mutationTestingStarted
        case mutantRunsStarted
        case workersChosen
        case stopAtFirstFailureTurnedOff
        case testBundlesNotRunDirectly
        case mutationTestingFinished
        case mutationTestingEndedEarly
        case newMutationTestOutcomeAvailable
        case newTestLogAvailable
        case baselineTestFailed
        case resultsFileCreated
        case resultsFileUnavailable
        case testPlanFileCreated
        case muterMutationTestPlanLoaded
    }

    var name: Name {
        switch self {
        case .muterLaunched: .muterLaunched
        case .updateCheckStarted: .updateCheckStarted
        case .updateCheckFinished: .updateCheckFinished
        case .changesSelected: .changesSelected
        case .projectCopyStarted: .projectCopyStarted
        case .projectCopySkippedVanishedFiles: .projectCopySkippedVanishedFiles
        case .projectCopyFinished: .projectCopyFinished
        case .projectCoverageDiscoveryStarted: .projectCoverageDiscoveryStarted
        case .projectCoverageDiscoveryFinished: .projectCoverageDiscoveryFinished
        case .projectCoverageTestsFailed: .projectCoverageTestsFailed
        case .sourceFileDiscoveryStarted: .sourceFileDiscoveryStarted
        case .packageSourceFilesUnavailable: .packageSourceFilesUnavailable
        case .sourceFileDiscoveryFinished: .sourceFileDiscoveryFinished
        case .mutationsDiscoveryStarted: .mutationsDiscoveryStarted
        case .mutationsDiscoveryFinished: .mutationsDiscoveryFinished
        case .resumePlanned: .resumePlanned
        case .mutationTestingStarted: .mutationTestingStarted
        case .mutantRunsStarted: .mutantRunsStarted
        case .workersChosen: .workersChosen
        case .stopAtFirstFailureTurnedOff: .stopAtFirstFailureTurnedOff
        case .testBundlesNotRunDirectly: .testBundlesNotRunDirectly
        case .mutationTestingFinished: .mutationTestingFinished
        case .mutationTestingEndedEarly: .mutationTestingEndedEarly
        case .newMutationTestOutcomeAvailable: .newMutationTestOutcomeAvailable
        case .newTestLogAvailable: .newTestLogAvailable
        case .baselineTestFailed: .baselineTestFailed
        case .resultsFileCreated: .resultsFileCreated
        case .resultsFileUnavailable: .resultsFileUnavailable
        case .testPlanFileCreated: .testPlanFileCreated
        case .muterMutationTestPlanLoaded: .muterMutationTestPlanLoaded
        }
    }

    /// The event's payload, or nil if it has none.
    var object: Any? {
        switch self {
        case .muterLaunched, .updateCheckStarted, .projectCopyStarted, .projectCoverageDiscoveryStarted,
             .sourceFileDiscoveryStarted, .mutationsDiscoveryStarted, .mutationTestingStarted, .mutantRunsStarted,
             .muterMutationTestPlanLoaded:
            nil
        case let .updateCheckFinished(newVersion): newVersion
        case let .changesSelected(selection): selection
        case let .projectCopySkippedVanishedFiles(paths): paths
        case let .projectCopyFinished(destinationPath): destinationPath
        case let .projectCoverageDiscoveryFinished(failure): failure
        case let .projectCoverageTestsFailed(failed): failed
        case let .packageSourceFilesUnavailable(reason): reason
        case let .sourceFileDiscoveryFinished(sourceFileCandidates): sourceFileCandidates
        case let .mutationsDiscoveryFinished(mappings): mappings
        case let .resumePlanned(summary): summary
        case let .workersChosen(choice): choice
        case let .stopAtFirstFailureTurnedOff(reason): reason
        case let .testBundlesNotRunDirectly(reason): reason
        case let .mutationTestingFinished(outcome): outcome
        case let .mutationTestingEndedEarly(earlyEnd): earlyEnd
        case let .newMutationTestOutcomeAvailable(mutation): mutation
        case let .newTestLogAvailable(mutationTestLog): mutationTestLog
        case let .baselineTestFailed(mutationTestLog): mutationTestLog
        case let .resultsFileCreated(path): path
        case let .resultsFileUnavailable(reason): reason
        case let .testPlanFileCreated(path): path
        }
    }
}

extension RunEvents {
    /// Calls `handler` with each event named `name` sent from now on, until the returned subscription goes.
    func observe(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) -> Subscription {
        observe { event in
            if event.name == name { handler(event) }
        }
    }
}

extension MuterTestCase {
    /// An expectation fulfilled by the first event named `name` sent from now on that `handler`, if given, accepts.
    /// Events are handled as they are sent, so a test can wait for it with any timeout once the event's sender returns.
    func expectation(forEvent name: RunEvent.Name, handler: ((RunEvent) -> Bool)? = nil) -> XCTestExpectation {
        let expectation = expectation(description: "\(name) sent")
        expectation.assertForOverFulfill = false
        let subscription = runEvents.observe(name) { event in
            if handler?(event) ?? true { expectation.fulfill() }
        }
        addTeardownBlock { subscription.cancel() }
        return expectation
    }
}
