# How SwiftMutator works

This page is for contributors. It follows a run from the command line to the report, and says
where each part is. The paths are under [`Sources/muterCore`](../Sources/muterCore) unless they
say otherwise. For how to use SwiftMutator, see the [README](../README.md).

## Targets

- `muter` ([`Sources/muter/main.swift`](../Sources/muter/main.swift)): the `swift-mutator`
  executable. It only calls `Muter.start()`.
- `muterCore`: everything else.
- `TestingExtensions` ([`Tests/Extensions`](../Tests/Extensions)): helpers the test targets share.
- `muterTests` ([`Tests`](../Tests)): the unit tests. `muterAcceptanceTests`
  ([`AcceptanceTests`](../AcceptanceTests)) and `muterRegressionTests`
  ([`RegressionTests`](../RegressionTests)) check the output their scripts save (see
  [CONTRIBUTING.md](../CONTRIBUTING.md#acceptance-and-regression-tests)).

## Commands

[`CLICommands/Muter.swift`](../Sources/muterCore/CLICommands/Muter.swift) lists the
subcommands: `init`, `run` (the default), `run-without-mutating`, `mutate-without-running`,
`report`, `triage`, `operator` and `watch-test-processes`. The three that mutate or test are in
[`CLICommands/RunCommand`](../Sources/muterCore/CLICommands/RunCommand). Each makes a
[`MutationTestHandler`](../Sources/muterCore/MutationTesting/MutationTestHandler.swift), which runs
a list of steps.

## The steps

A step is a [`MutationStep`](../Sources/muterCore/MutationSteps/MutationStep.swift): it reads the
run's state and returns changes to it. The handler checks for a stop before each step, then
applies the changes the step returns. The steps are in
[`MutationSteps`](../Sources/muterCore/MutationSteps). `run` runs these, in order:

1. `UpdateCheck`: asks GitHub whether SwiftMutator has a newer release. `--skip-update-check` drops it.
2. `LoadConfiguration`: reads `muter.conf.yml`, and finds its `executable` on the `PATH`.
3. `SelectChangedCode`: with `--since`, asks git which files and lines the branch changed
   ([`ChangeSelection`](../Sources/muterCore/ChangeSelection)).
4. `LoadResumeState`: with `--resume` or `--reuse`, reads the earlier results file, and refuses a
   run that wouldn't reproduce its results.
5. `CreateMutatedProjectDirectoryURL` (in `CreateTempDirectoryURL.swift`): names the copy.
6. `LockMutatedProject`: locks the copy's `.lock` file, `<project>_mutated.lock`, so a copy has one
   run at a time. A `--mutant` run has its own copy and lock, `<project>_mutant.lock`.
7. `PreviousRunCleanUp`: removes the last run's copy, clones and leftovers.
8. `CopyProjectToTempDirectory`: copies the project.
9. `FingerprintProjectTree`: records the SHA-256 of each of the project's files, so a later
   resume or reuse can tell what changed.
10. `ListChangedSources`: with `--since`, lists the changed files before the coverage run.
11. `DiscoverProjectCoverage`: runs the tests once with coverage, to find code no test reaches
    ([`DiscoverProjectCoverage/`](../Sources/muterCore/MutationSteps/DiscoverProjectCoverage),
    [`BuildSystems`](../Sources/muterCore/BuildSystems)). `--skip-coverage` drops it.
12. `DiscoverSourceFiles`: picks the Swift files to mutate, minus `exclude`
    (`SourceFileExcludes.swift`, `ExcludeGlob.swift`).
13. `DiscoverMutationPoints`: parses each file and runs every operator's visitor over it. Each mutant goes in a
    `MutationSwitchPlace`, usually its statement list. A file's top level can't hold a switch when it has a
    declaration, so there the place is the initial value or the statement, and a mutant with neither is a
    `DroppedMutant`, which the run counts and `--verbose` lists.
14. `SelectMutant`: with `--mutant`, keeps only that mutant.
15. `PruneLogFolders`: removes old runs' log folders beyond `keepLogFolders`.
16. `ApplySchemata`: rewrites each file with mutants in the copy (see below).
17. `CheckMutantSwitches`: reads the files back, and stops the run if a mutant's switch is missing.
18. `BuildForTesting`: xcodebuild only. Runs `build-for-testing`, without any mutant that doesn't
    compile (`CompileRecovery`, see below), copies the products to `TestContents` in the copy, and
    reads the `.xctestrun` file.
19. `PerformMutationTesting`: tests the mutants (see below).

`mutate-without-running` runs steps 1, 2, 5 to 9 and 11 to 13, then `PruneLogFolders`, `ApplySchemata`,
`CheckMutantSwitches` and `CreateMuterTestPlan`, which writes the test plan,
`muter-mappings.json`. `run-without-mutating` reads that plan (`LoadMuterTestPlan`), checks the
project and the copy against it (`CheckTestPlanSources`, `CheckTestPlanCode`), then runs
`PruneLogFolders` and `BuildForTesting` as `run` does, then `ProjectMappings`, which only reports the
plan's mutants, then `PerformMutationTesting`. The full lists, and which options drop which step,
are in `MutationTestHandler.swift`.

## Operators

[`MutationOperators`](../Sources/muterCore/MutationOperators) holds the eight operators:
`RelationalOperatorReplacement` (`ROROperator.swift`), `RelationalBoundary`, `RemoveSideEffects`,
`ChangeLogicalConnector`, `SwapTernary`, `NegateConditional`, `ChangeArithmeticOperator` and
`FlipBooleanLiteral`. Each is a SwiftSyntax visitor, built on
[`Visitors/MuterVisitor.swift`](../Sources/muterCore/Visitors/MuterVisitor.swift), which also
skips code between `// muter:disable` and `// muter:enable`. Each mutant becomes a
`MutationSchema`: its operator, its position, its ID and the code it puts in place, grouped by file
and code block in a `SchemataMutationMapping`
([`MutationSchemata`](../Sources/muterCore/MutationSchemata)). [mutation_operators.md](mutation_operators.md)
describes what each one changes.

## How a mutant is switched on

SwiftMutator uses mutation schemata: every mutant goes into the copy at once, each behind a
switch, and the copy is built once.

- [`Rewriters/MutationSwitch.swift`](../Sources/muterCore/Rewriters/MutationSwitch.swift) wraps a
  code block that has mutants in an `if` chain. Each branch is one mutant's version of the block,
  taken when the mutant's ID is set. The last branch is the original code.
- A mutant's ID is its file's name, a hash of its path, the operator, and its line, column and
  offset, as in `Walker_123ded629f2c52a7_ChangeLogicalConnector_40_17_1502`
  ([`MutationSchemata/MutationSchema.swift`](../Sources/muterCore/MutationSchemata/MutationSchema.swift)).
- [`Rewriters/MuterRewriter.swift`](../Sources/muterCore/Rewriters/MuterRewriter.swift) appends
  an enum to each rewritten file, `__SwiftMutator_` and a hash of the file's name. Its
  `static let environment` reads the process environment once. If
  `SWIFTMUTATOR_ACTIVE_MUTANT_FILE` is set, it also switches on the ID on the first line of the
  file that variable names, and reads the run's activation marker from its second. `static let ran`
  creates that marker the first time a switch's condition holds, as each mutant's `if` reads it after
  its own check, and reading `environment` creates `<marker>.reached`
  ([`MutationTesting/ActivationMarker.swift`](../Sources/muterCore/MutationTesting/ActivationMarker.swift)).
- [`MutationTesting/MutationTestingIODelegate.swift`](../Sources/muterCore/MutationTesting/MutationTestingIODelegate.swift)
  switches a mutant on for a test run. For SwiftPM it writes the ID to the worker's
  `<project>_mutated.active-mutant` file, beside its folder, and names that file in the
  variable: SwiftPM keys its manifest cache on the whole environment, so a variable per mutant
  would recompile every manifest. For xcodebuild it sets `<ID>=YES`, and
  `SIMCTL_CHILD_<ID>=YES` for a simulator, and writes the ID into the worker's `.xctestrun` file
  ([`BuildSystems/Xcode/XCTestRun.swift`](../Sources/muterCore/BuildSystems/Xcode/XCTestRun.swift)).

So no mutant needs a build of its own. A SwiftPM mutant runs `swift test --skip-build`, or, on
macOS with Swift Testing, its test bundles directly
([`BuildSystems/Swift/DirectTestRun.swift`](../Sources/muterCore/BuildSystems/Swift/DirectTestRun.swift)).
An xcodebuild mutant runs `test-without-building` on the `.xctestrun` file.

## The copy and the workers

[`MutationTesting/MutatedProjectNames.swift`](../Sources/muterCore/MutationTesting/MutatedProjectNames.swift)
names everything SwiftMutator makes beside the project: the copy, `<project>_mutated.noindex`
(`<project>_mutant.noindex` for `--mutant`), each extra worker's clone,
`<project>_mutated_worker<n>.noindex`, xcodebuild's derived data folders and the activation
markers' folders. `.noindex` keeps
Spotlight out. The lock is in
[`MutatedProjectLock.swift`](../Sources/muterCore/MutationTesting/MutatedProjectLock.swift).

`PerformMutationTesting` runs the baseline, the tests with no mutant on, which also makes the one
build. A build every mutant shares can fail on one of them, so [`CompileRecovery.swift`](../Sources/muterCore/MutationSteps/CompileRecovery.swift)
takes the mutants a failed build's errors are in out of the code, from the prepared text
`ApplySchemata` keeps, and it builds again. They stay in `mutationMapping`, as their keys, and the
counts a resume and a shard merge check, depend on every mutant being there, and each gets a result
line. Under xcodebuild `BuildForTesting` does this instead. Unless `mutationTestTimeout` is set, a timed test run then sets the time limit ([`MutantTimeLimits.swift`](../Sources/muterCore/MutationSteps/MutantTimeLimits.swift),
[`TimedTestRun.swift`](../Sources/muterCore/MutationSteps/TimedTestRun.swift)). Then
[`WorkerPool.swift`](../Sources/muterCore/MutationSteps/WorkerPool.swift) tests the mutants,
`mutationTestWorkers` at a time:

- SwiftPM: worker 0 tests in the copy. Each other worker tests in a clone of it, built once
  ([`WorkerClones.swift`](../Sources/muterCore/MutationSteps/WorkerClones.swift)).
- xcodebuild: every worker tests the one build, each on a simulator of its own
  ([`SimulatorWorkerSetup.swift`](../Sources/muterCore/MutationSteps/SimulatorWorkerSetup.swift),
  [`BuildSystems/Xcode/WorkerSimulators.swift`](../Sources/muterCore/BuildSystems/Xcode/WorkerSimulators.swift)).
  This needs a test command whose first `-destination` is a simulator. A run that can't give each
  worker a simulator tests one mutant at a time.
- Any other project, such as an xcodebuild project that tests on a Mac or an unknown build system,
  tests one mutant at a time. `parallelWorkersUnsupportedReason` in
  [`Configuration/MuterConfiguration.swift`](../Sources/muterCore/Configuration/MuterConfiguration.swift)
  gives the reason the run prints.

Among the mutants it runs control runs, with no mutant on, to find flaky tests
([`ControlRuns.swift`](../Sources/muterCore/MutationSteps/ControlRuns.swift)). With several
workers it runs the timeouts again at lower load at the end
([`MutationTesting/TimeoutReruns.swift`](../Sources/muterCore/MutationTesting/TimeoutReruns.swift)).
It tests again, alone, the kills only suspect tests failed for
([`MutationSteps/SuspectKillReruns.swift`](../Sources/muterCore/MutationSteps/SuspectKillReruns.swift)).
With `propertyTestFilter`, it then tests again, with only the property tests, each kill whose
recorded tests include none
([`MutationSteps/PropertyReruns.swift`](../Sources/muterCore/MutationSteps/PropertyReruns.swift)).

## The results file

Each result is written as it finishes, as a line of JSON in `results.jsonl` in the run's log
folder, `<project>_muter_logs/<run>/`
([`Results/ResultsFile.swift`](../Sources/muterCore/Results/ResultsFile.swift)). Its lines are of
six kinds: `header`, `retired`, `mutant`, `control`, `propertyRerun` and `end`
([`Results/ResultsRecords.swift`](../Sources/muterCore/Results/ResultsRecords.swift),
[`Results/ControlRunResult.swift`](../Sources/muterCore/Results/ControlRunResult.swift) for
`control`, and
[`Results/PropertyRerunResult.swift`](../Sources/muterCore/Results/PropertyRerunResult.swift) for
`propertyRerun`).
[results-file.md](results-file.md) documents the format. `--resume` and `--reuse` read it back
(`RecordedResults*.swift`, `ResumeCheck.swift`, `ResumePlan.swift`, `ReuseChanges.swift` in
[`Results`](../Sources/muterCore/Results)). `Provenance.swift` records the SwiftMutator build and
the toolchain that tested. A run that ends after its baseline passed also writes `summary.json`
beside it ([`TestReporting/RunSummary.swift`](../Sources/muterCore/TestReporting/RunSummary.swift)).
[test-plan.md](test-plan.md) documents the test plan.

## Reports

[`TestReporting`](../Sources/muterCore/TestReporting) turns the outcomes into a report:
`mutationScoring.swift` scores them, `ReportFormat.swift` picks the format, and
`PlainText/`, `Json/`, `HTML/` and `Xcode/` hold one reporter each.
[`TestReporting/ReportWriter.swift`](../Sources/muterCore/TestReporting/ReportWriter.swift) saves
every report. In a run, `MutationTestObserver` saves the report at the end, or a partial one when
the run stops early, and writes `summary.json`. `swift-mutator report`
([`CLICommands/Report.swift`](../Sources/muterCore/CLICommands/Report.swift)) makes a report from a
results file, with
[`Results/ResultsReport.swift`](../Sources/muterCore/Results/ResultsReport.swift). While a run goes, steps send [`RunEvents`](../Sources/muterCore/MutationTesting/RunEvents.swift),
which [`MutationTestObserver`](../Sources/muterCore/MutationTesting/MutationTestObserver.swift)
prints through `Logger.swift`.

## Other folders

- [`Configuration`](../Sources/muterCore/Configuration): `muter.conf.yml`, and what `init` writes.
- [`DependencyInjection`](../Sources/muterCore/DependencyInjection): `World.swift` holds every
  dependency a step reads with `@Dependency`, so tests can replace the file system, processes and
  clock.
- [`Shell`](../Sources/muterCore/Shell): starting, watching and stopping test processes.
- [`Interruptions`](../Sources/muterCore/Interruptions): stopping on Ctrl-C, SIGTERM and SIGHUP, and keeping
  the Mac awake while a run goes on.
- [`Sampling`](../Sources/muterCore/Sampling) and [`Sharding`](../Sources/muterCore/Sharding):
  `--sample`, and `--shard` with merging shards' results.
- [`CLICommands/ExitStatus.swift`](../Sources/muterCore/CLICommands/ExitStatus.swift): the exit
  statuses.
