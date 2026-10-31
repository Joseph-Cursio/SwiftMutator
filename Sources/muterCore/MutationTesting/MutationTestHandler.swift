import Foundation

final class MutationTestHandler {
    @Dependency(\.events)
    private var events: RunEvents

    private lazy var observer: MutationTestObserver = .init(runOptions: options)

    let steps: [MutationStep]
    var state: AnyMutationTestState

    private let options: Run.Options

    init(
        options: Run.Options = .null,
        steps: [MutationStep] = .allSteps,
        state: MutationTestState = .init()
    ) {
        self.steps = steps
        self.state = state
        self.options = options
    }

    convenience init(
        options: Run.Options,
        steps: [MutationStep] = .allSteps
    ) {
        self.init(
            options: options,
            steps: steps.filtering(with: options),
            state: MutationTestState(from: options)
        )
    }

    func run() async throws {
        startObserver()
        notifyMuterLaunched()
        try await runMutationsSteps()
    }

    /// Starts the observer, which creates the run's log folder, and hands that folder to the steps.
    private func startObserver() {
        observer.start()
        state.apply([.loggingDirectoryCreated(observer.loggingDirectory)])
    }

    private func notifyMuterLaunched() {
        events.send(.muterLaunched)
    }

    private func runMutationsSteps() async throws {
        for step in steps {
            // A stopped run starts no further step. A step under way stops at its own checks, or when its processes
            // are killed.
            try Task.checkCancellation()
            let changes = try await step.run(with: state)
            state.apply(changes)
        }
    }
}

/// Each list is made afresh for each handler, so no two runs share a step.
private extension [MutationStep] {
    static var allSteps: [MutationStep] {
        [
            UpdateCheck(),
            LoadConfiguration(),
            // Before the last run's copy is removed, which a run still writing the results file is testing in.
            LoadResumeState(),
            CreateMutatedProjectDirectoryURL(),
            // Before the last run's copy and clones are removed, which another run of the project may still be testing in.
            LockMutatedProject(),
            PreviousRunCleanUp(),
            CopyProjectToTempDirectory(),
            FingerprintProjectTree(),
            DiscoverProjectCoverage(),
            DiscoverSourceFiles(),
            DiscoverMutationPoints(),
            CreateMuterTestPlan(),
            ApplySchemata(),
            CheckMutantSwitches(),
            BuildForTesting(),
            ProjectMappings(),
            PerformMutationTesting(),
        ]
    }

    static var testPlanSteps: [MutationStep] {
        [
            UpdateCheck(),
            LoadConfiguration(),
            LoadMuterTestPlan(),
            // Before anything in the mutated project the plan names is read, which another run may be rewriting.
            LockMutatedProject(),
            CheckTestPlanCode(),
            CheckMutantSwitches(),
            BuildForTesting(),
            ProjectMappings(),
            PerformMutationTesting(),
        ]
    }

    static var createTestPlanSteps: [MutationStep] {
        [
            UpdateCheck(),
            LoadConfiguration(),
            CreateMutatedProjectDirectoryURL(),
            LockMutatedProject(),
            PreviousRunCleanUp(),
            CopyProjectToTempDirectory(),
            DiscoverProjectCoverage(),
            DiscoverSourceFiles(),
            DiscoverMutationPoints(),
            ApplySchemata(),
            CheckMutantSwitches(),
            CreateMuterTestPlan(),
        ]
    }

    func filtering(with options: Run.Options) -> [MutationStep] {
        var copy: [any MutationStep] = self

        if options.isUsingTestPlan {
            copy = [MutationStep].testPlanSteps
        } else {
            copy.removeAll { $0 is ProjectMappings }
        }

        if options.createTestPlan {
            copy = [MutationStep].createTestPlanSteps
        } else {
            copy.removeAll { $0 is CreateMuterTestPlan }
        }

        if options.skipCoverage {
            copy.removeAll { $0 is DiscoverProjectCoverage }
        }

        if options.skipUpdateCheck {
            copy.removeAll { $0 is UpdateCheck }
        }

        if options.resumeURL == nil {
            copy.removeAll { $0 is LoadResumeState }
        }

        return copy
    }
}
