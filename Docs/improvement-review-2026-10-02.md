# SwiftMutator improvement review: 2 October 2026

This is a ranked list of improvements to SwiftMutator, made at commit `4ba72fc` after PR #13 (the cached-environment speedup) landed.

- **How it was produced.** Thirteen agents read the code and the run logs without modifying anything. Six of them each examined one area. Six more each tried to disprove another agent's suggestions against the code. A final agent looked for anything all of them had missed.
- **How the suggestions held up.** There were 61 suggestions. Verification rejected none of the 54 from the six areas. About half of those needed a corrected estimate, and the corrected numbers are used below. The final agent's seven suggestions weren't separately checked.
- **Status.** Nothing has been implemented yet.

## The workload these numbers come from

The test project is SwiftProjectLint, run on the whole repo: 528 files, **2,497 mutants** in 302 files, 4 workers. Its Swift Testing suite has three test bundles with 3,622, 107 and 203 tests, and takes about 8 s on its own.

| | Before PR #13 (stopped at 44%) | After PR #13 (run in progress) |
|---|---|---|
| Time per mutant per worker | ~141 s | **~24 s**, made up of ~15.8 s of tests and ~9 s before any test starts |
| Throughput | ~1.65 mutants/min | ~10 mutants/min |
| Whole run | ~25 h (projected) | **~4.2 h** |

- **The machine.** It has 4 performance cores and 4 efficiency cores (not 8 full cores) and 24 GB of RAM. With 4 workers the CPU is fully busy, with a load of 32–40.
- **The workers run in step.** All four workers start and finish each round of mutants within the same second. So the time per mutant measures how hard the workers are competing for the CPU, more than the cost of any one mutant.

---

## 1. Speed

| # | Change | Effect on this run | Effort |
|---|---|---|---|
| 1 | Stop recompiling `Package.swift` for every mutant | About −1.2 h (cause not yet proven) | M |
| 2 | Stop each mutant's test run at the first failure | About 1.65×; with #1, **4.2 h → 1.4 h** | M |
| 3 | Skip mutants that no test reaches (about 6%) | About −16 min | M |
| 4 | Do less work per run: reuse unchanged results, `--since`, `--shard` | Minutes for nightly or PR runs; about 2× with sharding | M |
| 5 | Try release-mode tests and tune the worker count | Unmeasured; about 10–20% for the worker count | S |

### 1.1 Stop recompiling `Package.swift` for every mutant

- **What happens.** Each mutant runs `swift test --skip-build` (`MuterConfiguration.swift:192-193`). About 9 s of each mutant's ~24 s passes before the test helper even starts. During that time each worker's `swift-test` starts new `swift-driver` processes and links the package manifest again (`Package-1.o`).
- **Likely cause.** SwiftPM's manifest cache is keyed on the environment, and every mutant sets a different activation variable. So all 22 package manifests are recompiled every time.
- **Proposal.** Keep the SwiftPM process environment identical from one mutant to the next. For example:
  1. Give each worker one fixed variable that points to a per-worker file.
  2. Write the active mutant's ID into that file before each run.
  3. Have the generated `__SwiftMutator` enum read that file once.
  4. Add `--skip-update` so a fresh worker copy never fetches dependencies. This is a smaller saving: about 40 s on each worker's first run.
- **Measure before building it.** The cause is unproven. Time two `--skip-build` runs that use an identical environment in the same copy. If the manifest is cached on the second run, the fix will work.
- **Alternative.** Capture the exact `swiftpm-testing-helper` command lines once, with `swift test --skip-build -v`, and replay them for each mutant. This saves only SwiftPM's planning time, not process start-up or test discovery.

### 1.2 Stop each mutant's test run at the first failure

- **What happens.** The test process writes straight to a file (`MutationTestingIODelegate.swift:244-245`), and the log is read only after the process exits (`:160`). So every mutant runs all three test bundles to completion, even though about 76% are killed. The first failure appears about 2.5 s after the test helper starts. The code to kill the whole process tree already exists (`MuterProcess.swift:40`), but only the timeout path uses it.
- **Proposal.**
  1. Read the test output as it streams.
  2. On the first real failure, call `terminateTree()` and record a new result, `.stoppedOnFailure`, that counts as a kill. It needs its own result because a stopped run has no summary line, and `testFailureRegEx` (`TestSuiteOutcome.swift:111-113`) only matches summary lines.
  3. Never stop the baseline run early.
  4. Put it behind a config switch.
- **Best trigger.** Use Swift Testing's JSON event stream (`--event-stream-output-path`, version 0) rather than regexes over the console output. Stop on the first `issueRecorded` event whose `isKnown` is false. The same stream also gives:
  - the ID of the test that killed the mutant (see §2.2)
  - how long each test took
  - an end-of-run event for each bundle, which tells a finished run from a crashed or stopped one
