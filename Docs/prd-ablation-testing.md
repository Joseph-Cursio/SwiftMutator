# PRD: ablation testing

**Status: proposal, 21 November 2026. Nothing here is built. [#340](https://github.com/Joseph-Cursio/SwiftMutator/issues/340) tracks the work.** [ablation-testing.md](ablation-testing.md) explains what ablation testing is and when it's worth it.

`swift-mutator ablate --since <ref>` would take a branch's change, split it into parts, and test the project with each part taken back out, several times each. It would print an ablation table (part removed → tests that fail, flaky ones marked) and a Markdown snippet ready for the PR. `--revert-only` would run just the revert check, "the new tests fail without the source change", cheaply enough for CI.

- **It builds on what's there.** Git change selection from `run --since`, the copy and its lock, workers, failed-test parsing from logs, control-run ideas for flakiness, the results file and the reports all carry over. Operators and discovery don't. One-build switching would share its hard parts with [#309](https://github.com/Joseph-Cursio/SwiftMutator/issues/309), hand-written patches as mutants.
- **Build it in four steps** ([Milestones](#milestones)): the revert check first, with a build for each variant, then parts and the table, then one build for all variants, then telling "unneeded" from "untested".
- **Decide before starting:** whether it's a new command or a `run` flag, how parts are grouped by default, and what counts as a "new test" ([Open questions](#open-questions)).

## Problem

A bug fix usually comes with a test, and a reviewer has to take on trust that the test fails without the fix. When a fix has several parts, it's worse: the tests can pass with one part doing nothing, because the part isn't needed or because no test checks it. Concurrency fixes make both likelier, as a test of a race can pass by luck of timing.

Checking this by hand means reverting each part, building, running the tests several times, putting the source back, and writing the results up. For [apple/swift-async-algorithms#473](https://github.com/apple/swift-async-algorithms/issues/473), a three-part fix to a leak in `share()`, that was 15 tests × 3 runs × each version, done by hand ([the worked example](ablation-testing.md#worked-example-a-leak-in-share)). It's slow, it's easy to leave the source half reverted, and nobody does it on a PR they're reviewing.

Mutation testing doesn't answer this. `run --since --changed-lines` mutates the changed lines with SwiftMutator's operators, which says whether the tests notice `==` becoming `!=` there, not whether they notice the guard you added going missing.

## Goals

1. **The revert check, in one command:** the new tests pass with the change and fail without it, on every repeat.
2. **An ablation table for a fix with several parts:** for each part, the tests that fail when it's removed, which of them fail on every repeat, and which only on some. Each failure is also checked against the merge base, so a part that moved old behaviour, rather than adding new, is flagged.
3. **Never leave the user's source changed.** Every variant runs in SwiftMutator's copy; the project is checked unchanged at the end.
4. **Tell flaky tests apart,** by running each variant several times and running the unchanged fix as a control.
5. **Output ready for a PR:** a Markdown snippet, the table in the terminal, and a JSON report.
6. **A CI gate:** a non-zero exit when the new tests pass without the source change.
7. **Reuse SwiftMutator's runner and reports,** not a second tool in the same repository.

## Non-goals

- **A score.** An ablation has no score, and doesn't feed `--fail-under`, `--baseline`, `--max-score-drop` or `summary.json`'s `mutationScore`, as #309 proposes for patches.
- **Every combination of parts.** Removing each part alone, and all of them together, is the scope. Pairs are a later option ([Open questions](#open-questions)).
- **Finding the parts automatically by meaning.** Parts come from the diff's layout or from the user. SwiftMutator doesn't decide which lines form one idea.
- **Removing test code.** Parts are in source files. Test files are what's measured, not ablated.
- **Posting to GitHub.** It writes the snippet; a workflow or the author posts it.
- **Replacing mutation testing.** It answers a narrower question about one change.

## Users

- **A contributor fixing a bug with several parts,** especially in concurrent code: wants the table for the PR without reverting by hand. The #473 fix is the model case.
- **A maintainer reviewing PRs:** wants CI to say that a bug fix's tests fail without it, and wants a part nothing tests to stand out.
- **A SwiftMutator user** who already runs `run --since` in CI: same configuration file, same build settings, one more job.

## How a user marks the parts

A *part* is a set of the change's hunks, removed together. Removing a part puts those hunks' lines back as they are at the merge base, so a part that added a guard loses the guard, and a part that changed a line gets the old line back.

### From the diff's hunks (the default)

With no other say, each hunk of `git diff <merge-base>` in a source file is a part. "Source file" means what a run would mutate: the default and configured excludes leave out tests, manifests and what `exclude` names. This is the same selection `run --since` makes ([Mutating only what a branch changed](../README.md#mutating-only-what-a-branch-changed)).

Raw hunks are often too fine: one idea can touch three nearby lines that `-U0` splits into three hunks. Grouping the hunks in one function, accessor or closure into one part is likely the better default; see [Open questions](#open-questions).

### From a parts file or flags

To name parts, or group hunks across places, list ranges on the new side of the diff (the line numbers here are made up):

```yaml
# ablation.yml
parts:
  - name: unregisterSide wakes the loop
    ranges: [Sources/AsyncAlgorithms/AsyncShareSequence.swift:212-230]
  - name: cancel() wakes the loop with a full buffer
    ranges: [Sources/AsyncAlgorithms/AsyncShareSequence.swift:301-309]
  - name: iterate() doesn't park once cancelled
    ranges: [Sources/AsyncAlgorithms/AsyncShareSequence.swift:355-358, Sources/AsyncAlgorithms/AsyncShareSequence.swift:371]
```

or, for one run, `--part 'cancel() wakes the loop=AsyncShareSequence.swift:301-309'`, repeatable. A hunk belongs to every part whose ranges it overlaps; a hunk in two parts is refused, as removing one part would take half of the other with it. A hunk in no listed part stays its own part, named by its place. Paths are matched as `--mutant` matches them, by as much of the path as tells the file apart.

Ranges go stale when the branch changes, so the file suits a fix that's nearly done. A range that no longer overlaps any hunk is an error that names it.

### From annotations (later)

A comment directive in the style of `muter:disable`, such as `// muter:part <name>` … `// muter:end-part`, would survive rebases. But it puts tool comments in the fix itself, which reviewers then read and the project keeps. It's in [milestone 4](#milestones) at the earliest, and only if the parts file proves too brittle.

## How runs work

### The variants

| Variant | What's in the source | What it tells you |
|---|---|---|
| **The change** | The branch as it is | The control: every test should pass on every repeat |
| **Everything removed** | The merge base's source, the branch's tests | The revert check |
| **Part *k* removed** | The branch with part *k*'s hunks back as they were | Whether part *k* is needed and tested |

Each part's failures are compared with both controls: with the change, where every test should pass, and with everything removed. A test that fails without part *k* but passes at the merge base means part *k* moved behaviour the old code had, so "the change minus part *k*" is worse than the old code ([moves old behaviour](#the-ablation-table)).

`--revert-only` runs the first two. A run with *p* parts runs *p* + 2 variants.

### Repeats and order

- **Each variant runs N times,** `--repeats N`, `ablationRepeats` in `muter.conf.yml`, 3 by default. A test fails a variant when it fails all N runs, and is *flaky* there when it fails some but not all.
- **The change is run N times too.** A test that fails in any of its runs is flaky whatever the variants show, as a test that fails in a [control run](../README.md#control-runs) is now, and isn't counted as detecting a part. If the branch's tests fail on every run of the change, nothing is ablated, and the run exits with 3, as a failed baseline does now.
- **Runs are interleaved,** variant by variant within each round, so a change in load across the run doesn't line up with one variant.
- **No stop at the first failed test.** Every run goes to its end, as `--mutant` runs do, so the table can name every test that fails.
- **Timeouts are their own outcome,** *hung*. For a leak or deadlock fix, a test that hangs when a part is removed is the signal. The time limit is the default one SwiftMutator times now; a hang counts as a failure of every test the log doesn't show passing, and the table marks it.
- **Workers** test variants in parallel, as they test mutants. Timing-sensitive tests can behave differently under load, so `--workers 1` stays available and the report says how many workers ran.

### Building the variants

- **Milestones 1 and 2: one build per variant.** Each variant is made in an APFS clone of the copy, the way workers' clones are made now, with its hunks reverse-applied as text, then built and tested. Simple, and right for any hunk, including a new stored property or a changed signature.
- **Milestone 3: one build for all variants.** Each part's hunks become branches of a switch on the part's ID, around the smallest statement list that holds them, the way mutants are switched now. This is the core of #309 ("each hunk becomes a branch of a switch"), so the two should share it. Two things are new: a variant can switch on several parts at once (everything removed), so the active-mutant file has to hold a set of IDs; and a part with nowhere for a switch falls back to its own build, as #309 also proposes.
- **A part whose removal doesn't compile** is a finding, not a crash. It usually means another part depends on it, such as a helper function and its call. The table says "doesn't build without part *j*" where the compiler errors point there, and suggests merging the two.

### Keeping the source safe

- **The project is never edited.** All variants run in `<project>_ablation.noindex` and its clones, beside `<project>_mutated.noindex` and `<project>_mutant.noindex`. The README's advice to ignore `*_mutated*` and `*_mutant*` gains `*_ablation*`.
- **Each variant starts from the copy as made.** A clone is removed after its variant. Before each variant, the files it reverts are checked against the copy's SHA-256s, which `FingerprintProjectTree` records now.
- **At the end, the project is checked unchanged:** its fingerprints, and the same `git status`. A difference is an error, though no step of an ablation should be able to cause one.
- **A stopped run** (Ctrl-C) removes its clones as a stopped mutation run does. Resume is out of scope until milestone 3.

## Output

### The ablation table

Printed at the end, and in every report:

```
🧪 Ablation of 3 parts since origin/main (merge base 3f9c2e1), 3 runs each, 4 workers
| Part removed                                    | Tests that fail (3 of 3) | Pass at the merge base | Flaky | Hung | Verdict                  |
|-------------------------------------------------|--------------------------|------------------------|-------|------|--------------------------|
| None (the change)                               | 0                        | –                      | 0     | 0    | control                  |
| All (the merge base's source)                   | 10                       | –                      | 0     | 0    | revert check passes      |
| 1: unregisterSide wakes the loop                | 4                        | 0                      | 0     | 0    | needed, tested           |
| 2: cancel() wakes the loop with a full buffer   | 1                        | 0                      | 0     | 0    | needed, tested by 1 test |
| 3: iterate() doesn't park once cancelled        | 6                        | 1                      | 0     | 0    | needed, tested; moves old behaviour |
```

The verdicts:

- **needed, tested:** at least one test fails on every run, and passes on every run of the change. "tested by 1 test" is called out, as a part that rests on one test is easy to lose.
- **flaky only:** some tests fail on some runs, none on all of them. It's evidence, not proof: more repeats may settle it.
- **not detected:** nothing fails. The part is unneeded or untested, and the run can't tell which ([ablation-testing.md](ablation-testing.md#one-run-two-questions)). From milestone 4 the verdict adds whether the part's code ran ([Whether a mutant's code ran](../README.md#whether-a-mutants-code-ran)): code that never ran is untested; code that ran without any failure may be unneeded, or weakly checked.
- **doesn't build:** see above.
- **moves old behaviour:** added to another verdict when a test that fails with the part removed passes at the merge base. The part took something the old code already did along with what it adds, so its row overstates what it adds ([the moved-behaviour pitfall](ablation-testing.md#what-it-costs)). The "everything removed" variant runs anyway, so this costs nothing. The report names the tests and suggests cutting the part so that the old behaviour stays when it's removed. In #473, removing part 3 failed case 11, which passes on `main`: `main` checked for cancellation in `iterate()`'s limit path, and the fix moved that check into its new early check.

`--verbose` lists, for each variant, every test that failed and in how many runs. Tests in files the branch changed are marked, as those are usually the new tests.

### Reports

- **Markdown,** `-f markdown` or `--report markdown:<path>`: the table, the tests behind each row, and one line on how it ran (repeats, workers, toolchain), short enough for a PR description or `$GITHUB_STEP_SUMMARY`. It's the snippet [ablation-testing.md](ablation-testing.md#worked-example-a-leak-in-share) shows.
- **JSON,** `-f json`: every variant, every run, every test's outcome.
- **Plain,** the default, as above.
- HTML, Stryker, SARIF and Xcode formats aren't produced: they describe mutants.

### The results file

An ablation writes a results file as a run does ([Docs/results-file.md](results-file.md)): a header that records the merge base, the parts and their hunks, the repeats and the configuration, then one `variantRun` line per run of a variant, with its outcome and the tests that failed, then `end`. `swift-mutator report` makes any of the reports above from it, so a CI job can save the file and render the snippet later.

## CI integration

The revert check is the gate, as it's cheap: two variants, N runs each, two builds until milestone 3.

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0   # the merge base has to be there, as for run --since
- run: |
    swift-mutator ablate --since "origin/${{ github.base_ref }}" --revert-only \
      --require-revert-fails --report markdown:"$GITHUB_STEP_SUMMARY"
```

- **`--require-revert-fails`** exits with 2 when no test in a test file the branch changed fails on every run of "everything removed". The message names the tests that passed. 2 is what every failed check exits with now.
- **`--fail-on-undetected`** exits with 2 when some part's verdict is "not detected". It's for a full ablation, not the gate: a refactor or a defensive guard can be undetected on purpose.
- **Nothing to check exits with 0:** a branch with no change to a source file, as `run --since` does for a change to docs or tests. A branch that changes source but no test file is said, and with `--require-revert-fails` exits with 2: a fix with no test can't pass a revert check. A project's workflow can skip the job for a label such as `refactor`.
- **Time:** the gate costs two builds and 2 × N test runs on top of the job's own build. Milestone 1 measures it.

## Reuse of what SwiftMutator has

The command is another step list for `MutationTestHandler`, like `run`, `mutate-without-running` and `run-without-mutating` ([Architecture.md](Architecture.md#the-steps)). Most steps exist.

<details>
<summary>What carries over, what changes, and what's new</summary>

| Part of SwiftMutator | Where | In an ablation |
|---|---|---|
| Merge base, changed files and hunks | `ChangeSelection/GitChanges.swift`, `GitDiffParsing.swift` | Reused. `hunks(of:since:)` runs `git diff -U0` and keeps only the new side's line ranges; parts need each hunk's old-side lines too, so the parsing grows to keep them. |
| Excludes, to tell source from tests | `SourceFileExcludes.swift`, `ExcludeGlob.swift` | Reused as is. |
| Configuration, `muter.conf.yml` and flags | `LoadConfiguration`, `Configuration/` | Reused, with `ablationRepeats` and a flag for it, as every key has one now. |
| Copy, lock, clean-up | `CreateMutatedProjectDirectoryURL`, `LockMutatedProject`, `PreviousRunCleanUp`, `CopyProjectToTempDirectory` | Reused with a third name, `<project>_ablation`, and its own lock, as `--mutant` has. |
| Fingerprints | `FingerprintProjectTree` | Reused to check each variant's starting point and the project at the end. |
| Workers' APFS clones | Workers and release mode | Reused for one build per variant. |
| SwiftLint phases off, build for testing | `TurnOffSwiftLintPhases`, `BuildForTesting` | Reused for xcodebuild projects. |
| Test runs: direct bundles, `swift test`, xcodebuild | `MutationTesting/`, `BuildSystems/` | Reused, with no stop at the first failure, as `OneMutantRun` does. |
| Failed tests from logs, crashes, traps | `KillingTestSummary*`, `CrashLine.swift`, `TrapLine.swift` | Reused to fill the table. |
| Default timeout | Timed after the baseline | Reused; a timeout is *hung*, not a survivor. |
| Control runs and the flaky rule | `PerformMutationTesting+ControlRuns.swift`, `SuspectKillReruns.swift` | The idea carries over: the change's N runs are the control. |
| Schemata, switch check, compile recovery | `MutationSchemata/`, `ApplySchemata`, `CheckMutantSwitches`, compile recovery | Milestone 3, shared with #309. Needs a key kind for a part (#309 names the same need for a patch: `MutantKey` is a path, line, column and operator) and several active IDs at once. |
| Whether a mutant's code ran | `ActivationMarker.swift` | Milestone 4, to tell untested parts from unneeded ones. |
| Results file and `report` | `Results/`, `ReportWriter.swift` | Reused, with new line kinds. |
| Markdown, JSON and plain reports, `--report` | `TestReporting/Markdown`, `Json`, `PlainText` | New report bodies; the saving, paths and `--report` handling are reused. |
| Exit statuses | README, Exit status | Reused: 0, 2 for a failed check, 3 for a failed control, 6 for a held lock, 64, 255. |
| Operators, discovery, coverage step, sampling, shards, baselines | | Not used. |

</details>

## Open questions

1. **A command or a flag?** `swift-mutator ablate` keeps `run`'s flags and exit status about mutants; `run --ablate` would share more parsing. A separate command looks clearer, as `triage` and `report` are.
2. **The default parts:** raw `-U0` hunks, or hunks grouped by their enclosing function, accessor or closure? Grouping matches how people describe a fix; raw hunks are simpler to explain.
3. **What's a "new test"** for `--require-revert-fails`? Tests in test files the branch changed is easy to compute but counts an edited old test as new. Tests whose names aren't at the merge base is stricter, and needs the test list of both sides.
4. **The default number of repeats.** 3 matches the hand-made #473 runs; a test that fails 10% of the time by chance fails all 3 runs 0.1% of the time. 5 is safer for concurrency tests and costs two-thirds more.
5. **Which tests run:** the whole suite, as for mutants, or only the tests in changed test files, which is much faster? A `--tests <filter>` flag either way.
6. **Pairs.** `--pairs` would remove each pair of parts, *p*(*p*−1)/2 variants, to find parts that cover for each other. In #473 there was no gap: the three parts, removed one at a time, failed every one of the 10 tests that fail at the merge base, and no test failed for two parts. A gap, merge-base failures that no single removal reproduces, is the sign pairs are needed, and the table can say so. Worth building only if milestone 2's tables often show one.
7. **Overlap with #309.** Should a part be a generated patch, run through the same `--patches` path with the expected outcome "killed", or should both share a lower layer only? Sharing the key kind, the hunk switching and the fallback build is the minimum.
8. **Platforms.** SwiftPM on macOS and Linux first; xcodebuild in milestone 2 or later?

## Milestones

Each one ends with a measured doc, as [since-2026-11.md](since-2026-11.md) and [reuse-2026-10.md](reuse-2026-10.md) do.

1. **The revert check.** `ablate --since <ref> --revert-only`: the change and everything removed, a build for each, N repeats, the table for those two rows, `--require-revert-fails`, the Markdown and plain reports, and the CI example in the README. Done when it reproduces the hand-made #473 result, 10 of the 15 leak tests failing on every run with the merge base's source, and an acceptance test shows the project unchanged afterwards.
2. **Parts and the table.** Parts from hunks, the parts file and `--part`; one build per variant on workers; the verdicts; the results file's lines and `report`; JSON. Done when it reproduces the #473 rows, the same on every run: part 1 removed fails cases 1–4, part 2 removed fails case 5 alone, and part 3 removed fails cases 6–10 and case 11, marked as passing at the merge base.
3. **One build.** Parts switched in one build, shared with #309; the fallback to a build of its own; several active IDs; resume. Done when it measures the build time saved against milestone 2 on the same branch, with every verdict the same.
4. **Unneeded or untested.** Activation markers for each part, so "not detected" says whether the code ran; annotations if the parts file proved brittle; `--pairs` if milestone 2 showed the need.
