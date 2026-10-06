# SwiftMutator improvement review: 2 October 2026

This is a ranked list of improvements to SwiftMutator, made at commit `4ba72fc` after PR #13 (the cached-environment speedup) landed.

- **How it was produced.** Thirteen agents read the code and the run logs without modifying anything. Six of them each examined one area. Six more each tried to disprove another agent's suggestions against the code. A final agent looked for anything all of them had missed.
- **How the suggestions held up.** There were 61 suggestions. Verification rejected none of the 54 from the six areas. About half of those needed a corrected estimate, and the corrected numbers are used below. The final agent's seven suggestions weren't separately checked.
- **Status, updated 6 October 2026.** Each finished item below says what was done and what was left out.
  - CI (§4) is done in PR #24, and §2.3, §2.5 and the three bug fixes in §2.7 in PRs #25–#27.
  - Fail-fast (§1.2) is done in PR #36, and on by default for SwiftPM since PR #41, after an A/B run took 37% less time. One part of PR #36 applies whether or not it's on: a time-out rule that can raise scores (see §2.7).
  - The manifest recompile (§1.1) is fixed in PR #42, after lab measurements confirmed its cause. An A/B run of the merged build is still to do.
  - A plain `swift test` and `swiftlint` pass on `main` since PR #37 (§4).
  - The results file (§2.1 item 1) and the data for §2.2 item 1 are done in PR #38.
  - Clean interruptions (§2.1 item 4) are done: Ctrl-C, SIGTERM and SIGHUP stop the test processes, end the results file, write a partial report beside a requested one, and remove the worker clones.
  - The `report` command (§2.1 item 2) is done: `swift-mutator report` makes a run's report, in any format, from its results file.
  - `--resume` (§2.1 item 3) is done, which finishes §2.1: `swift-mutator run --resume` continues a stopped run, testing only the mutants without a result that still holds.
  - Problems found along the way, and which PRs fixed them, are under [Found while implementing](#found-while-implementing). Two are still open.

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
| 1 | Stop recompiling `Package.swift` for every mutant (PR #42) | About −1 h. Measured in the lab: 29% less time per mutant with 4 workers | M |
| 2 | Stop each mutant's test run at the first failure (PR #36, on by default since PR #41) | About 1.65×; with #1, **4.2 h → 1.4 h**. Measured: 37% less time on 255 mutants | M |
| 3 | Skip mutants that no test reaches (about 6%) | About −16 min | M |
| 4 | Do less work per run: reuse unchanged results, `--since`, `--shard` | Minutes for nightly or PR runs; about 2× with sharding | M |
| 5 | Try release-mode tests and tune the worker count | Unmeasured; about 10–20% for the worker count | S |

### 1.1 Stop recompiling `Package.swift` for every mutant

**Done in PR #42** (SwiftPM only: `swift test`, or a wrapper with `buildSystem: swift`).
- **Cause, confirmed.** SwiftPM 6.4 hashes the name and value of every environment variable, apart from a short deny-list, into its manifest cache key. So each mutant's own `<id>=YES` made every run compile all 22 manifests and add 22 rows to the shared cache. One fixed variable whose value changes each run measured the same: 9.81 s against 9.81 s. Only an identical environment helps.
- **Fix.** Every run in a worker's folder, baseline included, gets one environment.
  - `SWIFTMUTATOR_ACTIVE_MUTANT_FILE` names the folder's hidden `.swiftmutator-active-mutant` file. It holds the mutant's ID, or nothing for a baseline, and is written just before each run.
  - The generated `__SwiftMutator` enum reads the file once. If it can't, the tests stop with a fatal error, so a broken channel fails the baseline instead of letting every mutant survive.
  - xcodebuild and other wrappers keep each mutant's own variable. A SwiftPM test plan made by an older SwiftMutator is refused.
- **Measured in the lab** (Swift 6.4, SwiftProjectLint's full suite with `--skip-build`).
  - One run on its own: 9.81 s → 7.60 s.
  - 4 free-running workers: 21.6 s → 15.3 s per mutant per worker, 29% less. The time before the test helper starts went from 7.7 s to 1.9 s.
  - A prototype, run end to end on 24 mutants with 4 workers: the median time per mutant went from 20.02 s to 13.77 s. Mutant runs added no manifest rows, against 22 each before, and all 24 outcomes and failed-test counts matched.
  - `--skip-update` made no measurable difference, so it isn't used.
- **Projection.** About 2,497 × 6 s / 4 ≈ 1 h off the ~4.1 h run.
- **Not done yet.**
  - An A/B run of the merged build on SwiftProjectLint, and a full run.
  - About 1.3–1.9 s still passes before the test helper starts: toolchain probes, loading the package graph, a resolution step on every run, and XCTest discovery.
  - Tests that list hidden files at the package root, or need a clean `git status` in the copy, see the file. They see it in the baseline too, so they fail loudly.

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

**Done in PR #36, and on by default since PR #41** (SwiftPM only; turn it off with `stopAtFirstFailure: false`).
- **Trigger.** It doesn't use the event stream proposed below. On Swift 6.4 with several test bundles, SwiftPM merges the bundles' event streams only when the whole run exits, and the stream never covers XCTest.
  - Instead the run stops at the first console line that shows a failed test, matched from the start of the line: Swift Testing's `✘ … recorded an issue`, or XCTest's `Test Case '…' failed (`. Known issues and warnings don't match.
  - With the switch on, every test process gets `NSUnbufferedIO=YES`, baselines included. Otherwise `swift test` relays output in 4 KiB blocks, so the failure line arrives late, and a stopped run can lose the part of its log still in the buffer.
- **Behaviour.**
  - A stopped run counts as killed, and its log ends with a note naming the line that stopped it.
  - The baseline is never stopped.
  - Stopping turns itself off for any run whose passing baseline prints a line that looks like a failure.
- **Checked.** The 2 October run left 2,488 logs: 2,487 mutant logs and the baseline's.
  - The trigger matched every run scored as failed.
  - It also matched 19 runs that recorded an issue and then crashed. They are still killed, by a failure rather than a crash.
  - It matched nothing in the passing baseline, and gave no false matches.
- **Measured, 5 October.** An A/B run on SwiftProjectLint: 255 mutants in 33 files, 4 workers, arms in the order off, on, on, off.
  - **Time.** The whole run took 37% less time (1,847 s against 2,937 s for the two arms of each), and testing the mutants 46% less. A killed mutant took about 7 s instead of about 18 s.
  - **Verdicts.** The switch changed none.
    - Two mutants were killed in only one off arm each, because SwiftProjectLint's `analyze(files:)` test helper walks a Dictionary in hash-seed order. Repeated runs give the same kill rates with the switch on or off.
    - One mutant that both fails a test and crashes was reported as a runtime error with the switch off and a test failure with it on. It's killed either way.
  - **Survivors.** Not slower: 0.0% in a test that ran both modes side by side under the same load.
  - **Leftover processes.** No test process outlived its run, sampled every 0.57 s.
  - **Temporary files.** The temporary folder grew by the same number of bytes in both modes. Stopped runs leave about 4–5 extra entries each, because a killed test skips its cleanup.
  - **Projection.** For the full 4.1 h run, the PR's estimate of about 2.6–2.8 h holds.
- **Not done yet.**
  - Running quietly, the bonus below.
  - Stopping crash-only runs at SwiftPM's "exited with signal" line. Today they run their remaining test targets, about 1–3 s each.

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

**Item 1 done in PR #38.**
- **The file.** [results-file.md](results-file.md) documents the format.
  - A header line is written once the baseline passes, to `results.jsonl` in the run's log folder, or `results-2.jsonl` and so on if that name is taken.
  - Each tested mutant's result is appended as it finishes, and flushed with `fsync`.
  - An end line follows only when mutation testing stops by itself. A run ended by Ctrl-C, SIGTERM or SIGKILL has none. *(Since item 4, Ctrl-C, SIGTERM and SIGHUP write one too. SIGKILL still doesn't.)*
- **Keys.** Results are keyed by repo-relative path, operator, line, column and occurrence, never by job position or mutant ID.
- **Provenance.** Most of what §3 asks for is recorded (see §3).
  - The header records the SwiftMutator build, as its executable's SHA-256 in place of the commit, plus the toolchain, the configuration, the worker count and the effective timeout.
  - Each mutant line has its switch ID and duration.
- **Cancellation.** A run that returns after mutation testing was cancelled is never recorded.

**Item 4 done.** Ctrl-C, SIGTERM and SIGHUP stop a run cleanly. The README's [Stopping a run](../README.md#stopping-a-run) says what a user sees.
- **Test processes.** The first signal cancels mutation testing before anything is killed, so a run that the stop ended is never recorded. SwiftMutator then kills every process it started, and keeps killing new ones every 0.25 s until it exits. Each test process already leads a process group of its own, so the terminal's Ctrl-C reaches SwiftMutator alone.
- **What's kept.** The results file gets an end line that names the signal. With `-o`, a partial report is written beside the requested one, never over it. Worker clones are removed, and each run's start removes any that an earlier run left.
- **Exit.** SwiftMutator dies by the same signal, so the shell sees 130, 143 or 129. A second signal, or 30 s without stopping, exits at once, except a SIGHUP after a SIGHUP: zsh sends two when its terminal closes. Aborts still exit 255, and now write the partial report and a summary too.
- **Signals from outside.** A test run that seems to have died of SIGINT, SIGTERM or SIGHUP waits 250 ms before it is recorded. If the signal reaches SwiftMutator too in that time, as one from `killall` or a logout does, the run is discarded rather than counted as killed.

**Item 2 done.** `swift-mutator report <results file or log folder> [-f] [-o]` makes a run's report from its results file, in any format. [Reports from the file](results-file.md#reports-from-the-file) says what a user sees.
- **Exact for a finished run.** The run's outcome is rebuilt from the file: each mutant's last line, in the order the run tested them, under the last header's project paths, coverage and update notice, with the end line's exact test duration. Its report equals the run's own in all four formats. Only the HTML footer's time, the order of the Xcode warnings, the plain text's colours and the JSON key order can differ, and each depends on when or where a report is made. A unit test checks this on real `PerformMutationTesting` runs with 1 and 2 workers, and `ReportCommandAcceptanceTests` on the built `swift-mutator`.
- **Job order without a format change.** The order comes from fields already in the file: the resolved path, then `switchID` compared as text, then `occurrence`. That is how discovery sorts its jobs. A test over real discovery output fails if discovery's order changes.
- **Partial runs.** The file of a run that stopped, crashed or is still going gives a report of what it holds. A stopped run's report equals its partial report. How complete the file is goes on standard error, not into the report.
- **The stop summary** now ends with the command, with the results file's path quoted for the shell.
- **One report writer.** The final report, the partial report and `report` all save through `ReportWriter`.

**Item 3 done.** `swift-mutator run --resume <results file or log folder>` continues a stopped run, and a stopped run's summary ends with the command that does it. The README's [Resuming a run](../README.md#resuming-a-run) says what a user sees.
- **What's kept.** Discovery runs again, and a result is kept only if its key's place and operator appear once, it isn't a build error, its file's SHA-256 matches, and its snapshot is unchanged. Timeouts are kept: the score counts them like survivors, so a kept one can't raise it. Results are matched by key, never by job position, as the proposal asked. Unlike the proposal, it doesn't build on `mutate-without-running` and `run-without-mutating`, and a test-plan run can't be resumed.
- **Strict by default.** A change to the configuration (except `mutationTestWorkers` and `stopAtFirstFailure`) or to which mutants are tested always refuses. A changed SwiftMutator build, toolchain or SDK needs `--force-resume`, and changed project files need `--resume-ignoring <glob>`. Every refusal comes in one message, without the bug-report banner, and before the cleanup and the copy, except for a file that changes during the copy.
- **The project's files.** Every run now records each project file's SHA-256 in its header: the files git lists in the project, tracked and untracked but not ignored, plus every Swift file, `.swift-version` and the root `Package.resolved`, hashed in the copy before discovery rewrites it. That takes about 0.1 s and 205 KB on SwiftProjectLint. There's no default ignore list, because SwiftProjectLint's tests read its Markdown.
- **One file.** A resumed session appends to the same results file. Its `retired` line drops the results it no longer stands by, and its header says `formatVersion` 2, so a SwiftMutator from before `--resume` refuses the file rather than misreport it. The report at the end, and `report` of the file, cover every mutant.
- **What it saves.** The copy, build, baseline and worker clones are made again, which is 5–9% of a full SwiftProjectLint run. So a resume of a run stopped halfway should save about 33–46 min (~46%). In the lab's small runs, setup was most of the run, and the estimate was 12–18%.
- **Left out.** Retesting timeouts under a longer limit, `run-without-mutating --resume`, §1.4's `--since`, a lock on the project as well as the file, and a link to the results file in later sessions' log folders.

- **What happens.** Outcomes exist only in memory until the report is written at the very end. The "before" run was stopped at 1,103 of 2,497 mutants and kept no structured results, only 747 MB of raw per-mutant logs. There's also no signal handler, so an interrupted run leaves its test processes and worker copies behind.
- **Proposal.**
  1. **Results file.** In `record()` (`PerformMutationTesting.swift:225`), append one JSON line per mutant and flush it. Record: the mutant ID, repo-relative path, line and column, operator, outcome, duration, worker, exit status and killing tests. Add a header line with the toolchain, the SwiftMutator commit and the config.
  2. **Partial reports.** Add `swift-mutator report <results.jsonl>` to produce a report from a partial file at any time.
  3. **`--resume`.** Skip mutants already recorded, keyed by repo-relative path plus mutant ID and checked against a hash of the file contents. Never key on job position, because the job order is random. Build on the existing commands that separate discovery from running (`mutate-without-running` / `run-without-mutating`).
  4. **Interruptions.** On SIGINT/SIGTERM or an abort, write a partial report and remove the worker copies.

### 2.2 Tests that fail only under load inflate the score

**Item 1 partly done in PR #38.** Each killed, crashed or timed-out mutant's line in the results file names up to 20 failing tests, plus how many failed in all.
- **Swift Testing.** Read from its `✘ Test … recorded an issue` and `✘ Suite … recorded an issue` lines, with the issue's location when the line gives one.
- **XCTest.** Read from its `Test Case '…' failed (` lines, which give no location.
- **Gaps.** The list is left out when the passing baseline printed a line that looks like a failure. No report format shows the tests yet, and items 2–4 aren't done.

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

**Done in PR #25.** Mappings are merged by full path, the discovery summary adds up same-named files, and files are tested in path order. Deferred: path-qualified mutant IDs and log names (best done after §2.4), and source-position order within a file, which stays by mutant ID but is deterministic. Until the IDs change, same-named files' mutants can share a switch variable and a kept-log name, as the two `ArchitectureIssuesView.swift` copies do. The results file's keys (§2.1) don't depend on either.

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

**Done in PR #26.** `withExecutable` keeps the worker count, and both `with…` helpers now copy `self` and change only their own field. A `Mirror`-based test fails if a new field is added without the test builder setting it.

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

**Partly done in PR #27.** Fixed: truncated logs (the log is now decoded leniently), fractional timeouts, and identical statements (RemoveSideEffects now excludes by node identity). Left out by choice: counting timeouts as killed, the default timeout length, and rounding the score. One exception since PR #36, which applies whether or not `stopAtFirstFailure` is on: a timed-out run counts as killed if its log already shows a recorded Swift Testing issue, as a run showing XCTest's failed-test line already did. This can raise scores compared with earlier runs. The new Swift Testing rule doesn't apply to a run whose passing baseline printed a line that looks like a failure.

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
- **Provenance.** Record the SwiftMutator commit, toolchain, config, worker count, effective timeout, mutant IDs and per-mutant durations, so that two runs can be compared mutant by mutant. *(Mostly done in PR #38. The results file's header records the SwiftMutator build, as its executable's SHA-256, plus the toolchain, configuration, worker count and effective timeout. Each mutant line has its key, switch ID and duration. The reports themselves don't show any of it.)*
- **Exit codes.** Add `--fail-under <pct>` or `scoreThreshold:`, with distinct exit codes for "below threshold", "timeouts", "baseline failed" and "aborted". Wrappers can then stop parsing report text.
- **Log storage.** Each mutant's log is written twice, about 3.4 GB per full run, and never cleaned up. Write it once, and keep full logs only for survivors, crashes and timeouts.

---

## 4. Repo health

- **No CI.** None of the 22 PRs had an automated check, and the old Muter CI scripts are dead (`Scripts/ci/*` uses envman, and `Makefile:52` points to a script that doesn't exist). Add a macOS workflow that:
  - pins the toolchain,
  - caches `.build`,
  - runs `swift build --build-tests` and `swift test --filter muterTests`.

  Run the regression suite nightly or on demand.

  **Done in PR #24.** `.github/workflows/ci.yml` builds the package and runs the unit suite on every pull request and push to `main`, on `macos-26` (Xcode 26.6, Swift 6.3) and `xcode-27` (Xcode 27.0, Swift 6.4). It fails if the test filter matches nothing. The Bitrise scripts and the `ci-*` make targets are removed. Not done yet: a nightly regression run, a SwiftLint job (unblocked since PR #37 added the 20 missing trailing commas), caching, and required checks.
- **`swift test` fails by design.** A plain `swift test` fails 18 tests from the acceptance and regression harnesses. Skip those unless their sample projects exist, or move them into their own package. Every `make` test target also runs `swift package clean` first; keep that in `make clean` only. *(The skip is done in PR #37: each harness skips itself while its `samples` folder doesn't exist. Once a script has created that folder, the tests run as before, and fail if what the script generated is missing or wrong. Not done: `make build`, which the acceptance and regression targets run first, still starts with `swift package clean`.)*
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

  *Partly done:*
  - *PR #36's `ProcessTreeTests` kills a real tree of `sleep` processes and checks none survive.*
  - *PR #36's `StopAtFirstFailureProcessTests` stops a real stand-in test command.*
  - *PR #34's `test_cloningTheMutatedProject_discardsItsModuleCaches` copies a real temporary folder for a worker.*
  - *The interruption work (§2.1 item 4) checks that real worker clones are removed, and its `InterruptionAcceptanceTests` stop the built `swift-mutator` with real signals and check that no test process survives.*

  *Still missing: a real-process test of the timeout path (it uses only a stand-in process), and the SwiftProjectLint log fixture.*
- **Upstream Muter leftovers.** The banner's help link, version 0.1.0 and the update check still point at Muter. The toolchain setup (swiftly with `SDKROOT=…/MacOSX26.5.sdk`) isn't documented for contributors.
- **Swift 6 readiness.** There's global mutable dependency injection, blocking waits on the cooperative thread pool, and an untyped NotificationCenter bus. *(Since PR #36, waiting for a test process to exit no longer blocks a pool thread.)*
- **Better relational-operator mutants.** Today `<` and `>` are swapped, which almost any test kills. Boundary mutants (`<` → `<=`, `>` → `>=`, and so on) would expose missing edge-case tests. Alternatively, add them as a separate operator. The count stays at 218, but the score may drop a few points.
- **xcodebuild projects.** These always test one mutant at a time. The per-worker copies used for SwiftPM could cover them too, with a cloned simulator per worker.

---

## Checked and not worth doing

- **One mutant per line.** 2,478 inserted mutants sit on 2,205 lines, so a cap saves at most 11%.
- **`--disable-xctest`.** These runs contain only Swift Testing bundles, so there's nothing to skip.
- **One long-lived test process for many mutants.** PR #13's per-process environment cache, and other static state that persists between mutants, make this unsafe.

## Suggested order

1. **Small correctness fixes:** same-name merge, worker drop, UTF-8 classification (§2.3, §2.5, §2.7). *Done in PRs #25–#27.*
2. **The base for most of the rest:** a per-mutant results file and the killing tests for each mutant (§2.1, §2.2). *Results file done in PR #38, with the killing tests in it; reports don't show them yet. Clean interruptions, the `report` command and `--resume` are done too.*
3. **Fail-fast,** triggered by the event stream (§1.2). *Done in PR #36, triggered by console lines instead (see §1.2). On by default since PR #41, after an A/B run took 37% less time.*
4. **Measure, then fix, the manifest recompile** (§1.1). *Done in PR #42: every `swift test` run in a worker's folder gets one environment, and the mutant is named in a file.*
5. **Progress output** that works in a log file (§3).
6. **Reuse, `--since`, the coverage fix and CI** (§1.3, §1.4, §4). *CI done in PR #24.*

## Found while implementing

- **SwapTernary can mutate the wrong ternary.** `MuterVisitor.transform` finds the node to change with `codeBlockDescription.range(of: node.description)`, which returns the first matching text in the block. `TokenAwareVisitor` overrides this with offsets, so RelationalOperatorReplacement and ChangeLogicalConnector are safe, but SwapTernary doesn't. When the same ternary appears twice in one block, the second mutant changes the first one. Upstream Muter has the same code. The fix is to locate nodes by offset in the base `transform`, with its own failing-first test. *(Fixed in PR #31: `transform` locates the node by its position, and keeps the text search only as a fallback.)*
- **The score's rounding contradicts Muter's README.** The README's example says killing 50 of 75 mutants scores 67%, but `mutationScoring.swift:13` truncates, so the code reports 66%. §2.7 left the truncation as it is, so either the example or the code should change.
- **A declaring `#if` clause hid its declarations.** Switching the statements inside a `#if` clause hid the clause's declarations from the code after `#endif`, so the shared baseline build failed. One example is swift-argument-parser 1.8.2's `TestHelpers.swift`. *(Fixed in PR #31: such a clause's mutants switch the statement list around the `#if`.)*
- **The injected import broke some builds.** The injected `import class Foundation.ProcessInfo` clashed with a module's own `internal import Foundation`. Separately, the copy step kept Swift Build's `ModuleCache.noindex`. *(Both fixed in PR #28.)*
- **Worker clones shared files through compiled-in paths.** Clones ran test binaries built in the mutated project, so a test's `#filePath` pointed into that project. Tests that write next to their sources overwrote each other across workers, and each failure counted as a kill. *(Fixed in PR #34: each clone is built in its own folder before any mutant runs there. PR #32 fixed SwiftMutator's own tests that wrote next to their sources.)*
- **SwiftMutator couldn't mutation-test itself.** The process factory passed on an `IS_MUTER_RUNNING` it had inherited. So when SwiftMutator's own suite was the one being tested, its test that checks the factory leaves the marker out failed, and the baseline aborted. *(Fixed in PR #33: the factory removes an inherited marker. Test processes still set it explicitly.)*
- **Ending a test run had races.** These could change results:
  - a time limit that fired just after the process exited killed an exited PID and reported a passing run as a timeout;
  - a cancelled run, for example when too many build errors stop mutation testing, wasn't killed and ran to the end of its tests;
  - a tree kill could miss a test runner started between listing the tree and killing it.

  *(Fixed in PR #36's first four commits.)*
- **Waiting for a test process to exit could hang.** Reviewers of PR #36 saw `waitUntilExit()` on a GCD thread occasionally never return in their own copies, but only when the process had no `terminationHandler`. Every test process now has one, and the hang hasn't been seen in SwiftMutator. Having `exited()` resume from `terminationHandler` itself would be sturdier.
- **A failed worker clone leaks the clones before it.** If copying clone n fails, `cloneMutatedProject` throws before the caller has set up its cleanup. Clones 1 to n−1 and clone n's partial copy stay on disk until a later parallel run replaces them. *(Fixed by the interruption work in §2.1 (item 4): a failed clone removes the clones made before it and its own partial copy, and each run's start removes worker clones an earlier run left behind.)*
- **Default-MainActor modules failed to build.** With `-default-isolation MainActor`, the generated `__SwiftMutator` enum is isolated to the main actor too. A mutant in a nonisolated function, an actor, a `Sendable` closure or another global actor then can't read the cache: "main actor-isolated static property 'environment' can not be referenced from a nonisolated context". Every mutant is compiled into the one mutated project, so a single such mutant failed the baseline build and aborted the whole run before any mutant was tested. Swift 6 mode failed this way on every toolchain from 6.2.3 to 6.5-dev. Swift 5 mode only warns, which still fails a `-warnings-as-errors` build. *(Fixed in PR #43: the cache is a `nonisolated static let`, which builds with no warnings on those toolchains under either default isolation.)*

## Outside this repo

- **`swift-quality`.**
  - It prints `swift --version` before it changes into the project folder (line 79 versus line 84). That's why the header said 6.3.3 for one run and 6.4 for the other. Both runs actually tested with Xcode's toolchain, because SwiftProjectLint's `.swift-version` is `xcode`.
  - Add start and end timestamps to `summary.txt`.
  - Exclude `ExampleCode/` and `.swiftinfer`.
- **SwiftProjectLint.**
  - Skip, or rewrite, the wall-clock timing test in `ProjectLinterTests.swift:98` for mutation runs.
  - Sort the files that `PrimitiveNamedForDomainTypeVisitorTests.analyze(files:)` walks. It walks a Dictionary in hash-seed order, so two `RemoveSideEffects` mutants (lines 77 and 105) are killed in only about 75% and 50% of runs. The score moves by a point or two from run to run.
- **Spotlight.** It indexes the copies and logs under `~/xcode_projects`. Naming the work folders `*.noindex` is a cheap fix, though the benefit hasn't been measured.
