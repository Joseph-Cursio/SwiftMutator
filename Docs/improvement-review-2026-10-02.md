# SwiftMutator improvement review: open items

This started as a ranked review of SwiftMutator on 2 October 2026, at commit `4ba72fc`, after PR #13 (the cached-environment speedup). On 7 October, at `44c1b41`, the finished work was taken out. Every remaining item was checked again against the code, and its line references and estimates brought up to date. On 21 October each open item was filed as a GitHub issue, linked beside it, and the gaps found by comparing SwiftMutator with swift-mutation-testing were added as [§6](#6-gaps-found-by-comparing-with-swift-mutation-testing).

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
  - `TokenAwareVisitor`'s own edit range, which dropped a combining mark after the operator and would have cut short a longer replacement, and a CRLF test for the reparse edit (PR #56).
  - A default time limit based on a timed test run, for SwiftPM projects (§2.7, PR #57).
  - The progress bar's count, which ran one mutant ahead and hid the first estimate, its time left, which swung by 100×, its wording, and its redraw, which left stale text on screen, a whole line per redraw in an 80-column terminal (§3, PR #58).
  - Progress in a log file: a flushed, timestamped line per mutant when stdout isn't a terminal, and the file listings only with `--verbose` (§3, PR #59).
  - Coverage with several test bundles: one `llvm-cov` export over every bundle, uncovered files named by their path in the project so discovery leaves them out, the reason a coverage run failed, and one location converter per file, without which discovery with coverage took 29 s instead of 2 s on SwiftProjectLint in a release build, and minutes in a debug build (§1.3, PR #60).
  - Coverage counts lost to tests that run at once. Counting a run of some code loaded its counter and stored one more, so code running on two threads at once lost runs, and a count worked out from two others could read 0 though the code ran, which left its mutants out. The coverage run now makes the counters atomic. On SwiftProjectLint that removed 91 of the 93 negative counts in its plain Swift, for a test run of 9.3 s rather than 7.2 s. Running the tests one at a time took 11.4 s and kept 67.

  - Bugs found while comparing SwiftMutator with swift-mutation-testing, and in review (PR #61).
    - `exclude` globs never matched anything. Pathos expanded them on disk to full paths, which were compared with relative ones, and the test pinned that. They're now matched against each file's path in the project, with `**/` for any number of folders, none included.
    - xcodebuild coverage's build folder was the whole `BUILD_DIR = …` line, and could be the unexpanded `BUILD_DIR=…` of the arguments.
    - With the folder right, the coverage profile was the first that `find` listed. Xcode leaves other destinations' profiles in place, and a stale one reads every function added since as never run, so their mutants were skipped. It's now the newest.
    - The regex helpers searched a range counted in Characters, not UTF-16 units, which cut the end of the text off after an emoji, a decomposed accent or a CRLF.
  - The active-mutant file, which tests could see at the root of each worker folder. It's now beside the folder, as `<folder>.active-mutant` (§1.1, [#63]).
  - The coverage check, which looked only at the nodes around a mutant, and only on visiting them. So a mutant in code no test ran was tested, and survived, when its region was smaller than every node around it, as the right-hand side of `a && b > c` is, or when RemoveSideEffects removed a statement before visiting the body that held it: of a function no test called, or of a `guard` or loop that never ran. Each mutant is now checked by the node it changes instead. That also keeps the mutants in a local function's or type's code that ran, which can run before the code that declares it, and lets a `muter:disable` or `muter:enable` tag in code no test ran take effect. On SwiftProjectLint `c2082e5d`, discovery leaves out 47 more mutants. In the [trial](smt-trial-2026-10.md)'s run, 46 of them survived and a test that doesn't reach the other killed it (§1.3, [#65]).
  - Coverage counts in result builders. Swift works out the count after an `if` from the count at the end of each branch, and in a result builder it reads that count from an earlier block. So the code after an `if` that was never true counted as never run, and an `else` that never ran could count as run. Discovery now works those counts out again from the ones Swift counts directly, by walking the syntax as Swift's coverage does, and keeps llvm-cov's count where it can't. Code that holds code of its own function that Swift counts directly and that ran, such as a branch, or a closure made there, ran too, but for a `case`'s pattern and `where`, tried for each value, and a `repeat` loop's condition, run after each pass, which say nothing of the case's body or the code after the loop. A count the walk can't work out is llvm-cov's, as main had it, but for the code in a region that reads 0, as the code after a builder's `if` that was never true does: a count there can come from a stale one, too low or too high, and says nothing, so that code ran only if code in it that Swift counts directly did. That holds in code there that Swift counts directly and that ran, as an `if`'s then-block or a closure, too, since a builder's counts after it are as stale. In plain code the walk gives llvm-cov's own counts, but for four places where Swift's are wrong in any code, which it corrects: after a `repeat` loop left by `break` or `continue`, in a `repeat` loop's condition when its body threw, which Swift counts as run, after a call in a `case` pattern that threw, and after a call in a `for` loop's `where`, which gets the count before the loop, too high when the `where` threw for every first element. Apart from those and closure literals, whose own count it uses for the code in their bodies, and that of the code that makes them for their capture lists, the two agree on SwiftMutator's, SwiftIdempotency's and SwiftProjectLint's regions, but for one where a lost update left llvm-cov's count 0 though a `case` in it ran. In a builder the walk can't follow what a call threw when it ends inside a `try?` or a ternary's branch, or is in an `else if`'s condition, nor more than 50 chained ternaries or 200 nested expressions, so the code there keeps llvm-cov's counts. Nor can it read what a `try` threw where llvm-cov shows both counts it would read that from as negative, as after a builder's `if` that was never true, or after a `repeat` loop left by `break`: the code after the `try` then counts as never run unless code in it that Swift counts directly ran, though it did run if the `try` threw only some of the time. Discovery leaves out the RemoveSideEffects mutants there, which main kept, since it checked only the function that held them. In a probe of builder shapes, discovery kept 85 mutants in builder code that ran, and one in code that didn't. It now keeps 183, all in code that ran (§1.3).
  - Tests that fail only under coverage. SwiftPM merges the test processes' profiles only when every test passes, so one test that failed under coverage cost all of it. Each process still leaves its own, so after a run in which tests failed, SwiftMutator now merges them itself and warns, naming up to 5 of the tests, that code a failed test would have run after it stopped reads as never run. It doesn't when a test process crashed, or stopped before its tests finished, as one the system kills for its memory does without a line from SwiftPM: that process left no profile. Nor when no failed test is named, as when the build fails, which leaves an earlier run's profiles in place. Each of those now says what happened, where every one read "the tests with coverage on failed (exit status 1), and SwiftPM saves no coverage then", and the coverage run's output is kept as `coverage run.log` in the log folder, even when the run is stopped (§1.3, [#67]).
  - A time limit for the coverage run: `buildTimeout`, from [#117]'s proposal, in seconds, with no limit by default. Past it the run is killed with every process it started, and mutation testing goes on without coverage (§1.3, [#67]).
  - Coverage on Linux. Swift Build makes a `<target>.so` and a `<target>-test-runner` for each test target there, and coverage now reads each `.so`, where it found no test bundle before, and the native build system's bundle as it is. llvm-cov and llvm-profdata are the toolchain's, next to the test command, as SwiftPM's are, before any on `PATH`. Both platforms' code is tested on macOS, and the layout and the merge were checked in Docker's `swift:6.4-noble` image (§1.3, [#67]).
  - xcodebuild's coverage threshold and percentage. `coverageThreshold` was compared with xccov's share of a file's lines, from 0 to 1, so any threshold of 1 or more left out every file. It's a percentage now, as SwiftPM's is, and on both a file's share is worked out from its line counts, so a file exactly at the threshold is left out: llvm-cov's and xccov's own shares of 7 of 100 lines come out just above 7. The project's percentage was the first target's but the tests', in name order. It now counts the lines of the project's own files in every target but the tests, as SwiftPM's does, so the packages the project depends on no longer count, nor show their files as having no coverage, and the files that have none are named by their path in the project. On SwiftLintRuleStudio's last report that reads 72%, where it read 0%, and counting the packages' lines too would give 59%. Nor do the files in derived data that `-derivedDataPath` puts in the project count, and a report that names none of the project's files gives no coverage, as on SwiftPM, rather than 0% (§1.3, [#67]).
  - xcodebuild's regions and failed tests. Its coverage read regions from the one test bundle `find` listed, so with two it read none, and an app's hosted tests, a framework's tests and UI tests run code that only another binary maps. So a function no test runs kept its mutants. It now has the one `llvm-cov` export SwiftPM's coverage has, of every product xccov says the run built that exists, and of an app's `<App>.debug.dylib`, which holds the app's code in a Debug build. On copies of `Repositories/ExampleMacOSApp` and `FFCParserCombinator`, a function no test runs now loses its mutant. A file built into two binaries, as one an app shares with its extension is, reads as the copy the tests ran, and a universal build is read for this Mac's architecture. It also read the result bundle whatever happened to the tests. Xcode keeps the counts of every test process, a failed test's and even a crashed one's, so after tests failed the coverage is kept, with SwiftPM's warning naming them. But Xcode relaunches a crashed process without finishing the tests it was running, and in a probe that left 14 of 20 parallel Swift Testing tests unfinished, their code reading as never run. So after a crash, or a failed run whose failed tests SwiftMutator can't name, as with parallel testing, it goes on without coverage and says why. Its output is kept as `coverage run.log` too (§1.3, [#67], [#68]).
  - A resume that no longer discovers earlier results' mutants. Each session gathers coverage again, and if one session's failed and the other's worked, they test different mutants: a result whose mutant this session doesn't discover is retired, and nothing said so. A resumed run now warns, giving the count and, when it can explain it, the coverage change, such as coverage gathered in one session only. It also warns when the number of mutants discovered changed, as across a SwiftMutator that discovers differently. It never refuses: a kept result doesn't depend on coverage, and no flag could bring back the last session's (§1.3, [#67]).
  - A Swift package tested through xcodebuild. `-showBuildSettings` prints no settings for a package's scheme, so the profile wasn't found and no regions were read, and xccov lists only the tests' files, so coverage failed, saying xccov's report covered none of the project's files. The tests' bundle holds the library's code, so a package's files, lines and regions now all come from the one `llvm-cov` export of it, as on SwiftPM, leaving out the files xccov gives a test target, wherever it is. The profile is now the newest in the `Build` folders of the run's derived data, which the paths of its result bundle and its products show, and in the folder above `BUILD_DIR`, which a package's scheme has none of. Each can be the one that holds it. A package whose folder isn't named after it, as SwiftMutator's copy of a project isn't, has its products in derived data named after the folder, and its result bundle and profile in derived data named after the package. `SYMROOT` and `BUILD_DIR` move the products but not the profile, and Xcode's Custom and Shared Folder build locations move both, which can leave an earlier run's profile in the derived data. On a probe package, coverage now reads 33%, leaves out the two files no test runs, and keeps only the mutant in the function a test runs, where main kept all three. On copies of ExampleMacOSApp and FFCParserCombinator, on a framework with a local package, and on ExampleMacOSApp with a Custom build location, before and after a run with the default one, the coverage and the mutants discovered are unchanged (§1.3, [#69]).
  - The order of a file's mutants. They were sorted by switch ID as text, so each operator's came in turn, and line 10 before line 9. They now come by line and column, as numbers, then by operator, with repeats of one place and operator in the order discovery found them. `report` rebuilds that order from the results file by the same rule, never by the offset, which a kept result holds as an earlier session counted it (§2.3, [#85]).
  - Files that no target compiles. Discovery walked every path in the project, so an example app's files, or a tool's in a hidden folder, as SwiftProjectLint's `ExampleCode/` and `.swiftinfer` are, got mutants no test could kill, which counted as survivors. When the test command is `swift`, discovery now takes the Swift files of the tested package's targets from `swift package describe`, of the package `--package-path` names or the one in the project's folder, and those of the local packages in the project that it depends on, leaving out test, plugin and snippet targets, before the exclude list and coverage apply. A file that describe lists through a link to a folder is taken where it is, once, and left out if that's outside the project, where mutating it would change the user's own file. If describe fails or finds a package in a folder above, if `--package-path` names a package outside the project, or if `buildSystem: swift` is set for an executable that isn't `swift`, discovery says why and walks the project. It forwards the test command's `--disable-sandbox` and manifest flags to describe, and describes the package at the project's root too when the tested package depends on it. The walk, which other build systems use, skips hidden files and folders, and the paths git ignores when git lists the project. With an empty `exclude`, in place of the entries BonMot's configuration has for its example app's four files, discovery now finds the library's 33 files and none of the app's (§2.4, [#86]).
  - A mutant switch in a closure inside a multi-line string's interpolation. When a branch's last line ends in a `//` comment or `#endif`, its `}` starts on a new line (PR #53). That line had only the statement list's leading trivia, which is empty when the first statement shares the `{` line, so the brace started at column 0. Each line of a multi-line string that follows a line feed, an interpolation's code too, must start with the closing `"""`'s indentation, so the file didn't compile and the build every mutant shares failed. The brace's line now starts like the branch's last line, or like the list's first line for a branch on one line, whose indentation can be the string's text rather than trivia. It takes that line's spaces and tabs and its line break, so a CRLF file keeps its line endings. A brace after a lone carriage return goes unchecked, like the line it copies ([#90]).
  - `#sourceLocation` directives in a statement list with mutants. Each mutant's branch holds a copy of the list, so the compiler read each directive once per branch. It takes a `#sourceLocation(file:line:)` that opens a location again, but not a `#sourceLocation()` that closes one when none is open. So after the first branch closed the location, every later branch failed to compile, the original's among them, and with it the build every mutant shares. The copies now drop their directives, at any depth: in closures, in `case` bodies, where a `case` left with no statement gets a `do {}`, and in the types they declare. A dropped directive's comments and line breaks stay. The compiler reads the list's directives once, in the original's branch. That branch now starts in the original's location: a copy that opened one used to leave it open there, in the baseline too. Code after a dropped directive in a mutant's branch takes the location in effect where the switch starts, so a test that checks `#fileID` or `#line` there can kill that mutant. swift-syntax parses a directive in an `#if` clause of a type's members as unexpected text, which can't be dropped, so a list that holds one keeps every copy's directives, as before.
  - A crash with many mutants in one statement list. Each mutant of a list is an `else if` inside the one before, and writing the rewritten file out recursed once per level. That ran on one of Swift concurrency's threads, whose stack is about 512 KiB, so about 520 mutants in one list in a debug build, or 4,500 in a release one, ended the run with a bus error after discovery. Each file is now rewritten on a thread of its own with a 64 MiB stack. Such a list is still slow to build, since each branch holds a copy of it: 400 mutants in a 200-line list came to 81,000 lines and 44 s of build. swiftc itself compiled 4,000 levels of `else if` and crashed on 8,000.
  - Waits that held a thread of Swift concurrency's pool. A test run waited for its process with `waitUntilExit()` on a GCD thread, which reviewers of PR #36 saw never return for a process without a `terminationHandler`. Commands (the coverage run, `swift package describe`, build-for-testing, `which`, `find`, the toolchain probe), the git listing and the worker clones' `cp` waited on a thread of the pool itself, for minutes in a coverage run, and discovery waited there on a semaphore for each file. Each process's `terminationHandler`, set before it runs, now records its exit and opens a latch that the run awaits without holding a thread, and discovery walks eight files at once in a task group. `runProcess` no longer hangs on a command that can't be started, and on Linux a long `ps` listing no longer deadlocks a kill ([#91], part of [#101]).
  - The untyped notification bus. The run's steps told the observer what happened through a NotificationCenter, with 28 names and an untyped object each, which the observer force-cast in seven handlers and dropped silently on a wrong type in twelve. Each but the one only `init` sent is now a case of a `RunEvent` enum carrying its own payload, sent to a hub the observer handles in one exhaustive switch. Delivery stays synchronous, as the report written before SwiftMutator exits and the tests that cancel a run from an observer rely on. NotificationCenter kept the observer alive for good; now it goes with its run. `swift-mutator init` said nothing, as nothing observed its events; it now prints its banner and where it wrote the file (part of [#101]).
  - The global mutable `World`. Tests replace `current`, the dependencies every step reads, while signal handlers, time limits, GCD queues and parallel workers read it from other threads, and nothing guarded it. It is now one `World` behind a lock, `Sendable` with everything it holds, and a `@Dependency` reads just its own key path under the lock. A release build still can't replace it. It stays one global rather than being passed in or made task-local, as [#101] proposed: signal handlers, timers and GCD queues inherit no task-locals, so in tests they would read the real dependencies. Tests now share what their injected closures change through a lock too, which ends the one race Thread Sanitizer found in the suite: parallel workers moving a test's clock at once (part of [#101]).
  - Swift 5 language mode. The package's tools version was 5.9, so the compiler checked nothing for data races. It is 6.0 now, and every target builds in Swift 6 language mode, where a race the compiler can see is an error. No static state is mutable, the values a step hands on are `Sendable` (a file's mutation mapping is now a value, not a class), and mutation testing's tasks capture only what they use. Where the compiler can't see that something is safe, a comment says why: a resume state's results file, used by one step at a time, and tests that wait for a step they run in a task of their own. Two blocking waits stay on purpose: removing the worker clones at the very end of a run, in a `defer`, and the moment SwiftMutator waits to exit by a signal ([#101]).

  Their write-ups are in [this file at `44c1b41`](https://github.com/Joseph-Cursio/SwiftMutator/blob/44c1b41/Docs/improvement-review-2026-10-02.md), except those of PRs #49 and #52–#61, which are in the PRs themselves.
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

### 1.1 Time before the test helper starts

The manifest recompile is fixed (PR #42). Left:
- **Fixed time per mutant** ([#62]). About 1.3–1.9 s still passes before the test helper starts. It goes on toolchain probes, loading the package graph, a resolution step on every run, and XCTest discovery. Each mutant runs `swift test <arguments> --skip-build` (`MuterConfiguration.swift:226-227`) and nothing more.
  - Removing all of it would save 2,497 × 1.3–1.9 s / 4 ≈ 14–20 min, so that is an upper bound.
  - One option is to capture the exact `swiftpm-testing-helper` command lines once, with `swift test --skip-build -v`, and replay them for each mutant. That saves only SwiftPM's planning time, not process start-up or test discovery.
  - `--disable-xctest` hasn't been tried. These runs have no XCTest tests, but `swift test --skip …` still starts `swiftpm-xctest-helper` on each test bundle to look for them. On a one-bundle probe that cost about 0.07 s per run; on SwiftProjectLint's three large bundles it's unmeasured. A project with no XCTest tests can add the flag to `arguments:`. SwiftMutator mustn't add it by default, because an XCTest project would then run no tests and every mutant would survive.
  - `--skip-update` was measured and made no difference.

### 1.2 Fail-fast: what's left

Fail-fast is done (PR #36), and on by default since PR #41. Left:
- **Stopping crash-only runs** ([#64]). The stop trigger matches only failed-test lines (`TestLogFollower.swift:62`). So a run that crashes without a failed test runs its remaining test targets, about 1–3 s each.
  - The crash pattern already exists (`TestSuiteOutcome.swift:96-106`). A run stopped this way must still score as a runtime error.
  - Only 30 kills on 6 October weren't stopped at a failed test. A crash in the first bundle still runs the other two, so this saves under a minute: at most 30 × 2 × 1–3 s / 4 ≈ 15–45 s.
- **Running quietly** ([#64]). Test processes write all their output to each mutant's log (`MutationTestingIODelegate.swift:426-427`). A quiet mode would cut the log volume (see Log storage in §3). It must keep every line SwiftMutator reads:
  - the `✘ … recorded an issue` and `Test Case '…' failed (` lines, which fail-fast, killing tests and the baseline check read;
  - the suite summaries, build-error lines and crash lines, which scoring reads (`TestSuiteOutcome.swift:50-56`, `:96-138`).

### 1.3 Skip mutants that no test reaches

Coverage works with several test bundles since PR #60. On SwiftProjectLint `20438f4d`, with its run configuration, it left out 14 files no test runs and 113 of 3,372 mutants (3.35%), before [#65] had it check each mutant too. If they survive, as all but 2 of the 93 such mutants did on 2 October, that saves about 8–11 min of a 4-worker run, depending on whether a survivor takes 16.8 s or the 22.6 s of a whole test run. The coverage step took 96 s there, on a warm build, and the baseline then rebuilds without coverage. Left:
- **Coverage builds in the project's build folder** ([#66]), so the baseline then rebuilds everything without it: about 75–145 s on SwiftProjectLint. A separate `--scratch-path` would avoid that, but breaks tests that run a product from `.build/debug`, as SwiftProjectLint's CLITests do. The CLI's coverage would go missing, and 2 mutants the tests kill would be skipped.
- **`buildTimeout` limits only the coverage run** ([#117]), not yet the baseline or the worker clones' builds.
- **An Xcode project's local packages** (no issue yet). xccov lists no files for a local package's library that an app or framework links, so the package's files count neither toward the percent nor as files without coverage. Their regions are read, so a function no test runs still loses its mutants. On a probe framework with a local package, the percent counts only the framework's lines, and the package's file that no test runs isn't left out. Taking llvm-cov's lines for the project's files that xccov names in no target, and xccov's for the rest, would fix it without changing the counts PR #133 checked.
- **xcodebuild with parallel testing names no failed test** that SwiftMutator reads: its lines are `Test case '…' failed on '…'`, the same for a crash. So a test that fails only under coverage costs all of it there, and the killing tests aren't named. Checked with Xcode 27.1 on macOS only; simulators don't run here.
- **Linux CI doesn't block** ([#130]). The job builds SwiftMutator and runs the unit suite on Linux, but fails for now: SwiftMutator doesn't compile there, and some tests assume macOS. Until it passes, it runs on pushes to main and by hand, not on pull requests.

### 1.4 Do less work per run

The results file and `--resume` built most of the base for this. PR #38 added stable keys and provenance. PR #46 added each file's SHA-256, and reuse of a mutant's result when its file is unchanged. The estimates below include the 6.4 min of fixed setup.
- **Reuse results across runs** ([#71]), as the PIT and Stryker mutation tools and `cargo-mutants --iterate` do.
  - Today a changed project file refuses a resume. `--resume-ignoring` can waive that, but then test-file changes are ignored.
  - **Still needed:**
    - reuse a "killed" result if its file and its killing tests' files are unchanged, and a "survived" result only if no test file changed;
    - start a new run from a finished one, rather than as a resume;
    - run a full run on a schedule, for example weekly, so old results don't drift.
  - **Estimate.** With 20 changed files, about 165 mutants run: 165 × 8.1 s / 4 + 382 s ≈ 12 min. If a test file changed, the 594 survivors and 9 timeouts run again too, as do the kills by tests in that file: at least 64 min.
- **`--since <ref>`, with an optional `--changed-lines`** ([#72]). Mutate only the files, or the changed hunks, changed since a git ref.
  - A 5-file change is about 41 mutants and takes about 8 min, of which 6.4 min is setup.
  - Until then, passing the changed source files to `--files-to-mutate` (`Run.swift:10-11`) does the file-level part, for example from `git diff --name-only --relative <ref> -- '*.swift'`. Filter out tests and manifests first: `--files-to-mutate` skips the exclude list (`DiscoverSourceFiles.swift:29-32`), so a test file or `Package.swift` in the list would be mutated.
- **CLI overrides** ([#73]). Add `--workers N` and `--timeout S`, so wrappers don't need a YAML file for each run.
  - A changed `mutationTestWorkers` doesn't stop a resume, but a changed `mutationTestTimeout` does (`ResumeCheck.swift:48-56`).
  - The effective limit worked out from the timed test run or the baseline isn't compared (`:41-45`), so a `--timeout` override must be recorded and compared as that key is.
- **`--shard k/n`** ([#74]). Split the mutants deterministically by a hash of their key, so that two machines each run half.
  - Each half takes about (5,438 − 382) / 2 + 382 s ≈ 48 min, which is 1.9× faster.
  - `report` reads one results file (`Report.swift:12-13`), so it needs to learn to merge them.
- **`--sample N --seed S`** ([#75]). Run a random subset for trend checks. 500 mutants take about 23 min and give the score to ±3.4 points (95% confidence).
- `--since`, `--shard` and `--sample` change which mutants run. So each one must be recorded in the results file's header and compared by the resume check (`ResumeCheck.swift:91-98`). Otherwise a resume could reuse results from a different selection.

### 1.5 Experiments

- **Release-mode tests** ([#70]). Try `arguments:` with `-c release -Xswiftc -enable-testing`.
  - Since PR #42, most of each mutant's 8.1 s is test work, so release mode has more to act on than when this was first proposed.
  - The project's build and the clones' builds get slower, which adds to the setup.
  - Unmeasured.
- **Worker count** ([#70]). Try 2, 3, 4 and 6 workers. Each worker's Swift Testing run is already parallel, so expect 10–20% at most, about 9–18 min. Since fail-fast the workers no longer run in step, so only a measurement can settle it.

---

## 2. Losing or mis-scoring a run

### 2.1 Results file, `report`, `--resume` and interruptions: what's left

All four items are done (PRs #38 and #44–#46). These were left out of them:
- **`--resume`.**
  - It can't retest timeouts under a longer time limit ([#76]). A changed `mutationTestTimeout` refuses the resume (`ResumeCheck.swift:48-56`). Of the recorded outcomes, only build errors are always retested (`ResumePlan.swift:88-89`), so a timeout is kept like any result whose file and mutation are unchanged.
  - A test-plan run can't be resumed ([#79]): `run-without-mutating` has no `--resume` (`RunWithoutMutating.swift:21-31`).
  - Only the results file is locked (`ResultsFile.swift:64-66`), not the project, so two runs of one project can overlap ([#78]).
  - A resumed session's log folder doesn't point to the results file ([#77]).
  - When the results file is locked, the refusal names the previous session's writer, not the process holding the lock (`LoadResumeState.swift:26-35`, [#77]).
  - A resumed session writes its header and its `retired` line separately (`PerformMutationTesting.swift:726-729`, [#77]). A SIGKILL between the two leaves `report` showing stale results until the next session. Nothing is wrongly reused, because the plan checks the hashes again.
  - A refused resume leaves an empty log folder, and refusals have no exit code of their own ([#77]).
  - `report` of a resumed run's file doesn't say how many results came from earlier sessions ([#77]). Its status line gives only the count and how the last session ended (`RecordedResults+Status.swift:6-22`).
  - A results file from before PR #46 can't be resumed ([#77]).
  - The header grows by about 205 KB for each session ([#77]).
- **Interruptions.**
  - If SwiftMutator itself is killed with SIGKILL or crashes, its test processes are left running, and the next run's cleanup (`PreviousRunCleanUp.swift`) doesn't kill them ([#80]).
  - Ctrl-Z suspends SwiftMutator, but its tests keep running ([#81]). Their time limits keep counting but can't fire. So after `fg`, every run whose limit passed in the meantime is stopped at once, and can be recorded as a timeout even if its tests had finished.
  - Under xcodebuild, the simulator's test hosts aren't SwiftMutator's descendants, so they aren't killed ([#81]).
  - A forced exit, by a second signal or the 30 s watchdog, writes no end line ([#81]).
  - SIGQUIT keeps its default action ([#81]).

### 2.2 Killing tests: what's left

Items 1–3 are done. PR #38 records each mutant's failing tests, and PR #47 shows and summarises them and flags suspect tests. Left:
- **Item 4, a control job** ([#82]). Every so often, run the suite with no mutant active, under the same load.
  - Mark tests that fail in it as flaky, and kills by only those tests as suspect.
  - One control run per 100 mutants would cost about 2% of the run.
  - It would also make possible comparing how often a test fails alone with how often it fails beside others. That needs complete failure lists, which fail-fast prevents.
- **Gaps in the suspect rule** ([#82]).
  - When the passing baseline printed a line that looks like a failure, no mutant records its failing tests (`ResultsRecords.swift:283-284`), so the reports name none.
  - The rule misses a test that fails in fewer than about 3% of runs, or about 5% when runs stop at their first failed test. That's worth about 1 point at most; 0.16 points was measured.
  - Its thresholds (`KillingTestSummary.swift:4-10`) are calibrated on SwiftProjectLint alone. Check them on a second project, and perhaps make them configuration keys.

### 2.3 Same-named files: what's left

Discovery has merged mutants by full path since PR #25. Deferred:
- **Path-qualified mutant IDs** ([#83]). The ID is built from the file name only (`MutationSchema.swift:6-12`), so same-named files' mutants can share a switch variable.
  - Build it from the repo-relative path, or a short hash of it, plus the operator and position.
  - About 16 test files contain the ID format: 10 snapshots and 6 test files. The change also invalidates existing test plans.
  - `--resume` never compares IDs, so it's unaffected.
- **Kept-log names** ([#84]). They're built from the operator, file name, line and column (`MutationTestLog.swift:17-23`), with no folder and no occurrence number.
  - So same-named files, and repeated mutants at one place, overwrite each other's kept log. The results file's `log` field then points both mutants at one file.
  - The raw log each test process writes doesn't have this flaw. It goes in `running/` in the run's log folder, as `<job number>_<file name>_<operator>_<offset>_<line>_<column>.log` (`PerformMutationTesting.swift:677-679`, `MutationTestingIODelegate.swift:434-446`), and the job number keeps two runs under way at once apart. Without it, repeats, which are tested next to each other, could share one file, and the first to finish would remove it before the other read it.
  - Log folders are named to the minute (`fileOperations.swift:35`). So two runs or sessions started in the same minute share a folder, and a retested mutant's log overwrites the earlier one.
- **Compiler errors** ([#87]). `CompilerError.first` (`MutationTestingAbortReason.swift:128-138`) matches compiler errors to files by name, so with same-named files a failed baseline's message can name the wrong one.

### 2.4 Discovery and target membership: what's left

A project whose test command is `swift` mutates only the files its package's targets compile, and other projects skip hidden and git-ignored paths. Left:
- **xcodebuild target membership** ([#86]). An xcodebuild project's discovery still walks the project, so a file that git lists but no target compiles, such as an example app's in a folder of its own, gets mutants no test can kill. Coverage doesn't drop them, because a file outside every target is never reported as uncovered. The source files of the scheme's targets, from the project file, would say which files count. They would also bring back a generated source that git ignores and a target compiles, which the walk now leaves out though main mutated it.
- **A Swift package tested through xcodebuild,** such as FFCParserCombinator's `-Package` scheme, and a wrapper script with `buildSystem: swift`, are walked too. `swift package describe` would work for the first; the second can't be asked, as a wrapper may run anything with its arguments.
- **Executable targets that serve as examples.** An example app that is one of the package's executable targets is still mutated, as SwiftProjectLint's `App` target is. A test can `@testable import` an executable target, so only coverage tells whether any test reaches it.
- **A local package's targets that the package doesn't build.** Every target of a local package in the project that a SwiftPM project depends on is mutated, but its test, plugin and snippet targets, though the build compiles only those the products it uses need. A demo executable or a library no used product names gets mutants no test can kill. Following each product's targets and their dependencies would leave the others out.

### 2.6 One uncompilable mutant switch aborts the whole run

Tracked in [#87].

- **What happens.** A compile error in any of the ~300 rewritten files fails the baseline (`PerformMutationTesting.swift:194-226`). That ends the run after the copy, discovery and a ~95 s baseline. Stryker puts the offending mutants back instead, and cargo-mutants and mull mark them "unviable".
- **Proposal.**
  1. Make the build of the mutated project its own step. For SwiftPM it happens inside the baseline test run today.
  2. On failure, match each compiler error's path to a rewritten file, by full path in the copy, and restore that file from the original project. `CompilerError.all(in:)` (`MutationTestingAbortReason.swift:141-143`) already parses the errors.
  3. Record its mutants as "unviable", left out of the score but listed in the report.
  4. Rebuild incrementally, and repeat for a few rounds.
  5. Always print a loud warning naming the files that were dropped.
- **Effect.** Losing a handful of mutants, about 8 here, instead of all 2,497.

### 2.7 Timeouts and the score

PR #27 fixed truncated logs, fractional time limits and identical statements. A timed-out run counts as killed if its log already shows a failure summary or XCTest's `Test Case '…' failed (` line (PR #22). Since PR #36 it also counts if the log shows Swift Testing's `✘ … recorded an issue` line, unless the passing baseline printed such a line. Left out by choice, and still open:
- **xcodebuild projects keep the old default time limit** ([#88]). Since PR #57 a SwiftPM project's default comes from one timed run of `swift test … --skip-build` with no mutant on. An xcodebuild project's mutants run `test-without-building` from `muter.xctestrun`, which `switchOn` rewrites for each mutant, so timing one needs that file with no mutant switched on. Until then its default is still 3 × the baseline's build plus test (`PerformMutationTesting.swift`, `defaultTimeoutMultiplier`), as is any other build system's.
- **Plain timeouts count as survivors** ([#89]) (`mutationScoring.swift:6-7`). Decide whether to count them as killed, or to leave them out of the score.
- **The score is truncated, not rounded** ([#89]) (`mutationScoring.swift:13`). Muter's README, kept as `Docs/Muter-README.md` and linked from `README.md` for the configuration options, says killing 50 of 75 mutants scores 67% (line 92). The code gives 66%. Either:
  - round. That moves every score that uses `mutationScore`, including the score without suspect tests. It also changes the test at `KillingTestSummaryTests.swift:367-368`, and perhaps report snapshots; or
  - change the README to 66%.

## Open bugs

- **Workers share the user's `UserDefaults`** ([#92]). Tests that write fixed keys in `UserDefaults.standard` can overwrite each other's values across workers. That gave SwiftProjectLint 4 false kills on 2 October.
  - No SwiftMutator-side fix is known. `CFFIXED_USER_HOME` doesn't isolate `UserDefaults` on macOS 27, and it also moves `NSHomeDirectory()`, which breaks the swiftly proxy.
  - The fix belongs in the project's tests (see [Outside this repo](#outside-this-repo)).

---

## 3. Watching a run and using the report

- **A heartbeat in a log file** ([#93]). Since PR #59, a log gets a line as each mutant finishes, and nothing in between. So while every worker is on a long mutant, such as one that runs to SwiftProjectLint's 181 s time limit (PR #57, at 4 workers), a hang looks like a slow run. After 60 s with nothing finished, print what each worker is running and for how long.
- **Reports** ([#94]). They have shown each mutant's killing tests since PR #47. Still to do:
  - List survivors first. The plain report groups mutants by file in the order they ran, and the HTML report sorts them by file name.
  - Show the repo-relative `path:line:col`. The plain and HTML reports show `fileName:line`.
  - Show the original source line, before → after. The HTML and JSON reports show only the mutation's snapshot, never the whole line: the operator for relational and logical mutants (`<` → `>`), the removed statement for RemoveSideEffects, and the ternary for SwapTernary. The plain report shows no change at all.
  - Show each mutant's duration. Today only `results.jsonl` has it.
  - Add each mutant's repo-relative path and key to the JSON. Its paths point into the `_mutated` copy today.
  - Write a `summary.json` with the score, the counts by outcome and the wall time.
  - Never colour report files ([#95]). Today `-f plain -o report.txt`, run from a terminal, saves colour codes in the file (`ReportWriter.swift:8-14`).
  - Say "coverage skipped" when coverage was skipped ([#95]). The plain report says SwiftMutator "could not gather coverage data" either way (`PlainTextReporter.swift:79-82`).
- **Provenance in reports** ([#94]). The results file's header records:
  - the SwiftMutator build, as its executable's SHA-256 rather than a commit;
  - the toolchain;
  - the configuration;
  - the worker count;
  - the time limit.

  Each mutant's line has its key, switch ID and duration. The reports show none of this; they should at least name the results file. Nothing compares two runs mutant by mutant yet.
- **Exit codes** ([#96]). Add `--fail-under <pct>` or `scoreThreshold:`, with distinct exit codes for "below threshold", "timeouts", "baseline failed" and "aborted".
  - Today a finished run exits 0 whatever its score.
  - A stop by signal ends SwiftMutator by that same signal, so a shell reports 128 + its number (130, 143 or 129). A wrapper that reads the wait status sees a signal, not an exit code.
  - Every other failure of a run exits 255, a refused resume included. A usage error exits 64, and `report` exits 1 when it can't read its file.
- **Log storage** ([#97]).
  - Each mutant's log is still written twice: by the test process, to `running/` in the run's log folder, and again under its kept name (`MutationTestObserver.swift:100-102`, `:124-130`). The first copy goes once it's read back (`MutationTestingIODelegate.swift`), where it used to stay in `_mutated` until the next run, and tests could see it. Write it once.
  - Kept logs are never removed. On this machine, SwiftProjectLint's log folder holds 15 runs and 2.4 GB.
  - Keep full logs only for survivors, crashes and timeouts. That needs the results file's `log` field to become optional.

---

## 4. Repo health

- **CI follow-ups** ([#98]). CI is done (PR #24). Not done:
  - a nightly or on-demand regression run. `workflow_dispatch` reruns only the unit tests;
  - a SwiftLint job, which can go in as it is: `swiftlint lint` passes on `main`;
  - caching `.build`;
  - required checks: `main` has no branch protection or rulesets.
- **`make build` cleans every time** ([#98]). It starts with `swift package clean` (`Makefile:9`), and `run`, `acceptance-test` and `regression-test` depend on it. Keep the clean in `make clean` only. `mutation-test` also removes `.build` first (`Makefile:43`).
- **Type-check more of the generated code** ([#99]). `GeneratedEnvironmentCacheTests.swift:304-372` compiles a rewritten file with `swiftc`: in Swift 6, with warnings as errors, and under default `MainActor` isolation. Its own file holds one `value > 1` mutant, and the tests add files beside it: code other modules may copy, closures in multi-line strings, with each kind of line ending ([#90]), and `#sourceLocation` directives. Not covered:
  - result builders
  - opaque non-builder bodies
  - file-scope `#if`
  - `main.swift`
  - ternaries containing longer expressions

  The test's helper could take the source as a parameter. Fixtures like these would have caught three of the four rewriter bugs fixed just before the review.
- **Real-process tests** ([#99]). Still missing:
  - a real process tree that outlives its time limit, checking that the outcome is a timeout and nothing survives (today's timeout tests use stand-ins);
  - one real log from SwiftProjectLint's three test bundles, as a fixture.
- **Upstream Muter leftovers** ([#100]). The update check and version 0.1.0 are already SwiftMutator's own. Left:
  - The banner's help link and three error messages point at Muter's issues (`Logger.swift:37`, `RunCommand.swift:48`, `MutationTestingAbortReason.swift:41` and `:76`).
  - The baseline-failure messages still call the tool Muter (`MutationTestingAbortReason.swift:68-99`).
  - `CONTRIBUTING.md` is still Muter's text: its title, pinned issues, "fork Muter's repository", `master`, and Muter on your `PATH`. Only its CI and `swift test` notes were updated.
  - The toolchain setup (swiftly, and `SDKROOT=…/MacOSX26.5.sdk` for Swift 6.3.3) isn't documented for contributors.
  - The release tooling is Muter's ([#121]).
    - `make release` runs `Scripts/shipIt.sh`, which hashes Muter's release archive and builds a Homebrew formula for Muter.
    - `Scripts/bump_version.py` and the `homebrew-formulae` submodule point at Muter too.
  - The update check calls GitHub's API on every run that isn't given `--skip-update-check` (`swift-quality` passes it). SwiftMutator has no releases, so the check can never find one. Cut a release, or make the check opt-in ([#121]).
- **Better relational-operator mutants** ([#102]). Today `<` and `>` are swapped, which almost any test kills. Boundary mutants (`<` → `<=`, `>` → `>=`, and so on) would expose missing edge-case tests.
  - Done in place, the count stays at 218 here.
  - As a separate operator, they would add 218 mutants, about 7–15 min.
- **xcodebuild projects** ([#103]). These always test one mutant at a time, without fail-fast (`MuterConfiguration.swift:100-111`). The per-worker copies used for SwiftPM could cover them too, with a cloned simulator per worker.
- **Spotlight** ([#104]). It indexes the copies and logs under `~/xcode_projects`. SwiftMutator names those folders itself (`_mutated`, `_muter_logs` and `_worker<n>`), so it could add `.noindex`. The benefit hasn't been measured.
  - Only the steps that make the folders (`CreateTempDirectoryURL.swift:21`, `fileOperations.swift:41`, `PerformMutationTesting.swift:819`) and the cleanup (`PreviousRunCleanUp.swift:38`) use their names. `report` and `--resume` use the path they're given and the paths in the results file.
  - Outside this repo, `swift-quality` removes `${repo}_mutated` by name, so it would need to change too.

---

## 5. Example tests and property tests

Added on 7 October, from a discussion of using property-based tests (PBT) alongside mutation testing. Not in the suggested order: it's a feature, not a fix, and its first step only reads existing results. Tracked in [#105].

- **The idea.** Report which kind of test kills each mutant, so the score can be split by kind. It can also show how much each property constrains the code: mutants make a measure of a property's strength.
- **What exists.** Each `mutant` line in `results.jsonl` has `killedBy`: each failing test's name and `file:line:col`, at most 20 (`ResultsRecords.swift:226-228`, `FailedTestLine.swift:95`). A test's file or suite can mark it as a property test, so no new recording is needed to start.
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

## 6. Gaps found by comparing with swift-mutation-testing

Added on 21 October, from a comparison with swift-mutation-testing v1.6.3 (`937f128`), checked against SwiftMutator `af38f174`. These are the gaps the sections above didn't already cover. Where a gap matched an item above, its issue is linked there instead.

- **Operators.**
  - NegateConditional, which wraps `if`, `guard` and `while` conditions in `!( )` ([#106]). SwiftMutator's docs call the relational swap "Negate Conditionals", which it isn't.
  - Arithmetic and boolean-literal operators, an `operators:` key and a way to turn one off ([#111]).
  - RemoveSideEffects: the blocks it skips, and a deny-list matched by name, with `assert` and `precondition` added ([#112]).
  - Every link of a ternary chain, identical branches, loops and `#if` conditions ([#113]).
- **Discovery and the build.**
  - Mutants outside function bodies are dropped without a word, and a `main.swift` with an `import` loses all its top-level ones ([#107]).
  - A mutant in an `@inlinable` body fails the shared build, because the support enum is `fileprivate` (checked with Swift 6.4, [#108]).
  - Inactive `#if` branches are left out only through coverage ([#114]).
  - Declaration-scoped and next-line suppression, test-helper excludes, folders in `--files-to-mutate` and an `--exclude` flag ([#115]).
  - xcodebuild mutant runs keep only `-destination` of the user's arguments ([#123]).
- **Verdicts and runs.**
  - Recording whether each mutant's code ran: no-coverage verdicts, integrity warnings and reruns of kills whose code never ran ([#109]).
  - Failing loudly when a mutant isn't applied or switched on ([#110]).
  - Parallel SwiftPM runs by default, keeping one writable copy per worker. swift-mutation-testing's shared folder gives false kills (ericodx/swift-mutation-testing#187, [#116]).
  - Time limits for the build, coverage and baseline, and the baseline's failing tests named ([#117]).
  - Keeping the Mac awake during a run ([#118]).
- **Reports, CI and distribution.**
  - Stryker JSON, SARIF and a Markdown summary, several from one run ([#119]).
  - CI gates against a committed baseline: new survivors and score drops ([#120]).
  - Releases with binaries, Homebrew, a real version and an update check that works ([#121]).
  - Warnings for unknown configuration keys, value checks, runs without a configuration file, and a smarter `init` ([#122]).
  - User documentation in one place, with a GitHub Actions recipe ([#124]).

---

## Checked and not worth doing

- **One mutant per line.** On 2 October, 2,478 inserted mutants sat on 2,205 lines, so a cap would save at most 11%. That was before PR #25 inserted every mutant, but that run's 2,487 logs give the same 11%.
- **One long-lived test process for many mutants.** PR #13's per-process environment cache, and other static state that persists between mutants, make this unsafe.

## Suggested order

1. **Unviable mutants** (§2.6, [#87]), so that one bad mutant can't cost a whole run.
2. **`--since`, reuse and `--shard`** (§1.4: [#72], [#71] and [#74]), for runs on a change rather than the whole repo.

## Outside this repo

- **Upstream Muter.** The fixes in PRs #25, #27, #49 and #52–#55 also apply to upstream Muter at `7f1f258`, and PR #26's once muter#309 and muter#312 are in. Each PR's body says how to port it. They're held until upstream's CI is green again.
- **`swift-quality`.**
  - It prints `swift --version` before it changes into the project folder (lines 75 and 80 at dotfiles-claude `cf472b0`), so its header can name the wrong toolchain.
  - Add start and end timestamps to `summary.txt`.
  - Copy the "Mutation Score without suspect tests" and "Suspect tests" lines into `summary.txt`. Anchor the killed-count `grep` to the line that starts "Of the".
  - Drop `--skip-coverage`, now that coverage works with several test bundles (PR #60), so runs leave out the mutants no test runs.
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

[#62]: https://github.com/Joseph-Cursio/SwiftMutator/issues/62
[#63]: https://github.com/Joseph-Cursio/SwiftMutator/issues/63
[#64]: https://github.com/Joseph-Cursio/SwiftMutator/issues/64
[#65]: https://github.com/Joseph-Cursio/SwiftMutator/issues/65
[#66]: https://github.com/Joseph-Cursio/SwiftMutator/issues/66
[#67]: https://github.com/Joseph-Cursio/SwiftMutator/issues/67
[#68]: https://github.com/Joseph-Cursio/SwiftMutator/issues/68
[#69]: https://github.com/Joseph-Cursio/SwiftMutator/issues/69
[#70]: https://github.com/Joseph-Cursio/SwiftMutator/issues/70
[#71]: https://github.com/Joseph-Cursio/SwiftMutator/issues/71
[#72]: https://github.com/Joseph-Cursio/SwiftMutator/issues/72
[#73]: https://github.com/Joseph-Cursio/SwiftMutator/issues/73
[#74]: https://github.com/Joseph-Cursio/SwiftMutator/issues/74
[#75]: https://github.com/Joseph-Cursio/SwiftMutator/issues/75
[#76]: https://github.com/Joseph-Cursio/SwiftMutator/issues/76
[#77]: https://github.com/Joseph-Cursio/SwiftMutator/issues/77
[#78]: https://github.com/Joseph-Cursio/SwiftMutator/issues/78
[#79]: https://github.com/Joseph-Cursio/SwiftMutator/issues/79
[#80]: https://github.com/Joseph-Cursio/SwiftMutator/issues/80
[#81]: https://github.com/Joseph-Cursio/SwiftMutator/issues/81
[#82]: https://github.com/Joseph-Cursio/SwiftMutator/issues/82
[#83]: https://github.com/Joseph-Cursio/SwiftMutator/issues/83
[#84]: https://github.com/Joseph-Cursio/SwiftMutator/issues/84
[#85]: https://github.com/Joseph-Cursio/SwiftMutator/issues/85
[#86]: https://github.com/Joseph-Cursio/SwiftMutator/issues/86
[#87]: https://github.com/Joseph-Cursio/SwiftMutator/issues/87
[#88]: https://github.com/Joseph-Cursio/SwiftMutator/issues/88
[#89]: https://github.com/Joseph-Cursio/SwiftMutator/issues/89
[#90]: https://github.com/Joseph-Cursio/SwiftMutator/issues/90
[#91]: https://github.com/Joseph-Cursio/SwiftMutator/issues/91
[#92]: https://github.com/Joseph-Cursio/SwiftMutator/issues/92
[#93]: https://github.com/Joseph-Cursio/SwiftMutator/issues/93
[#94]: https://github.com/Joseph-Cursio/SwiftMutator/issues/94
[#95]: https://github.com/Joseph-Cursio/SwiftMutator/issues/95
[#96]: https://github.com/Joseph-Cursio/SwiftMutator/issues/96
[#97]: https://github.com/Joseph-Cursio/SwiftMutator/issues/97
[#98]: https://github.com/Joseph-Cursio/SwiftMutator/issues/98
[#99]: https://github.com/Joseph-Cursio/SwiftMutator/issues/99
[#100]: https://github.com/Joseph-Cursio/SwiftMutator/issues/100
[#101]: https://github.com/Joseph-Cursio/SwiftMutator/issues/101
[#102]: https://github.com/Joseph-Cursio/SwiftMutator/issues/102
[#103]: https://github.com/Joseph-Cursio/SwiftMutator/issues/103
[#104]: https://github.com/Joseph-Cursio/SwiftMutator/issues/104
[#105]: https://github.com/Joseph-Cursio/SwiftMutator/issues/105
[#106]: https://github.com/Joseph-Cursio/SwiftMutator/issues/106
[#107]: https://github.com/Joseph-Cursio/SwiftMutator/issues/107
[#108]: https://github.com/Joseph-Cursio/SwiftMutator/issues/108
[#109]: https://github.com/Joseph-Cursio/SwiftMutator/issues/109
[#110]: https://github.com/Joseph-Cursio/SwiftMutator/issues/110
[#111]: https://github.com/Joseph-Cursio/SwiftMutator/issues/111
[#112]: https://github.com/Joseph-Cursio/SwiftMutator/issues/112
[#113]: https://github.com/Joseph-Cursio/SwiftMutator/issues/113
[#114]: https://github.com/Joseph-Cursio/SwiftMutator/issues/114
[#115]: https://github.com/Joseph-Cursio/SwiftMutator/issues/115
[#116]: https://github.com/Joseph-Cursio/SwiftMutator/issues/116
[#117]: https://github.com/Joseph-Cursio/SwiftMutator/issues/117
[#118]: https://github.com/Joseph-Cursio/SwiftMutator/issues/118
[#119]: https://github.com/Joseph-Cursio/SwiftMutator/issues/119
[#120]: https://github.com/Joseph-Cursio/SwiftMutator/issues/120
[#121]: https://github.com/Joseph-Cursio/SwiftMutator/issues/121
[#122]: https://github.com/Joseph-Cursio/SwiftMutator/issues/122
[#123]: https://github.com/Joseph-Cursio/SwiftMutator/issues/123
[#124]: https://github.com/Joseph-Cursio/SwiftMutator/issues/124
[#130]: https://github.com/Joseph-Cursio/SwiftMutator/issues/130
