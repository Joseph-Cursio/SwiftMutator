# SwiftMutator improvement review: open items

This started as a ranked review of SwiftMutator on 2 October 2026, at commit `4ba72fc`, after PR #13 (the cached-environment speedup). On 7 October, at `44c1b41`, the finished work was taken out. Every remaining item was checked again against the code, and its line references and estimates brought up to date.

- **Done and removed.**
  - CI (§4, PR #24).
  - The same-name merge (§2.3, PR #25), the worker drop (§2.5, PR #26) and three classification fixes (§2.7, PR #27).
  - Fail-fast (§1.2, PR #36), on by default since PR #41.
  - A passing plain `swift test` and `swiftlint` (PR #37).
  - The results file, clean interruptions, `report` and `--resume` (§2.1, PRs #38 and #44–#46).
  - The manifest recompile (§1.1, PR #42).
  - Killing tests and suspect tests (§2.2 items 1–3, PRs #38 and #47).
  - The bugs found while implementing, fixed in PRs #28, #31–#34, #36, #43 and #44.
  - The reparse edit's UTF-8 range (PR #49).
  - RemoveSideEffects joining a `;`-separated statement onto the line above (PR #52).
  - A mutant switch's closing brace landing in a `//` comment or after `#endif` (PR #53).
  - SwapTernary replacing the trivia on either side of the swap, which could join two statements or comment out the swap (PR #54).
  - SwapTernary moving a trailing closure to the end of a `guard` condition, and putting code after a `#endif` (PR #55).

  Their write-ups are in [this file at `44c1b41`](https://github.com/Joseph-Cursio/SwiftMutator/blob/44c1b41/Docs/improvement-review-2026-10-02.md), except those of PRs #49 and #52–#55, which are in the PRs themselves.
- **Section numbers are the original ones,** so references in PRs and notes still work. A missing number is a finished section.

## The workload these numbers come from

SwiftProjectLint at `c2082e5d`, the whole repo: 2,497 mutants in 302 files, 4 workers and `--skip-coverage`. It was run with SwiftMutator `main` at `0ca6c03` on 6 October.

| | |
|---|---|
| Whole run | **1 h 31 min** (5,438 s), against 4 h 09 min on 2 October, before §1.1 and §1.2 |
| Time per mutant per worker | 8.1 s on average: 4.0 s for the 1,864 mutants (75%) stopped at their first failed test, and 16.8 s for a survivor, which runs the whole suite |
| Throughput | About 28 mutants a minute |
| Fixed setup | About 6.4 min: the copy, discovery, the build, the baseline and the worker clones' builds. That is 5,438 s − 2,497 × 8.1 s / 4 = 382 s |
| Outcome | 1,894 killed, 594 survived, 9 timed out |

The machine has 4 performance cores and 4 efficiency cores, and 24 GB of RAM. With 4 workers the load averaged about 28.

---

## 1. Speed

| § | Change | Time saved on the 1 h 31 min run | Effort |
|---|---|---|---|
| 1.1 | Cut the time each mutant spends before its test helper starts | Up to about 14–20 min | M |
| 1.2 | Stop crash-only runs early, and run quietly | Under a minute; quiet running saves disk, not time | S |
| 1.3 | Skip the mutants that no test reaches (about 6%) | About 11 min | M |
| 1.4 | Do less work per run: reuse unchanged results, `--since`, `--shard` | A small change runs in about 8–12 min instead of 91; two machines run the whole repo 1.9× faster | M |
| 1.5 | Try release-mode tests, and tune the worker count | Unmeasured; up to about 9–18 min for the worker count | S |
| 2.7 | Base the default time limit on test time | About 8.5 min | S |

### 1.1 Time before the test helper starts

The manifest recompile is fixed (PR #42). Left:
- **Fixed time per mutant.** About 1.3–1.9 s still passes before the test helper starts. It goes on toolchain probes, loading the package graph, a resolution step on every run, and XCTest discovery. Each mutant runs `swift test <arguments> --skip-build` (`MuterConfiguration.swift:226-227`) and nothing more.
  - Removing all of it would save 2,497 × 1.3–1.9 s / 4 ≈ 14–20 min, so that is an upper bound.
  - One option is to capture the exact `swiftpm-testing-helper` command lines once, with `swift test --skip-build -v`, and replay them for each mutant. That saves only SwiftPM's planning time, not process start-up or test discovery.
  - `--disable-xctest` hasn't been tried. These runs have no XCTest tests, but `swift test --skip …` still starts `swiftpm-xctest-helper` on each test bundle to look for them. On a one-bundle probe that cost about 0.07 s per run; on SwiftProjectLint's three large bundles it's unmeasured. A project with no XCTest tests can add the flag to `arguments:`. SwiftMutator mustn't add it by default, because an XCTest project would then run no tests and every mutant would survive.
  - `--skip-update` was measured and made no difference.
- **Tests can see the active-mutant file.** It's written at the root of each worker folder (`MutationTestingIODelegate.swift:355-358`), and the copy keeps `.git`. So a test that lists hidden files at the package root, or needs a clean `git status`, sees it. It does so in the baseline too, so the test fails loudly rather than mis-scoring. Writing the file beside the clone, and pointing the variable there, would remove the problem.

### 1.2 Fail-fast: what's left

Fail-fast is done (PR #36), and on by default since PR #41. Left:
- **Stopping crash-only runs.** The stop trigger matches only failed-test lines (`TestLogFollower.swift:62`). So a run that crashes without a failed test runs its remaining test targets, about 1–3 s each.
  - The crash pattern already exists (`TestSuiteOutcome.swift:96-106`). A run stopped this way must still score as a runtime error.
  - Only 30 kills on 6 October weren't stopped at a failed test. A crash in the first bundle still runs the other two, so this saves under a minute: at most 30 × 2 × 1–3 s / 4 ≈ 15–45 s.
- **Running quietly.** Test processes write all their output to each mutant's log (`MutationTestingIODelegate.swift:373-374`). A quiet mode would cut the log volume (see Log storage in §3). It must keep every line SwiftMutator reads:
  - the `✘ … recorded an issue` and `Test Case '…' failed (` lines, which fail-fast, killing tests and the baseline check read;
  - the suite summaries, build-error lines and crash lines, which scoring reads (`TestSuiteOutcome.swift:50-56`, `:96-138`).

### 1.3 Skip mutants that no test reaches

- **What happens.** The coverage step assumes one test bundle, but SwiftPM's newer build layout makes one per test target (three for SwiftProjectLint), so coverage fails.
  - `xctestExecutable` (`BuildSystem.swift:83-85`) returns every bundle `find` lists as one path, and `coverageReport` (`SwiftCoverage.swift:63-97`) builds one `llvm-cov` call from it.
  - `CoverageError` has only `.build` (`BuildSystem.swift:134-136`), so the log prints a fixed "Gathering coverage failed" (`Logger.swift:73-83`) and the reason is lost.
  - `swift-quality` also always passes `--skip-coverage`.
- **Effect.** About 151 mutants (6%) are never executed by any test. They survive, so each runs the whole suite: 151 × 16.8 s / 4 ≈ 10.6 min, about 12% of the run.
- **Options, from cheapest to most thorough.**
  1. **Reuse existing coverage.** Accept the llvm-cov JSON that `swift-quality` already produces, mapped by canonical path. The helpers from PR #21 exist. No extra build is needed.
  2. **Fix the coverage step.** Handle every bundle, merge their reports, and say why it failed. `functionsCoverage` (`BuildSystem.swift:51-81`) has the same one-bundle flaw, and `testProfileData` (`:94-102`) takes the first `.profdata` it finds. This adds a coverage build and test run of about 1.5–2 min, so the net saving is about 9 min.
  3. **Trace reached switches.** Record which mutant switches the baseline run executes, and mark the rest "no coverage" without running them. This could later grow into a map from each mutant to the tests that reach it.

### 1.4 Do less work per run

The results file and `--resume` built most of the base for this. PR #38 added stable keys and provenance. PR #46 added each file's SHA-256, and reuse of a mutant's result when its file is unchanged. The estimates below include the 6.4 min of fixed setup.
- **Reuse results across runs,** as the PIT and Stryker mutation tools and `cargo-mutants --iterate` do.
  - Today a changed project file refuses a resume. `--resume-ignoring` can waive that, but then test-file changes are ignored.
  - **Still needed:**
    - reuse a "killed" result if its file and its killing tests' files are unchanged, and a "survived" result only if no test file changed;
    - start a new run from a finished one, rather than as a resume;
    - run a full run on a schedule, for example weekly, so old results don't drift.
  - **Estimate.** With 20 changed files, about 165 mutants run: 165 × 8.1 s / 4 + 382 s ≈ 12 min. If a test file changed, the 594 survivors and 9 timeouts run again too, as do the kills by tests in that file: at least 64 min.
- **`--since <ref>`, with an optional `--changed-lines`.** Mutate only the files, or the changed hunks, changed since a git ref.
  - A 5-file change is about 41 mutants and takes about 8 min, of which 6.4 min is setup.
  - Until then, passing the changed source files to `--files-to-mutate` (`Run.swift:10-11`) does the file-level part, for example from `git diff --name-only --relative <ref> -- '*.swift'`. Filter out tests and manifests first: `--files-to-mutate` skips the exclude list (`DiscoverSourceFiles.swift:18-27`), so a test file or `Package.swift` in the list would be mutated.
- **CLI overrides.** Add `--workers N` and `--timeout S`, so wrappers don't need a YAML file for each run.
  - A changed `mutationTestWorkers` doesn't stop a resume, but a changed `mutationTestTimeout` does (`ResumeCheck.swift:48-56`).
  - The effective limit worked out from the baseline isn't compared (`:41-45`), so a `--timeout` override must be recorded and compared as that key is.
- **`--shard k/n`.** Split the mutants deterministically by a hash of their key, so that two machines each run half.
  - Each half takes about (5,438 − 382) / 2 + 382 s ≈ 48 min, which is 1.9× faster.
  - `report` reads one results file (`Report.swift:12-13`), so it needs to learn to merge them.
- **`--sample N --seed S`.** Run a random subset for trend checks. 500 mutants take about 23 min and give the score to ±3.4 points (95% confidence).
- `--since`, `--shard` and `--sample` change which mutants run. So each one must be recorded in the results file's header and compared by the resume check (`ResumeCheck.swift:91-98`). Otherwise a resume could reuse results from a different selection.

### 1.5 Experiments

- **Release-mode tests.** Try `arguments:` with `-c release -Xswiftc -enable-testing`.
  - Since PR #42, most of each mutant's 8.1 s is test work, so release mode has more to act on than when this was first proposed.
  - The project's build and the clones' builds get slower, which adds to the setup.
  - Unmeasured.
- **Worker count.** Try 2, 3, 4 and 6 workers. Each worker's Swift Testing run is already parallel, so expect 10–20% at most, about 9–18 min. Since fail-fast the workers no longer run in step, so only a measurement can settle it.

---

## 2. Losing or mis-scoring a run

### 2.1 Results file, `report`, `--resume` and interruptions: what's left

All four items are done (PRs #38 and #44–#46). These were left out of them:
- **`--resume`.**
  - It can't retest timeouts under a longer time limit. A changed `mutationTestTimeout` refuses the resume (`ResumeCheck.swift:48-56`). Of the recorded outcomes, only build errors are always retested (`ResumePlan.swift:88-89`), so a timeout is kept like any result whose file and mutation are unchanged.
  - A test-plan run can't be resumed: `run-without-mutating` has no `--resume` (`RunWithoutMutating.swift:20-31`).
  - Only the results file is locked (`ResultsFile.swift:64-66`), not the project, so two runs of one project can overlap.
  - A resumed session's log folder doesn't point to the results file.
  - When the results file is locked, the refusal names the previous session's writer, not the process holding the lock (`LoadResumeState.swift:26-35`).
  - A resumed session writes its header and its `retired` line separately (`PerformMutationTesting.swift:637-640`). A SIGKILL between the two leaves `report` showing stale results until the next session. Nothing is wrongly reused, because the plan checks the hashes again.
  - A refused resume leaves an empty log folder, and refusals have no exit code of their own.
  - `report` of a resumed run's file doesn't say how many results came from earlier sessions. Its status line gives only the count and how the last session ended (`RecordedResults+Status.swift:6-22`).
  - A results file from before PR #46 can't be resumed.
  - The header grows by about 205 KB for each session.
- **Interruptions.**
  - If SwiftMutator itself is killed with SIGKILL or crashes, its test processes are left running, and the next run's cleanup (`PreviousRunCleanUp.swift`) doesn't kill them.
  - Ctrl-Z suspends SwiftMutator, but its tests keep running. Their time limits keep counting but can't fire. So after `fg`, every run whose limit passed in the meantime is stopped at once, and can be recorded as a timeout even if its tests had finished.
  - Under xcodebuild, the simulator's test hosts aren't SwiftMutator's descendants, so they aren't killed.
  - A forced exit, by a second signal or the 30 s watchdog, writes no end line.
  - SIGQUIT keeps its default action.

### 2.2 Killing tests: what's left

Items 1–3 are done. PR #38 records each mutant's failing tests, and PR #47 shows and summarises them and flags suspect tests. Left:
- **Item 4, a control job.** Every so often, run the suite with no mutant active, under the same load.
  - Mark tests that fail in it as flaky, and kills by only those tests as suspect.
  - One control run per 100 mutants would cost about 2% of the run.
  - It would also make possible comparing how often a test fails alone with how often it fails beside others. That needs complete failure lists, which fail-fast prevents.
- **Gaps in the suspect rule.**
  - When the passing baseline printed a line that looks like a failure, no mutant records its failing tests (`ResultsRecords.swift:276-277`), so the reports name none.
  - The rule misses a test that fails in fewer than about 3% of runs, or about 5% when runs stop at their first failed test. That's worth about 1 point at most; 0.16 points was measured.
  - Its thresholds (`KillingTestSummary.swift:4-10`) are calibrated on SwiftProjectLint alone. Check them on a second project, and perhaps make them configuration keys.

### 2.3 Same-named files: what's left

Discovery has merged mutants by full path since PR #25. Deferred:
- **Path-qualified mutant IDs.** The ID is built from the file name only (`MutationSchema.swift:6-12`), so same-named files' mutants can share a switch variable.
  - Build it from the repo-relative path, or a short hash of it, plus the operator and position.
  - About 16 test files contain the ID format: 10 snapshots and 6 test files. The change also invalidates existing test plans.
  - `--resume` never compares IDs, so it's unaffected.
- **Kept-log names.** They're built from the operator, file name, line and column (`MutationTestLog.swift:14-20`), with no folder and no occurrence number.
  - So same-named files, and repeated mutants at one place, overwrite each other's kept log. The results file's `log` field then points both mutants at one file.
  - The raw log each test process writes has the same flaw. It goes in the `_mutated` folder, which every worker shares, as `<file name>_<operator>_<offset>_<line>_<column>.log` (`PerformMutationTesting.swift:611-615`, `MutationTestingIODelegate.swift:379-388`). Repeats are tested next to each other, so two can run at once and write one file, which fail-fast's follower also reads. Their code is identical, so a verdict is unlikely to change.
  - Log folders are named to the minute (`fileOperations.swift:35`). So two runs or sessions started in the same minute share a folder, and a retested mutant's log overwrites the earlier one.
- **Order within a file.** Mutants are sorted by their ID as text (`MutationSchema.swift:92-99`): by operator, then by line as text, so line 10 comes before line 9.
  - Sorting by line, column and offset means updating `JobOrder` too (`RecordedResults+Outcome.swift:3-16`), which `report` uses to rebuild the order, and the test that pins discovery's order.
- **Compiler errors.** `CompilerError.first` (`MutationTestingAbortReason.swift:128-138`) matches compiler errors to files by name, so with same-named files a failed baseline's message can name the wrong one.

### 2.4 Discovery mutates files that no build target includes

- **What happens.** `DiscoverSourceFiles.swift:67-90` walks every path in the project and filters only by the exclude list and the `.swift` suffix. So files outside every target, such as SwiftProjectLint's `ExampleCode/` and `.swiftinfer`, get mutants that can never be killed. Coverage doesn't drop them either, because a file outside every target is never reported as uncovered.
- **Fix.** For SwiftPM, build the candidate list from `swift package describe --type json`, or at least skip hidden and git-ignored paths. `ProjectTree.swift:302` already asks git for that list, for the resume check.

### 2.6 One uncompilable mutant switch aborts the whole run

- **What happens.** A compile error in any of the ~300 rewritten files fails the baseline (`PerformMutationTesting.swift:168-200`). That ends the run after the copy, discovery and a ~95 s baseline. Stryker puts the offending mutants back instead, and cargo-mutants and mull mark them "unviable". The multi-line string bug under [Open bugs](#open-bugs) is one way to hit this today.
- **Proposal.**
  1. Make the build of the mutated project its own step. For SwiftPM it happens inside the baseline test run today.
  2. On failure, match each compiler error's path to a rewritten file, by full path in the copy, and restore that file from the original project. `CompilerError.all(in:)` (`MutationTestingAbortReason.swift:141-143`) already parses the errors.
  3. Record its mutants as "unviable", left out of the score but listed in the report.
  4. Rebuild incrementally, and repeat for a few rounds.
  5. Always print a loud warning naming the files that were dropped.
- **Effect.** Losing a handful of mutants, about 8 here, instead of all 2,497.

### 2.7 Timeouts and the score

PR #27 fixed truncated logs, fractional time limits and identical statements. A timed-out run counts as killed if its log already shows a failure summary or XCTest's `Test Case '…' failed (` line (PR #22). Since PR #36 it also counts if the log shows Swift Testing's `✘ … recorded an issue` line, unless the passing baseline printed such a line. Left out by choice, and still open:
- **The default time limit is very loose.** It is 3 × the baseline's build plus test, measured with nothing else running (`PerformMutationTesting.swift:221-223`).
  - On 6 October that was 286 s, about 17 times a survivor's whole suite under load.
  - Now that most runs stop early, timeouts weigh more. The 9 timeouts took 9 × 286 s, 12.7% of all worker time.
  - A limit based on test time, such as 60 s, would save about 9 × (286 − 60) / 4 s ≈ 8.5 min.
  - Timeouts already count as survivors, so a tighter limit can't raise the score. It can only turn a late kill into a timeout.
- **Plain timeouts count as survivors** (`mutationScoring.swift:6-7`). Decide whether to count them as killed, or to leave them out of the score.
- **The score is truncated, not rounded** (`mutationScoring.swift:13`). Muter's README, kept as `Docs/Muter-README.md` and linked from `README.md` for the configuration options, says killing 50 of 75 mutants scores 67% (line 92). The code gives 66%. Either:
  - round. That moves every score that uses `mutationScore`, including the score without suspect tests. It also changes the test at `KillingTestSummaryTests.swift:367-368`, and perhaps report snapshots; or
  - change the README to 66%.

## Open bugs

- **A mutant switch inside a multi-line string's interpolation can fail to compile.** PR #53 starts a branch's `}` on a new line when the branch's last line ends in a `//` comment or `#endif`.
  - **When it fails.** Take a closure inside a `"""` string's `\( … )` whose first statement is on the `{` line. The new line starts at column 0, which is less indented than the closing `"""`, so it fails with "insufficient indentation". It failed on `main` before PR #53 too, because the comment swallowed the brace.
  - **Fix.** Indent the `}` like the source line it follows. That indentation is part of the string's text, not trivia, so it's rare enough to leave for now.
- **`TokenAwareVisitor`'s own edit range is redundant, and fragile (S).**
  - Its `transform` override (`TokenAwareVisitor.swift:68-97`) ends the edit at the mutation's length in Characters.
  - Every relational and logical mutation today has the same length as its operator, so it matches the position lookup that PR #31 added to the base class. A scratch comparison on ASCII, emoji and CRLF sources gave identical results.
  - A longer replacement would run past the operator, so the override must go before boundary mutants (§4).
  - Delete it and its helper, then `String.convertToCharOffset` and its test.
- **No CRLF test for the reparse fix (S).** PR #49 fixed CRLF files as well as multi-byte text, but none of its five tests uses CRLF line endings.
  - A failing-first test needs more CRLFs before the mutation than its distance from the start of its statement.
  - About 20 `x()` lines joined by `"\r\n"`, before `let ok = a && b`, gave an unchanged mutant before PR #49 and `a || b` after.
- **Waiting for a test process can hang.** `exited()` (`MuterProcess.swift:42-49`) calls `waitUntilExit()` on a GCD thread.
  - Reviewers of PR #36 saw that call never return, but only for a process without a `terminationHandler`.
  - Every test process now has one, and the hang hasn't been seen in SwiftMutator.
  - Having `exited()` resume from the handler (`MutationTestingIODelegate.swift:243`) would be sturdier.
- **Workers share the user's `UserDefaults`.** Tests that write fixed keys in `UserDefaults.standard` can overwrite each other's values across workers. That gave SwiftProjectLint 4 false kills on 2 October.
  - No SwiftMutator-side fix is known. `CFFIXED_USER_HOME` doesn't isolate `UserDefaults` on macOS 27, and it also moves `NSHomeDirectory()`, which breaks the swiftly proxy.
  - The fix belongs in the project's tests (see [Outside this repo](#outside-this-repo)).

---

## 3. Watching a run and using the report

- **Progress output in a log file (S).**
  - The progress bar always writes cursor-movement codes (`ProgressExtensions.swift:86-93`). Nothing checks whether stdout is a terminal.
  - stdout is block-buffered, so a SIGKILL, a crash or a hang loses the end of the output, and a `| tee` reader sees lines late. Since PR #44, a stop by signal flushes it.
  - There are no timestamps. Today `tail -f results.jsonl` gives a timestamped record instead, because each result has a `finishedAt` and is written as it finishes.
  - The finish estimate (`ProgressExtensions.swift:16-18`) multiplies the time since the last redraw by the number of mutants left, so with 4 workers it swings wildly. Base it on the average rate: time since the first mutant started ÷ mutants finished × mutants left. PR #46 fixed only the estimate shown before the first mutant finishes.
  - Two small bugs come from Muter:
    - the estimate's plural is the wrong way round ("1 minutes", "5 minute"; `ProgressExtensions.swift:24`);
    - the bar runs one mutant ahead and reaches 100% a mutant early (`Progress.swift:27`, `Logger.swift:243`).

  Instead, when stdout isn't a terminal, print one timestamped, flushed line per mutant. For example: `[13:13:25] 1103/2497 (44%) killed 837 survived 262 … | 2.0 s/mutant | ETA 0h47m`. Collapse the file listings (`Logger.swift:91-118`) unless `--verbose` is given.
- **Reports.** They have shown each mutant's killing tests since PR #47. Still to do:
  - List survivors first. The plain report groups mutants by file in the order they ran, and the HTML report sorts them by file name.
  - Show the repo-relative `path:line:col`. The plain and HTML reports show `fileName:line`.
  - Show the original source line, before → after. The HTML and JSON reports show only the mutation's snapshot, never the whole line: the operator for relational and logical mutants (`<` → `>`), the removed statement for RemoveSideEffects, and the ternary for SwapTernary. The plain report shows no change at all.
  - Show each mutant's duration. Today only `results.jsonl` has it.
  - Add each mutant's repo-relative path and key to the JSON. Its paths point into the `_mutated` copy today.
  - Write a `summary.json` with the score, the counts by outcome and the wall time.
  - Never colour report files. Today `-f plain -o report.txt`, run from a terminal, saves colour codes in the file (`ReportWriter.swift:8-14`).
  - Say "coverage skipped" when coverage was skipped. The plain report says SwiftMutator "could not gather coverage data" either way (`PlainTextReporter.swift:79-82`).
- **Provenance in reports.** The results file's header records:
  - the SwiftMutator build, as its executable's SHA-256 rather than a commit;
  - the toolchain;
  - the configuration;
  - the worker count;
  - the time limit.

  Each mutant's line has its key, switch ID and duration. The reports show none of this; they should at least name the results file. Nothing compares two runs mutant by mutant yet.
- **Exit codes.** Add `--fail-under <pct>` or `scoreThreshold:`, with distinct exit codes for "below threshold", "timeouts", "baseline failed" and "aborted".
  - Today a finished run exits 0 whatever its score.
  - A stop by signal ends SwiftMutator by that same signal, so a shell reports 128 + its number (130, 143 or 129). A wrapper that reads the wait status sees a signal, not an exit code.
  - Every other failure of a run exits 255, a refused resume included. A usage error exits 64, and `report` exits 1 when it can't read its file.
- **Log storage.**
  - Each mutant's log is written twice. The test process writes it into the `_mutated` folder (`MutationTestingIODelegate.swift:379-394`), and then it's copied to `<project>_muter_logs` (`MutationTestObserver.swift:208-228`). Write it once.
  - Kept logs are never removed. On this machine, SwiftProjectLint's log folder holds 15 runs and 2.4 GB.
  - Keep full logs only for survivors, crashes and timeouts. That needs the results file's `log` field to become optional.

---

## 4. Repo health

- **CI follow-ups.** CI is done (PR #24). Not done:
  - a nightly or on-demand regression run. `workflow_dispatch` reruns only the unit tests;
  - a SwiftLint job, which can go in as it is: `swiftlint lint` passes on `main`;
  - caching `.build`;
  - required checks: `main` has no branch protection or rulesets.
- **`make build` cleans every time.** It starts with `swift package clean` (`Makefile:9`), and `run`, `acceptance-test` and `regression-test` depend on it. Keep the clean in `make clean` only. `mutation-test` also removes `.build` first (`Makefile:43`).
- **Type-check more of the generated code.** `GeneratedEnvironmentCacheTests.swift:87-141` compiles a rewritten file with `swiftc`: in Swift 6, with warnings as errors, and under default `MainActor` isolation. But it covers only one `value > 1` mutant. Not covered:
  - result builders
  - opaque non-builder bodies
  - file-scope `#if`
  - `main.swift`
  - ternaries containing longer expressions

  The test's helper could take the source as a parameter. Fixtures like these would have caught three of the four rewriter bugs fixed just before the review.
- **Real-process tests.** Still missing:
  - a real process tree that outlives its time limit, checking that the outcome is a timeout and nothing survives (today's timeout tests use stand-ins);
  - one real log from SwiftProjectLint's three test bundles, as a fixture.
- **Upstream Muter leftovers.** The update check and version 0.1.0 are already SwiftMutator's own. Left:
  - The banner's help link and three error messages point at Muter's issues (`Logger.swift:24`, `RunCommand.swift:48`, `MutationTestingAbortReason.swift:41` and `:76`).
  - The baseline-failure messages still call the tool Muter (`MutationTestingAbortReason.swift:68-99`).
  - `CONTRIBUTING.md` is still Muter's text: its title, pinned issues, "fork Muter's repository", `master`, and Muter on your `PATH`. Only its CI and `swift test` notes were updated.
  - The toolchain setup (swiftly, and `SDKROOT=…/MacOSX26.5.sdk` for Swift 6.3.3) isn't documented for contributors.
  - The release tooling is Muter's.
    - `make release` runs `Scripts/shipIt.sh`, which hashes Muter's release archive and builds a Homebrew formula for Muter.
    - `Scripts/bump_version.py` and the `homebrew-formulae` submodule point at Muter too.
  - The update check calls GitHub's API on every run that isn't given `--skip-update-check` (`swift-quality` passes it). SwiftMutator has no releases, so the check can never find one. Cut a release, or make the check opt-in.
- **Swift 6 readiness.** Since PR #36, waiting for a test process no longer blocks a pool thread. Left:
  - global mutable dependency injection (`World.swift:6-10`);
  - other blocking waits reached from async steps:
    - discovery's semaphore and group waits;
    - `waitUntilExit` in `FoundationProcess.swift:29`;
    - the clone's `cp`;
    - the `git` listing;
  - an untyped NotificationCenter bus;
  - Swift 5 language mode: the package's tools version is 5.9.
- **Better relational-operator mutants.** Today `<` and `>` are swapped, which almost any test kills. Boundary mutants (`<` → `<=`, `>` → `>=`, and so on) would expose missing edge-case tests.
  - Done in place, the count stays at 218 here.
  - As a separate operator, they would add 218 mutants, about 7–15 min.
  - Remove `TokenAwareVisitor`'s override first (see [Open bugs](#open-bugs)).
- **xcodebuild projects.** These always test one mutant at a time, without fail-fast (`MuterConfiguration.swift:100-111`). The per-worker copies used for SwiftPM could cover them too, with a cloned simulator per worker.
- **Spotlight.** It indexes the copies and logs under `~/xcode_projects`. SwiftMutator names those folders itself (`_mutated`, `_muter_logs` and `_worker<n>`), so it could add `.noindex`. The benefit hasn't been measured.
  - Only the steps that make the folders (`CreateTempDirectoryURL.swift:21`, `fileOperations.swift:41`, `PerformMutationTesting.swift:730`) and the cleanup (`PreviousRunCleanUp.swift:28`) use their names. `report` and `--resume` use the path they're given and the paths in the results file.
  - Outside this repo, `swift-quality` removes `${repo}_mutated` by name, so it would need to change too.

---

## 5. Example tests and property tests

Added on 7 October, from a discussion of using property-based tests (PBT) alongside mutation testing. Not in the suggested order: it's a feature, not a fix, and its first step only reads existing results.

- **The idea.** Report which kind of test kills each mutant, so the score can be split by kind. It can also show how much each property constrains the code: mutants make a measure of a property's strength.
- **What exists.** Each `mutant` line in `results.jsonl` has `killedBy`: each failing test's name and `file:line:col`, at most 20 (`ResultsRecords.swift:219-221`, `FailedTestLine.swift:95`). A test's file or suite can mark it as a property test, so no new recording is needed to start.
- **Measures worth reporting.**
  - **Kills only by examples, only by properties, and by both.** A property's value is the mutants that only it kills. Two separate scores, one for examples and one for properties, overlap and hide this.
  - **Kills per property, and kills only that property makes.** A property that kills many mutants may just be broad, for example a round trip through the whole pipeline. The unique count says more.
  - **The same denominator as the headline score.** All tested mutants, timeouts included (§2.7), so the split adds up to the headline.
- **Measures to leave out.**
  - **"It survived a property too, so it's not a test gap."** A survivor that passes a property only shows that the property doesn't constrain that change. It's evidence of equivalence only when the properties fully specify the behaviour, as "ordered" plus "a permutation" do for a sort. Most code has no full specification, so a mutant that survives both kinds is as likely a gap in both.
  - **A score over "non-equivalent" mutants.** Equivalence can't be decided automatically. Until survivors are triaged by hand, and the triage stored by mutant key so it carries across runs (§1.4's reuse uses the same keys), such a score is the headline score under another name.
  - **A fixed target, such as 80%, or "no regressions".** These are policy choices, not standards. A "no regressions" check also needs a tolerance: SwiftProjectLint's score moves a point or two between runs from test noise alone (see [Outside this repo](#outside-this-repo)). It needs `--fail-under` and a run-to-run comparison too (§3).
- **The catch: fail-fast.** A run stopped at its first failed test records only that test (§2.2). So an example test that fails first hides any property test that would also have killed the mutant, and "both" and "only by examples" can't be told apart. Options:
  1. Run with `stopAtFirstFailure: false`. Every kill is then complete, up to the 20-test cap. But fail-fast cut run time by 37% in PR #41's A/B, so turning it off makes a run about 1.6 times as long.
  2. **A second pass over killed mutants, running only the property tests,** with fail-fast on. It needs property tests to be selectable by name, for example in their own suites, since `swift test --filter` selects by name. This costs one property-suite run per killed mutant whose recorded killers include no property test. Property tests run many inputs, so this is unmeasured.
  3. Report only what fail-fast recorded, and say the property counts are lower bounds. That's free, and enough for a first look.
- **Steps.**
  1. In `report`, take a pattern for property tests (a file or suite name) and print the split and the per-property counts from `killedBy`, as lower bounds when runs stopped early. No change to runs.
  2. Option 2's second pass, if the lower bounds are too loose to be useful.
  3. Triage labels for survivors (missing test, equivalent, out of scope, tool limitation), stored by mutant key, and shown in reports.
- **Elsewhere.** SwiftInferProperties infers properties. This would measure how much they constrain the code.

---

## Checked and not worth doing

- **One mutant per line.** On 2 October, 2,478 inserted mutants sat on 2,205 lines, so a cap would save at most 11%. That was before PR #25 inserted every mutant, but that run's 2,487 logs give the same 11%.
- **One long-lived test process for many mutants.** PR #13's per-process environment cache, and other static state that persists between mutants, make this unsafe.

## Suggested order

1. **`TokenAwareVisitor`'s override,** with the CRLF test for PR #49. Both are small, and the override must go before boundary mutants (§4).
2. **A default time limit based on test time** (§2.7). It's the cheapest speed-up left, about 8.5 min.
3. **Progress output** that works in a log file (§3).
4. **Coverage** (§1.3). It saves about 11 min, and stops counting code that no test runs as survivors.
5. **Unviable mutants** (§2.6), so that one bad mutant can't cost a whole run.
6. **`--since`, reuse and `--shard`** (§1.4), for runs on a change rather than the whole repo.

## Outside this repo

- **Upstream Muter.** The fixes in PRs #25, #27, #49 and #52–#55 also apply to upstream Muter at `7f1f258`, and PR #26's once muter#309 and muter#312 are in. Each PR's body says how to port it. They're held until upstream's CI is green again.
- **`swift-quality`.**
  - It prints `swift --version` before it changes into the project folder (lines 75 and 80 at dotfiles-claude `cf472b0`), so its header can name the wrong toolchain.
  - Add start and end timestamps to `summary.txt`.
  - Exclude `ExampleCode/` and `.swiftinfer`, until §2.4 is done.
  - Copy the "Mutation Score without suspect tests" and "Suspect tests" lines into `summary.txt`. Anchor the killed-count `grep` to the line that starts "Of the".
- **SwiftProjectLint.**
  - Skip, or rewrite, the wall-clock timing test in `ProjectLinterTests.swift:98` for mutation runs.
  - Sort the files that `PrimitiveNamedForDomainTypeVisitorTests.analyze(files:)` walks. It walks a Dictionary in hash-seed order, so two `RemoveSideEffects` mutants in `PrimitiveNamedForDomainTypeVisitor.swift` (lines 77 and 105, each `typeNameStack.removeLast()`) are killed in only about 75% and 50% of runs. The score moves by a point or two from run to run.
  - The same applies to `runOnceContractRule` in `OnceContractViolationTests`. It walks a `[String: SourceFileSyntax]` dictionary, so two `ContextSymbolTable.swift` mutants (lines 96 and 98) are killed only when the conflicting declarations come in one order.
  - `everyFormatRendersTheSameBytesForAnyArrivalOrder` renders a reference report once, then compares each shuffled render against it. `HTMLFormatter` prints the current time to the minute (`Generated … at h:mm a`), so when a minute boundary falls between the reference and a later render, the test fails whatever the mutant.
    - On 6 October that gave 3 false kills, and named the wrong killing test for a fourth mutant.
    - Fix: let `HTMLFormatter` take its date, for example `init(now: @escaping () -> Date = { .now })`, and pass a fixed one in the test. Or leave the timestamp line out of the comparison.
  - Several App tests write fixed `UserDefaults.standard` keys, such as `enabledLintRules` and `uec.harness.flag`. Under 4 workers they interfere with each other (see [Open bugs](#open-bugs)).
    - Fix: give `ContentViewModel` an injected `UserDefaults`, and give `@AppStorage` a `store:`.
    - Each test should create its store with a unique suite name, such as a UUID, and remove that domain afterwards. A fixed suite name would still be shared by all 4 workers.