- **Bonus.** Running quietly would cut log writes from about 3.5 GB per run to a few MB.
- **Estimate.** A killed mutant would cost about 11.5 s instead of about 24 s. Weighted over all mutants: 0.76 × 11.5 + 0.24 × 25 ≈ 14.7 s. 2,497 × 14.7 / 4 ≈ **2.55 h**, against about 4.2 h now. With §1.1 as well, about **1.4 h**.
- **Limit.** On an iOS simulator (xcodebuild), `terminateTree` can't reach the test runner inside the simulator. Keep the switch for that case.

### 1.3 Skip mutants that no test reaches

- **What happens.** The coverage step assumes one test bundle. SwiftPM's newer build layout produces three, so coverage fails with only "Gathering coverage failed" (the reason is discarded) and quietly falls back to no coverage. `swift-quality` also always passes `--skip-coverage`.
- **Effect.** About 151 mutants (6%) are never executed by any test, yet each gets a full test run.
- **Options, from cheapest to most thorough.**
  1. **Reuse existing coverage.** Accept the llvm-cov JSON that `swift-quality` already produces, mapped by canonical path (the helper from #21 exists). No extra build is needed.
  2. **Fix the coverage step.** Make it handle several test bundles, and show the reason when it fails.
  3. **Trace reached switches.** Record which mutant switches the baseline run executes, and mark the rest "no coverage" without running them. This can later be extended into a map from each mutant to the tests that reach it.

### 1.4 Do less work per run

- **Reuse results across runs** (as the PIT and Stryker mutation tools and `cargo-mutants --iterate` do).
  - Key each result by a stable ID plus a hash of the source file, together with a fingerprint of the toolchain, the SwiftMutator commit and the config.
  - Reuse a "killed" result if its file and the files of the tests that killed it are unchanged. Reuse "survived" only if no test file changed.
  - Run a full run on a schedule (for example weekly) to stop old results drifting.
  - On a typical day with about 20 changed files, that's roughly 16–80 min instead of about 4.1 h.
- **`--since <ref>`, with an optional `--changed-lines`.** Mutate only the files, or the changed hunks, changed since a git ref. A 5-file change takes about 8 min.
- **CLI overrides.** Add `--workers N` and `--timeout S` so wrappers don't need to write a YAML file for each run.
- **`--shard k/n`.** Split the mutants deterministically by a hash of their stable ID, so two machines each run half, then merge the result files. That's about 2× on your two machines.
- **`--sample N --seed S`.** Run a random subset for nightly trend checks: 500 mutants takes about 50 min and gives the score ±3.4 points (95% confidence).

### 1.5 Experiments

- **Release-mode tests.** The suite is CPU-heavy swift-syntax work running unoptimised, so release mode may be faster. Try `arguments:` with `-c release -Xswiftc -enable-testing`. This is unmeasured, and the ~9 s of fixed time per mutant wouldn't change.
- **Worker count.** Try 2, 3, 4 and 6 workers. Each worker's Swift Testing run is already parallel, so expect only about 10–20%.

---

## 2. Losing or mis-scoring a run

### 2.1 Nothing is saved until the run finishes, and there's no resume (four of six agents flagged this)

- **What happens.** Outcomes exist only in memory until the report is written at the very end. The "before" run was stopped at 1,103 of 2,497 mutants and kept no structured results, only 747 MB of raw per-mutant logs. There's also no signal handler, so an interrupted run leaves its test processes and worker copies behind.
- **Proposal.**
  1. **Results file.** In `record()` (`PerformMutationTesting.swift:225`), append one JSON line per mutant and flush it. Record: the mutant ID, repo-relative path, line and column, operator, outcome, duration, worker, exit status and killing tests. Add a header line with the toolchain, the SwiftMutator commit and the config.
  2. **Partial reports.** Add `swift-mutator report <results.jsonl>` to produce a report from a partial file at any time.
  3. **`--resume`.** Skip mutants already recorded, keyed by repo-relative path plus mutant ID and checked against a hash of the file contents. Never key on job position, because the job order is random. Build on the existing commands that separate discovery from running (`mutate-without-running` / `run-without-mutating`).
  4. **Interruptions.** On SIGINT/SIGTERM or an abort, write a partial report and remove the worker copies.

### 2.2 Tests that fail only under load inflate the score

- **What happened.** SwiftProjectLint's `ProjectLinterTests.swift:98` asserts `#expect(duration < 10.0)`.
  - **Before run:** it failed in 817 of 1,103 mutant runs, and was the only failing test for about 200 mutants. Of the mutants seen in both runs, 23 of the 24 killed only by this test flipped to survived in the new run.
  - **Real score:** about 75%, not the 92.8% the before run was showing.
  - **Cause:** the baseline runs that test on its own, but mutants run four at a time. The pre-#13 slowdown made it borderline (11 s on its own), and the extra load pushed it over.
  - **After PR #13:** it takes 2.2 s on its own, but up to about 10.4 s with 4 workers. That's still close to the limit.
  - **A second suspect:** `everyFormatRendersTheSameBytesForAnyArrivalOrder` failed 103 times before and 2 times after.
- **Proposal.**
  1. Record the names of the tests that killed each mutant (from the event stream, or the `✘ Test … failed` / `Test Case '…' failed (` lines) in every report format.
  2. Add a "top killing tests" summary.
  3. Warn when one test is the only killer of more than about 5% of mutants.
  4. Optionally, every so often run a control job with no mutant active, under the same load. Mark tests that fail in it as flaky, and report kills by those tests alone as "suspect".
- **Short term.** Skip the timing test in mutation runs, the way `ParallelListDriftDogfoodTests` is already skipped.

### 2.3 Files with the same name are merged during discovery (S)

- **What happens.** `DiscoverMutationPoints.swift:29` merges mappings by file name only (`mergeByFileName`, `SchemataMutationMapping.swift:194`), and the mutant ID is built from the file name too (`MutationSchema.swift:7-11`). Mutants in a same-named file are then:
  - tested but never inserted,
  - inserted into the wrong file, or
  - scheduled twice under the same ID and log name.
- **Effect here.** 21 mutants (0.84%): 18 in `main.swift`, plus 3 because `ExampleCode/` holds a near-identical copy of `ArchitectureIssuesView.swift`. The effect grows in packages with common file names.
- **Related.** Mutants run in a different random order on every run, so you can't compare runs mutant by mutant.
- **Fix.**
  1. Merge by full path.
  2. Build the ID from the repo-relative path (or a short hash of it), plus the operator and position.
  3. Name log files by that ID.
  4. Sort the jobs by path, then position.
  5. Add a test with two same-named files.
- **Cost of the fix.** Changing the ID format means updating 11 tests and snapshots, and it invalidates existing test plans.

### 2.4 Discovery mutates files that no build target includes

- **What happens.** Files outside any target, such as `ExampleCode/` and `.swiftinfer`, get mutants that can never be killed.
- **Fix.** Build the candidate list for SwiftPM from `swift package describe --type json`, or at least skip hidden and git-ignored paths.

### 2.5 `executable: swift` silently drops `mutationTestWorkers` (S)

- **What happens.** `withExecutable` (`MuterConfiguration.swift:114`) rebuilds the configuration without `mutationTestWorkers`, so a config with a bare `executable: swift` runs one mutant at a time with no warning. That's about 2× slower: about 8 h instead of about 4.2 h. Configs generated by `init` use an absolute path and aren't affected.
- **Fix.** Use one copy-with helper for every field, and add a test that every field survives `withExecutable` and `withDefaultTestSuiteTimeout`.

### 2.6 One uncompilable mutant switch aborts the whole run

- **What happens.** A compile error in any of the ~301 rewritten files ends the run after the copy, discovery and a 86–111 s build. Stryker puts the offending mutants back instead, and cargo-mutants and mull mark them "unviable".
- **Proposal.**
  1. Make the build of the mutated project its own step.
  2. On failure, match each compiler error's path to a rewritten file and restore that file from the original project.
  3. Record its mutants as "unviable", left out of the score but listed in the report.
  4. Rebuild incrementally, and repeat for a few rounds.
  5. Always print a loud warning naming the files that were dropped.
- **Effect.** Losing about 8 mutants instead of all 2,497.

### 2.7 Smaller classification problems (S)

- **Truncated logs.** A timed-out run whose log ends in the middle of a UTF-8 character is recorded as a build error. That's left out of the score and counts toward the 5-in-a-row abort.
- **Timeouts.** They count as survivors in the score.
- **Timeout length.** The default timeout is 3 × (build + test), measured with nothing else running. That's about 5× looser than a limit based on test time under load would be.
- **Rounding.** Fractional timeouts are truncated (`TestingTimeOutExecution.swift:31`), and the score is truncated rather than rounded (`mutationScoring.swift:13`).
- **Identical statements.** `RemoveSideEffects` deletes every identical sibling statement, so two identical statements give two identical mutants.

---

## 3. Watching a run and using the report

- **Progress output in a log file (S).**
  - When stdout isn't a terminal, the progress bar's cursor codes end up in the log file.
  - Output is block-buffered, so its tail is lost if the process is killed.
  - There are no timestamps.
  - The finish estimate (ETC, `ProgressExtensions.swift:16`) multiplies the gap since the last finished mutant by the number left, so with 4 workers it swings between 12 and 3,165 minutes.

  Instead, print one timestamped, flushed line per mutant, for example `[13:13:25] 1103/2497 (44%) killed 1023 survived 78 … | 35.3 s/mutant | ETA 13h40m`, with the estimate based on the average rate. Collapse the file listings unless `--verbose` is given.
- **Reports.**
  - List survivors first, with repo-relative `path:line:col`, the original source line (before → after), the killing tests and the duration.
  - Add `relativePath` and the mutant ID to the JSON.
  - Write a `summary.json` with the score, the counts and the wall time.
  - Never colour report files.
  - Say "coverage skipped" when coverage was skipped.
- **Provenance.** Record the SwiftMutator commit, toolchain, config, worker count, effective timeout, mutant IDs and per-mutant durations, so that two runs can be compared mutant by mutant.
- **Exit codes.** Add `--fail-under <pct>` or `scoreThreshold:`, with distinct exit codes for "below threshold", "timeouts", "baseline failed" and "aborted". Wrappers can then stop parsing report text.
- **Log storage.** Each mutant's log is written twice, about 3.4 GB per full run, and never cleaned up. Write it once, and keep full logs only for survivors, crashes and timeouts.

---

## 4. Repo health

- **No CI.** None of the 22 PRs had an automated check, and the old Muter CI scripts are dead (`Scripts/ci/*` uses envman, and `Makefile:52` points to a script that doesn't exist). Add a macOS workflow that:
  - pins the toolchain,
  - caches `.build`,
  - runs `swift build --build-tests` and `swift test --filter muterTests`.

  Run the regression suite nightly or on demand.
- **`swift test` fails by design.** A plain `swift test` fails 18 tests from the acceptance and regression harnesses. Skip those unless their sample projects exist, or move them into their own package. Every `make` test target also runs `swift package clean` first; keep that in `make clean` only.
- **The generated mutant code is never type-checked in tests.** The snapshots record swift-format's rewrite and hide errors. Add a small fixture to type-check, covering:
  - result builders
  - opaque non-builder bodies
  - file-scope `#if`
  - `main.swift`
  - ternaries containing longer expressions

  Three of the four recent rewriter fixes would have been caught.
- **Real-process tests.**
  - a timeout test that kills a tree of `sleep` processes and checks none survive
  - a test that copies a temporary folder for a worker and checks it's kept separate and cleaned up
  - one real log from SwiftProjectLint's three test bundles as a fixture
- **Upstream Muter leftovers.** The banner's help link, version 0.1.0 and the update check still point at Muter. The toolchain setup (swiftly with `SDKROOT=…/MacOSX26.5.sdk`) isn't documented for contributors.
- **Swift 6 readiness.** There's global mutable dependency injection, blocking waits on the cooperative thread pool, and an untyped NotificationCenter bus.
- **Better relational-operator mutants.** Today `<` and `>` are swapped, which almost any test kills. Boundary mutants (`<` → `<=`, `>` → `>=`, and so on) would expose missing edge-case tests. Alternatively, add them as a separate operator. The count stays at 218, but the score may drop a few points.
- **xcodebuild projects.** These always test one mutant at a time. The per-worker copies used for SwiftPM could cover them too, with a cloned simulator per worker.

---

## Checked and not worth doing

- **One mutant per line.** 2,478 inserted mutants sit on 2,205 lines, so a cap saves at most 11%.
- **`--disable-xctest`.** These runs contain only Swift Testing bundles, so there's nothing to skip.
- **One long-lived test process for many mutants.** PR #13's per-process environment cache, and other static state that persists between mutants, make this unsafe.

## Suggested order

1. **Small correctness fixes:** same-name merge, worker drop, UTF-8 classification (§2.3, §2.5, §2.7).
2. **The base for most of the rest:** a per-mutant results file and the killing tests for each mutant (§2.1, §2.2).
3. **Fail-fast,** triggered by the event stream (§1.2).
4. **Measure, then fix, the manifest recompile** (§1.1).
5. **Progress output** that works in a log file (§3).
6. **Reuse, `--since`, the coverage fix and CI** (§1.3, §1.4, §4).

## Outside this repo

- **`swift-quality`.**
  - It prints `swift --version` before it changes into the project folder (line 79 versus line 84). That's why the header said 6.3.3 for one run and 6.4 for the other. Both runs actually tested with Xcode's toolchain, because SwiftProjectLint's `.swift-version` is `xcode`.
  - Add start and end timestamps to `summary.txt`.
  - Exclude `ExampleCode/` and `.swiftinfer`.
- **SwiftProjectLint.** Skip, or rewrite, the wall-clock timing test in `ProjectLinterTests.swift:98` for mutation runs.
- **Spotlight.** It indexes the copies and logs under `~/xcode_projects`. Naming the work folders `*.noindex` is a cheap fix, though the benefit hasn't been measured.
