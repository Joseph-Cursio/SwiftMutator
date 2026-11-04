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

    /// Runs the steps, and gives the finished run's verdict on its score against its `failUnder` (`ScoreGate`): nil
    /// without one. A run that doesn't finish throws, or, stopped by a signal, ends with no verdict.
    @discardableResult
    func run() async throws -> ScoreGate? {
        try startObserver()
        // However the run ends, whether refused, failed, stopped or finished, it removes a log folder it kept nothing
        // in. Every step has returned by then, and events are handled as they are sent, so nothing is still writing
        // there.
        defer { observer.removeLoggingDirectoryIfEmpty() }
        notifyMuterLaunched()
        try await runMutationsSteps()
        return observer.scoreGate
    }

    /// Starts the observer, which creates the run's log folder, and hands that folder to the steps. `run()` removes
    /// the folder at the end if the run kept nothing there. If starting fails, no folder was claimed, and there is
    /// none to remove.
    private func startObserver() throws {
        try observer.start()
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
            // Before a resume is checked, which compares what it chose, and before anything is copied.
            SelectChangedCode(),
            // Before the last run's copy is removed, which a run still writing the results file is testing in.
            LoadResumeState(),
            CreateMutatedProjectDirectoryURL(),
            // Before the last run's copy and clones are removed, which another run of the project may still be testing
            // in.
            LockMutatedProject(),
            PreviousRunCleanUp(),
            CopyProjectToTempDirectory(),
            FingerprintProjectTree(),
            // Before the coverage run, which runs the whole test suite.
            ListChangedSources(),
            DiscoverProjectCoverage(),
            DiscoverSourceFiles(),
            DiscoverMutationPoints(),
            // Before the copy is rewritten, so it gets only that mutant's switch, and builds as quickly as it can.
            SelectMutant(),
            // Once nothing can refuse the run, or find nothing to test: the last step that can is just before. Before
            // the build and every mutant's run, which write most of its logs.
            PruneLogFolders(),
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
            // It finds the project folder the plan is read under. A folder without a configuration stops here, as an
            // error, so `CheckTestPlanSources` refuses another folder only when it has one.
            LoadConfiguration(),
            LoadMuterTestPlan(),
            // It reads only the plan. Before the checks, so they look only at that mutant's file.
            SelectMutant(),
            // Before the copy is locked: it reads only the project, and a refusal leaves another run's copy alone.
            CheckTestPlanSources(),
            // Before the copy is locked, as for any run, so that a results file another session still writes is
            // refused for that alone. It compares the plan, and `FingerprintProjectTree` the copy.
            LoadResumeState(),
            // Before anything in the mutated project the plan names is read, which another run may be rewriting.
            LockMutatedProject(),
            CheckTestPlanCode(),
            CheckMutantSwitches(),
            // The copy as it is tested, rewritten and perhaps fixed by hand, which the results file records.
            FingerprintProjectTree(),
            // Once nothing can refuse the run: the plan's code and its copy are checked, and a resume's copy compared.
            PruneLogFolders(),
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
            // Before anything is rewritten: the plan records the project's files as they are, for its runs to check.
            FingerprintProjectTree(),
            DiscoverProjectCoverage(),
            DiscoverSourceFiles(),
            DiscoverMutationPoints(),
            // Once the run can't find nothing to mutate.
            PruneLogFolders(),
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

        if options.continuedFrom == nil {
            copy.removeAll { $0 is LoadResumeState }
        }

        if options.since == nil {
            copy.removeAll { $0 is SelectChangedCode || $0 is ListChangedSources }
        }

        if options.mutant == nil {
            copy.removeAll { $0 is SelectMutant }
        } else {
            // A short probe, the run most likely to go alongside another, never prunes their log folders.
            copy.removeAll { $0 is PruneLogFolders }
        }

        return copy
    }
}
