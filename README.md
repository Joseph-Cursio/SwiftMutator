# SwiftMutator

[![CI](https://github.com/Joseph-Cursio/SwiftMutator/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Joseph-Cursio/SwiftMutator/actions/workflows/ci.yml)

Automated [mutation testing](https://en.wikipedia.org/wiki/Mutation_testing) for Swift.

SwiftMutator is based on [Muter](https://github.com/muter-mutation-testing/muter) by the Muter
contributors, and keeps its history. Muter introduces small changes (*mutants*) into your
code, such as `==` becoming `!=` or a call being removed, and runs your tests against each one.
A mutant your tests don't catch shows a behavior your tests don't check. The mutation score is
the share of mutants caught.

## Also look at swift-mutation-testing

If you're choosing a mutation tester for Swift, take a good look at
[swift-mutation-testing](https://github.com/ericodx/swift-mutation-testing) too. It isn't a fork
of Muter, and it's actively maintained: in October 2026 it had a new release most weeks, and each
of the four issues this project's maintainer reported to it
([#125](https://github.com/ericodx/swift-mutation-testing/issues/125),
[#135](https://github.com/ericodx/swift-mutation-testing/issues/135),
[#187](https://github.com/ericodx/swift-mutation-testing/issues/187),
[#188](https://github.com/ericodx/swift-mutation-testing/issues/188)) was closed within about a
day, three of them with a fix. It has things SwiftMutator doesn't, among them:

- a check, as each mutant is tested, that its code actually ran. A mutant no test reaches is
  reported as "no coverage" and counts against the score, and a kill whose code never ran is tested
  again. SwiftMutator instead skips the code that one coverage run, before mutating, shows no test
  reaching, and leaves those mutants out of its score;
- seven mutation operators, against SwiftMutator's four. Its default run uses three of them:
  logical operators, negated conditions and swapped ternaries. So by default it doesn't replace
  relational operators, as in `==` becoming `!=`, or remove calls, which SwiftMutator does;
  `--operator-tier experimental` runs all seven;
- on SwiftPM packages, recovery from mutants that don't compile, without giving up its shared
  build;
- a quality gate for CI: a minimum score, and no new survivors against a committed baseline;
- SARIF, SonarQube, Markdown and Stryker-compatible JSON reports.

SwiftMutator differs in how it keeps tests apart. Each of its workers tests in its own full
copy of the project, `.git` included. swift-mutation-testing tests in a sandbox whose unchanged
files are links to your project's files, so a test that rewrites one in place, such as a fixture,
changes your project, and a test that runs `git` can fail. On a package, its workers share that
sandbox, so tests that write files there at fixed paths can give false kills. In both tools,
workers share the temporary directory. On macOS, SwiftMutator gives each worker's directly run
tests their own `UserDefaults` (see Test bundles run directly); swift-mutation-testing's workers
share them ([#92](https://github.com/Joseph-Cursio/SwiftMutator/issues/92)).

swift-mutation-testing needs macOS 15 or later, and installs with Homebrew.
[Docs/smt-trial-2026-10.md](Docs/smt-trial-2026-10.md) compares the two tools as they were on
21 October 2026, on two packages. On the mutants both made, they gave the same verdict 97% of the
time. On the larger package, SwiftMutator was 6.6 times as fast, mostly because
swift-mutation-testing built 918 of its mutants one at a time; its v1.6.4, of 27 October, builds
fewer that way. On the small package, swift-mutation-testing was faster.

## Why a fork of Muter

Muter's last release is 16 (September 2023). On current toolchains its `main` branch reports a
0% score for SwiftPM projects ([muter#307](https://github.com/muter-mutation-testing/muter/issues/307)),
and fixes wait months for review. SwiftMutator starts from Muter's `main` and adds:

- **Mutants that actually apply:** schemata keyed by stable source position, nested blocks kept,
  ternary swaps that don't corrupt code, and simulator, PATH and module-cache fixes (from
  [muter#309](https://github.com/muter-mutation-testing/muter/pull/309), by John Marshall).
- **Parallel workers:** `mutationTestWorkers: N` tests N mutants at once on SwiftPM projects,
  each in its own APFS clone of the mutated project. Each clone is built once before testing, which
  costs one extra build per worker but keeps tests that write files next to their sources from
  sharing them across workers.
- **One environment for every `swift test` run:** a mutant is switched on by its ID in a file
  beside the worker's folder, such as `MyPackage_mutated.active-mutant`, not by a variable of its
  own, so your tests don't find it among the package's files or in its `git status`. For a package
  inside a larger git repository, ignore `*_mutated*` there, which covers the worker clones too.
  SwiftPM keys its cache of compiled package manifests on the whole environment, so runs no longer
  recompile every `Package.swift`, which saves about 6 s per mutant with 4 workers. A wrapper
  script around `swift test` gets this only with `buildSystem: swift`, and its tests must be able
  to read that file; other wrappers and `xcodebuild` keep a variable per mutant. A SwiftPM test
  plan made by an older SwiftMutator is refused: make it again with
  `swift-mutator mutate-without-running`.
- **Test bundles run directly:** on macOS, a SwiftPM project's mutants don't go through
  `swift test`, which spends about a second of each run loading the package and planning the build
  it skips. Each test bundle runs with SwiftPM's own `swiftpm-testing-helper`, from the toolchain of
  the `swift` in `executable`, given the same arguments and variables `swift test --skip-build`
  gives it, so `--filter` and `--skip` still apply. Before the mutants, one such run with no mutant
  on must pass and run as many Swift Testing tests in each bundle as the baseline did; it is the
  run the default timeout is based on. Otherwise, and when the baseline ran XCTest tests, which only
  `swift test` runs, or the build is outside the project, mutants run `swift test` as before, and a
  line says why. A wrapper `executable`, and Linux, always run `swift test`.
  - **Each worker's own `UserDefaults`.** The helper has no bundle identifier, so its tests keep
    `UserDefaults.standard`, and `@AppStorage` without a `store:`, in a domain named after the
    helper's file, which every worker shared, and every other `swift test` run on the Mac too. A test
    that wrote a fixed key could then fail another worker's tests and kill a mutant they don't check
    ([#92](https://github.com/Joseph-Cursio/SwiftMutator/issues/92)). Direct runs start the helper
    through a link beside the worker's folder, such as
    `MyPackage_mutated_worker1.swiftpm-testing-helper`, which makes that the domain, and empty it
    before each mutant's run, so no mutant sees what an earlier one wrote. The links and domains go
    at the end of the run.
  - **Still shared:** what the baselines and `swift test` runs write, a suite you open with a fixed
    `UserDefaults(suiteName:)`, the keychain, fixed temporary paths and ports. The fix for those
    belongs in your tests: give each test its own store, for example a suite named with a UUID that
    the test removes afterwards. Until then, `mutationTestWorkers: 1` avoids it, at the cost of
    speed.
- **A default timeout:** without `mutationTestTimeout`, a mutant's test run stops after a limit
  based on how long your tests take, so a mutant that loops forever can't hang the run. For a
  SwiftPM project, SwiftMutator times one run of a mutant's test command with no mutant on,
  the test bundles run directly or `swift test … --skip-build`, just after the baseline, and allows 5× that, once more for each worker beyond the first, and at
  least 20 s. For another build system, or when that run fails, it allows 3× the baseline, build
  included, and at least 10 s. A timeout counts as a survivor, so if your tests set limits of their
  own, such as Swift Testing's `.timeLimit`, which is at least a minute, set `mutationTestTimeout`
  above them: otherwise a mutant that only your tests' limit would catch ends as a timeout.
- **Coverage with several test bundles:** Swift 6.4's build system makes a test bundle for each
  test target, which Muter's coverage step can't read, so it tested every mutant, even in code no
  test runs. SwiftMutator exports the coverage of every bundle at once, leaves out the files no
  test runs and skips the mutants in code no test runs. If coverage can't be gathered, it says
  why, and tests every mutant as before. `--skip-coverage` turns the step off. On SwiftPM, coverage
  builds with flags of its own, so the baseline after it builds again without them. That costs
  less than it sounds: SwiftMutator's copy of the project is at a new path, so its first build is
  a full one anyway. On SwiftProjectLint the coverage step took about 82 s, and the baseline with
  the timed run after it about 80 s, of which about 5–15 s was owed to coverage's flags. Building coverage in a clone of
  the copy instead saved that, but copying and removing the clone cost more, about 18 s.
- **No silent survivors from missing switches:** a mutant whose switch isn't in the code would run
  the original code, pass its tests and count as a survivor. After rewriting the copy, SwiftMutator
  reads each rewritten file back and checks that it holds every one of its mutants' IDs as a quoted
  string, and `run-without-mutating` checks a test plan's code the same way, as it may have been
  edited by hand. A gap stops the run before any test, naming the files and mutants, as does a file
  with mutants that can't be read. Under xcodebuild, a mutant whose `muter.xctestrun` can't be
  written stops mutation testing, since the file left by the run before would switch that mutant
  on. These prove a switch is there, not that a run switched it on.
- **Logging through the injected printer**, so log output can be captured and tested.

Fixes that apply to Muter are offered upstream too.

## Build and run

```bash
swift build -c release --product swift-mutator
.build/release/swift-mutator init      # writes muter.conf.yml in the current project
.build/release/swift-mutator run       # runs mutation testing
```

`make install` installs `swift-mutator` into `/usr/local/bin`.

A run tests in a copy of the project beside it, `<project>_mutated`, so a project has one run at a
time. `run`, `mutate-without-running` and `run-without-mutating` lock `<project>_mutated.lock`
before they read, remove, copy or test anything there. One started while another holds the lock is
refused, naming the folder, and the process that holds it when the lock file shows which, and
leaves everything as it was. The lock goes when SwiftMutator exits, however it exits, so it never
needs clearing; the file stays, made with the permissions your umask gives new files, so anyone
who can remove the copy can lock it.

## Progress

In a terminal, a progress bar counts the mutants tested and estimates the time left from the time
per mutant so far. Elsewhere, as with `> run.log` or `| tee run.log`, the bar's redraws would fill
the log with cursor movements. So SwiftMutator prints a line once the baseline passes and one as
each mutant finishes instead, and flushes each line as it prints it:

```
[13:13:25] 1103 of 2497 (44%) | 838 killed, 262 survived, 3 timed out | 47 min left | survived at Rules.swift:42:17 (changed == to !=)
```

So `tail -f run.log` follows the run, and `grep 'survived at' run.log` lists the survivors so far.
A resumed run's lines count only the mutants it tests, so they leave out the results it kept;
`swift-mutator report` gives them all. Standard output counts as a terminal where colour can show:
it's a tty, and `TERM` is set and isn't `dumb`. `NO_COLOR` turns off the colour, not the bar.

The Swift files a run finds, then how many mutants are in each file that has any, are listed only
with `--verbose`.

## Configuration

SwiftMutator reads Muter's `muter.conf.yml`, so existing Muter configurations work unchanged,
except an xcodebuild project's `coverageThreshold`. Muter read that one as a fraction from 0 to 1,
so any value of 1 or more left out every file. It's a percentage from 0 to 100 now, as it always
was for SwiftPM: `0.5` means 0.5%, so write `50` for half. The options are documented in
[Muter's README](Docs/Muter-README.md#configuration-options); SwiftMutator adds:

| Key | Meaning |
|---|---|
| `mutationTestWorkers` | How many mutants to test at once (SwiftPM projects only; default 1) |
| `mutationTestTimeout` | Seconds before a mutant's test run is stopped (default: based on a timed test run; see above) |
| `stopAtFirstFailure` | Stop a mutant's test run at its first failed test, or at a test process's crash, either of which already decides that it is killed (SwiftPM projects only; never the baseline; default true) |
| `buildTimeout` | Seconds before the coverage run, which builds your project and runs its tests with coverage on, is stopped. Mutation testing then goes on without coverage, as after any coverage failure. For now it limits only the coverage run, not the baseline or other builds (default: no limit) |

`--workers N` and `--timeout S`, on `run` and `run-without-mutating`, set `mutationTestWorkers`
and `mutationTestTimeout` for one run, in place of the file's
([#73](https://github.com/Joseph-Cursio/SwiftMutator/issues/73)). They must be at least 1 and
above 0. The run records and compares them as it does the keys: a resume with another
`--timeout` is refused, and another `--workers` only said. A run that tests several mutants at
once says so, and one that uses fewer workers than asked says why:

```
👷 Testing 3 mutants at a time, though 4 workers were asked for: only 3 are left to test.
👷 Testing one mutant at a time, though 4 workers were asked for: only SwiftPM projects test more than one at once.
```

### Workers and release mode

Measured on SwiftProjectLint's whole repo, 2,463 mutants, on an 18-core Mac, with
`--skip-coverage` and one run per setting
([Docs/release-and-workers-2026-10.md](Docs/release-and-workers-2026-10.md)):

- **`mutationTestWorkers`** (default 1). 2 workers took 39 min, 3 took 30, 4 took 27, 6 took 24
  and 8 took 24. Each worker past the first adds a clone and its build, and every test run slows
  as the load rises, so the gain falls off fast; two runs with 4 workers differed by 13%. On that
  machine 4 was a safe choice, and 6 or 8 helped a little; a machine with fewer cores will do best
  with fewer. More workers also make false kills from tests that share state outside the project
  more likely, such as `UserDefaults`
  ([#92](https://github.com/Joseph-Cursio/SwiftMutator/issues/92)): with 8 workers they killed 9
  mutants that most runs didn't.
- **Release-mode tests.** With `arguments: [test, -c, release, -Xswiftc, -enable-testing]` the same
  run took 19 min instead of 27, with about the same verdicts. `-enable-testing` keeps
  `@testable import` working. The tests ran 2.8 times as fast, but the builds took longer and setup
  went from 2 min to 10, so with 4 workers it pays off only above about 1,250 mutants, and above
  more with more workers. With coverage on, the coverage run is also built in release, which
  wasn't measured.
  - Tests that look for a product in `.build/debug` fail the baseline in release mode, which stops
    the run. Link `.build/debug` to the release products, or find the product another way.
  - Release mode can also lose kills without any warning: an `assert` or `assertionFailure` isn't
    evaluated, and code and tests under `#if DEBUG` drop out. `precondition` is still checked. If
    your code relies on them, compare a release run's survivors with a debug run's.

## Mutating only what a branch changed

`run --since <ref>` mutates only the Swift files that changed since the merge base of the git ref
and HEAD, as a pull request shows them
([#72](https://github.com/Joseph-Cursio/SwiftMutator/issues/72)). `--changed-lines` narrows that
to the mutants on the lines the change added or changed.

```
swift-mutator run --since origin/main --changed-lines -o report.txt
🌿 5 Swift files changed since the merge base of origin/main and HEAD (3f9c2e1), of which only the changed lines are mutated.
```

- **What counts as changed.** The working tree is compared with the merge base, so commits on the
  branch, uncommitted changes, and new files git doesn't ignore all count. Changes the base branch
  made after the branch left it don't. A removed file has nothing to mutate.
- **The usual filters still apply.** Of the changed files, the excludes, both default and
  configured, leave out tests, manifests and what `exclude` names. Then, as in any run, only what
  the package's targets compile is mutated, and the coverage filter applies.
- **`--changed-lines`** keeps a mutant when its code is on a line the change added or changed, or
  lost lines from its middle. That is the whole statement for a removed statement, the whole
  ternary for a swapped one, and the whole expression for an operator, so an edit to an operand on
  another line counts. Removing lines between two statements selects neither.
- **Nothing to mutate isn't a failure.** When no Swift file changed, or the filters leave none, or
  no mutant is on a changed line, SwiftMutator says which, writes no report or results file, and
  exits with 0, so a CI job on a change to docs or tests passes. A ref git doesn't know, no common
  history, or unresolved merge conflicts fail the run before anything is copied.
- **In CI**, the base branch's history has to be there: a shallow clone has no merge base. With
  `actions/checkout`, set `fetch-depth: 0`, and compare with `origin/<base>`.
- **Resuming.** The results file's header records what `--since` chose. A resume compares its merge
  base and `--changed-lines`, and the Continue line names the merge base, so a ref that moved since,
  as `origin/main` does after a fetch, still resumes. Files changed meanwhile are compared as in any
  resume. `--reuse` keeps an earlier run's results for the mutants this run chose, whatever that
  run chose.
- **The reports say so.** The plain and HTML reports say which ref the mutated code changed since,
  and the JSON report gives it as `since`. Of the files without coverage, they list only the
  changed ones.
- **Limits.** git compares only this repository, so changes inside a submodule or a repository of
  its own in the project, such as a local package with its own `.git`, aren't seen, and
  SwiftMutator names those folders. A symbolic link to a Swift file is never chosen. A file renamed
  only in case, without `git mv`, is followed by its name on disk.
- **Measured** on SwiftProjectLint, with 4 workers
  ([Docs/since-2026-11.md](Docs/since-2026-11.md)): a four-file pull request took 2.7 min by
  whole files and 50 s by changed lines, against 27.3 min for the whole project, with every verdict
  the full run's. A change to tests alone ended in 1 s, with nothing copied.

## Results file

SwiftMutator saves each mutant's result as soon as it is tested, as one line of JSON in
`results.jsonl` in the run's log folder, `<project>_muter_logs/<run>/`. A run that is stopped or
crashes keeps every result it finished. The file's first line records the SwiftMutator build, the
toolchain and the settings the run used, and each killed mutant's line names the tests that failed.
`run --resume` continues a stopped run from it (see [Resuming a run](#resuming-a-run)).
[Docs/results-file.md](Docs/results-file.md) describes the format, with `jq` recipes such as the
tests that killed the most mutants.

Each test run writes its output to `running/` in the log folder while it runs, never to the mutated
project or a worker clone, where your tests would see it. Once SwiftMutator has read it back, the
log folder keeps its own copy, such as `baseline run.log`, and the file in `running/` goes.

A SwiftPM mutant's run adds `--quiet`, so Swift Testing prints no line for each test or suite that
starts or passes. Its log keeps each recorded issue, the run's summary, your tests' own output and
any crash; on SwiftProjectLint a survivor's log went from about 960 KB to about 2 KB. Put `-v` or
`--verbose` in `arguments` for full logs. Baselines run with `arguments` as they are, and XCTest's
output doesn't change.

`swift-mutator report` makes a run's report from its results file, in any format. The log folder
is beside the project, not in it, so from the project's folder, where `run` is run:

```bash
swift-mutator report "../SwiftProjectLint_muter_logs/Oct 4, 2026 at 1:16 PM" -f html -o report.html
```

- **What it takes.** The results file, or the run's log folder that holds it. `-f` and `-o` work as
  in `run`. Without `-o` the report goes to standard output alone, so `-f json > report.json` gives
  valid JSON.
- **A finished run** gets its own report back, in any format. Only what depends on when and where a
  report is made can differ, such as the time in the HTML report's footer. A run by an older
  SwiftMutator, which tested a file's mutants by operator and put line 10 before line 9, gets them
  in line order.
- **A run that was stopped, crashed or is still going** gets a report of the mutants it has tested.
- **On standard error** it says how many of the run's mutants the report covers, how the run ended,
  and where it saved the report. A run that stopped on its fifth build error in a row, for example,
  gives `Report of 1103 of 2497 mutants, from …: the run stopped on an error (tooManyBuildErrors).`
- **It exits with status 1** when the file can't be read or isn't a results file.
- **It exits with status 255** once the report is made of a run that stopped on an error, the status
  the run itself exited with, so a script that checks the report fails as one that checked the run
  would.

[Reports from the file](Docs/results-file.md#reports-from-the-file) has the details.

### Killing tests and suspect tests

The plain text, HTML and JSON reports name the tests that failed for each killed mutant, as its log
shows them, and add a Killing Tests section. That section lists the 10 tests that failed for the
most killed mutants, how many files those mutants are in, and how many of them recorded the test as
their only failure. No extra test runs are needed. `swift-mutator report` reads the names from the
results file, and a resumed run keeps those of the results it reuses, so both name the tests the
run named. A mutant a crash killed shows its tests but isn't counted in the section, because a
crash kills a mutant whichever tests failed.

- **Plain text.** The Applied Mutation Operators table gets a Killed By column. A cell gives the
  first test that failed, cut at 60 characters, then `(+N)` when N more failed, and
  `(suspect only)` when only suspect tests did (see below). `(none named)` is a kill whose log
  names no test. `-` is a mutant that wasn't killed, or whose tests weren't recorded.
  `grep -E 'survived|suspect only' report.txt` lists the mutants to look at first.
- **HTML.** The same column and section. A cell that names more than one test opens to each of
  them, with where it failed.
- **JSON.** Each killed or timed-out mutant has `killingTests`: up to 20 tests, how many failed in
  all, and whether the list is complete. A top-level `killingTestSummary` holds the section. The
  [example](Docs/test_report_json_example.md#killing-tests-in-the-json-report) shows the keys.
- **Xcode.** Only what it says of suspect tests.

A list is complete when the run exited by itself and named every test that failed. With
`stopAtFirstFailure`, which is on by default for SwiftPM, a killed mutant's run stops at its first
failed test, so its list can stop there too.

**Suspect tests.** Some tests fail whatever the mutant, because they are timing-sensitive or flaky
under the load of several workers. Such a test makes a mutant count as killed when no test checks
it, which raises the score. SwiftMutator calls a test *suspect* when it failed for mutants in at
least 15% of the files that have a killed mutant naming a test, and in at least 10 of those files.
A test of the mutated code rarely does that. With fewer than 10 such files the report gives no
verdict, and says so.

When there are suspect tests, the headline score, the killed count and the exit status stay as
they are. Every report also gives the score without the suspect tests, which counts each kill that
only suspect tests were recorded failing for as a survivor:

```
Of the 1103 mutants introduced into your code, your test suite killed 1024.
Mutation Score of Test Suite: 92%
Mutation Score without suspect tests: 72%
Suspect tests: 2 (testAnalyzeProjectPerformance(), everyFormatRendersTheSameBytesForAnyArrivalOrder()); see Killing Tests above
```

- **Where it's said.**
  - Plain text adds the two lines above under the score. Their prefixes don't change, so a script
    can look for them. The Killing Tests section says more.
  - HTML adds a "Without Suspect Tests" box beside the score, and the warning below to its
    summary.
  - The Xcode format adds `Mutation score without suspect tests: 72` (`at least 72` when it is a
    lower bound) and the warning as one `warning: SwiftMutator: …` line, with no file or line.
  - JSON marks each such kill `"killedOnlyBySuspectTests": true`, and gives the score in
    `killingTestSummary`.
- **The warning.** The console says it too:
  - A finished run prints it after its report, or after where it saved the report.
  - A run that stops early prints it on standard error, after the score so far.
  - `swift-mutator report` prints it on standard error without the emoji, so standard output holds
    the report alone.

  ```
  ⚠️ 2 tests may fail whatever the mutant: they failed for mutants in at least 15% of the 132 files with a killed mutant (testAnalyzeProjectPerformance() in 128, everyFormatRendersTheSameBytesForAnyArrivalOrder() in 60). Without their failures, the mutation score would be 72%, not 92%.
  ```
- **"At least".** A kill that only suspect tests were recorded failing for may have stopped at its
  first failed test, so another test might have failed for it too. The score without suspect tests
  is then a lower bound, and the reports say "at least 72%".
- **What to do.** A suspect test is a suspicion, not a verdict. A broad end-to-end or golden-output
  test can fail for mutants in that many files, and be right to. If a suspect test also fails
  without a mutant, under the same load, leave it out of mutation runs. SwiftMutator sets the
  environment variable `IS_MUTER_RUNNING` to `YES` for the baseline and every mutant's test run, so
  a test can skip itself there:

  ```swift
  @Test(.disabled(if: ProcessInfo.processInfo.environment["IS_MUTER_RUNNING"] == "YES", "Flaky under load"))
  func analyzesTheProjectInTime() async throws { … }
  ```

  In XCTest, start the test with
  `try XCTSkipIf(ProcessInfo.processInfo.environment["IS_MUTER_RUNNING"] == "YES")`.
- **Limits.**
  - The thresholds are fixed, from one project's runs. In SwiftProjectLint's, no test of the
    mutated code reached more than 8.8% of the files, in whole runs or in 1,634 smaller ones. The
    tests that failed under load reached 23–97%.
  - The rule misses a test that fails in fewer than about 3% of runs, or about 5% when runs stop
    at their first failed test. Such a test is worth about 1 point of score at most: on
    SwiftProjectLint, 0.16.

## Stopping a run

Press Ctrl-C once to stop a run and keep what it tested. SIGTERM, which `kill` sends, and SIGHUP,
which a closed terminal sends, stop it the same way. SwiftMutator then:

1. Stops the test runs under way and kills every process it started, so no test runner is left
   running. A test run that the stop ended is never recorded, so it can't count as a killed mutant.
   What it had written stays in `running/` in the log folder.
2. Says on standard error that it is stopping. Standard error reaches the terminal even when the
   same Ctrl-C has ended a `| tee`.
3. Ends `results.jsonl` with an `end` line whose `detail` names the signal, such as `"SIGINT"`, and
   writes the partial report described below.
4. Says on standard error how many mutants it tested, the mutation score so far, where the results
   file is, the `swift-mutator report` command that makes a report of them all from it, in any
   format, and the command that continues the run (see [Resuming a run](#resuming-a-run)). The
   commands are left out when no mutant has a result, or when the results file couldn't be written
   in full. A run of a test plan (`run-without-mutating`) can't be resumed, so it gets no command
   to continue it.
5. Removes its worker clones, `<project>_mutated_worker<n>`, and the active-mutant files beside the
   mutated project and the clones. The mutated project, `<project>_mutated`, is kept, as after a
   finished run.
6. Exits by the same signal, so the shell sees status 130 for SIGINT, 143 for SIGTERM or 129 for
   SIGHUP, and a script or loop that runs SwiftMutator stops too.

A stop before the baseline has passed, or during the timed test run after it, has nothing to keep:
the results file starts only after both.

- **The partial report.** With `-o report.txt`, the mutants tested so far are reported in
  `report.partial.txt` beside it, in the format `-f` chose, and `-o report` gives `report.partial`.
  The stop never writes or removes `report.txt`, so a complete report from an earlier run is kept.
  A later run that finishes leaves an old partial report alone. Without `-o` there is no partial
  report: the summary and `results.jsonl` say what was tested, and `swift-mutator report` makes a
  report from `results.jsonl` in any format. If no mutant had finished, there is no partial report
  either.
- **Stopping at once.** Press Ctrl-C again, or send any second SIGINT, SIGTERM or SIGHUP, to stop at
  once. Ctrl-\\ (SIGQUIT) stops at once even as the first signal. SwiftMutator does the same by
  itself if stopping takes more than 30 seconds. It still kills every process it started, ends
  `results.jsonl` with an `end` line whose `detail` names the first signal, unless it had already
  written one, and exits by the first signal. But the partial report is there only if it had
  already written it, and worker clones and their active-mutant files can be left behind. A SIGHUP
  after a first SIGHUP is ignored, because zsh sends two when its terminal closes: closing a
  terminal stops a run the same way as one Ctrl-C.
- **Suspending.** Ctrl-Z suspends SwiftMutator with every process it started, which the terminal's
  Ctrl-Z doesn't reach: each leads a process group of its own. `fg` or `bg` continues them all. No
  time limit counts the time suspended, and no test run's duration includes it, though a test that
  measures time itself can still see it pass. Under xcodebuild, a simulator runs the tests in a
  process of its own, which SwiftMutator didn't start, and doesn't suspend. A run that is
  stopping isn't suspended: it is about to end.
- **Leftovers.** The next `run` removes `<project>_mutated` and any worker clones and active-mutant
  files an earlier run left behind, such as one stopped at once, killed with SIGKILL, or crashed.
  SwiftMutator can't handle SIGKILL or a crash itself, so once its tests start, it starts a watcher,
  `swift-mutator watch-test-processes`, which kills the test processes of a run that dies, as soon as
  it dies, and ends with SwiftMutator. If the watcher is killed too, as by `killall -9 swift-mutator`,
  the lock file lists them, and the next command to take the lock kills them before it removes or
  uses anything they run in.
- **`nohup` and scripts.** A signal that was ignored when SwiftMutator started stays ignored. So a
  run started with `nohup` outlives its terminal, and SIGINT and SIGTERM still stop it. In a script,
  a run started in the background with `&` ignores SIGINT: stop it with SIGTERM.
- **Errors.** When an error stops mutation testing, such as 5 build errors in a row, SwiftMutator
  writes the same summary and partial report, then shows the error and exits with status 255. A
  signal that comes after the error, such as a Ctrl-C while the worker clones are removed, doesn't
  hide it: SwiftMutator still shows the error, then exits by the signal.
- **Pipes.** SwiftMutator ignores SIGPIPE, so piping its output into `head`, or quitting a `less` it
  writes to, doesn't stop a run: it runs to the end and still writes its results file and report.

## Resuming a run

`run --resume` continues a stopped run. A stopped run's summary ends with the command, which repeats
the run's own arguments, ready to paste:

```
⏹ Stopped by SIGINT after testing 1103 of 2497 mutants. Mutation score so far: 61%.
📝 Partial report: report.partial.txt
💾 Each tested mutant's result is in /…/SwiftProjectLint_muter_logs/Oct 6, 2026 at 9:12 AM/results.jsonl
📝 Full report: swift-mutator report '/…/results.jsonl'
▶️ Continue: swift-mutator run --skip-coverage -o report.txt --resume '/…/results.jsonl'
```

`--resume` takes the results file, or the log folder that holds it. SwiftMutator copies, discovers
and builds the project as any run does, then says which results it keeps:

```
♻️ Resuming the run in /…/results.jsonl: 1098 results still hold, so 1399 mutants are left to test (1394 never tested, 5 build errors).
```

It runs the baseline again and tests only the mutants left, which are what the progress bar, or the
line per mutant, counts. Their results go into the same file, as a new session, so the file stays in
the first session's log folder. The report at the end covers every mutant, kept or tested, and so
does `swift-mutator report` of the file.

- **What it saves.** The copy, the build, the baseline and the worker clones are made again. On
  SwiftProjectLint's 2,497 mutants on 6 October, on an 8-core Mac, they took 5–9% of a run, so
  resuming a run stopped halfway should have saved about 33–46 minutes, roughly 46% of a new run.
  On 31 October, on an 18-core Mac, a whole 4-worker run took 27 minutes with 2 of setup, so it
  would save about 12. On a small project they are most of the run:
  for lab runs of 43 and 151 mutants, the estimate is 12–18%.
- **What it keeps.** A result is kept when discovery finds its mutant again in the same file, at the
  same place, with the same operator and the same change (`snapshot`), and the file's SHA-256 hasn't
  changed. Killed mutants, survivors and timeouts are kept: the score counts a timeout as a survivor,
  so a kept one can't raise it. These are tested again:
  - build errors, including test runs that couldn't start;
  - mutants in a file that changed, and mutations that changed;
  - mutants whose place and operator appear more than once in a file, as they share a switch ID;
  - mutants never tested, including any that discovery finds for the first time.
- **Coverage.** Each session gathers coverage again, unless `--skip-coverage` is given, and
  discovers mutants by it. A result whose mutant this session no longer discovers is dropped,
  neither kept nor tested. SwiftMutator warns of that, and of a session that discovers more or fewer
  mutants than the last one, or has coverage the last one didn't, or the reverse. Discovery can also
  change when `swift package describe` works in one session only, or git lists the project in one
  only. SwiftMutator names the coverage change when that can explain the count:
  `⚠️ 412 earlier results no longer count, as this session doesn't discover their mutants: coverage
  couldn't be gathered then, and is now.`
- **Stopping again.** A resumed run stops as any run does. Its summary counts what it tested apart
  from what it kept, `⏹ Stopped by SIGINT after testing 197 of the 1399 mutants left: 1295 of 2497
  have results.`, and ends with the command that continues it, as often as needed.
- **A finished run** can be resumed too. Only its build errors and newly discovered mutants are
  tested, so this is how to test build errors again. With nothing left to test, it says `nothing is
  left to test`, builds nothing, runs no baseline and prints the report.

### When a resume is refused

A result is reused only if this run would give the same one, so SwiftMutator compares this run with
the file's last session. It checks before it removes or copies anything, and names every reason in
one message:

```
SwiftMutator won't resume the run in '/…/results.jsonl', so that no result is reused that this run might not reproduce:
  - mutationTestTimeout was 60 and is 120 now. A configuration change needs a new run.
  - The toolchain (toolchain.testCommandVersion) was "Apple Swift version 6.3.3 …" and is "Apple Swift version 6.4 …" now. --force-resume reuses the results anyway.
  - 2 project files changed since the run stopped: README.md (changed), notes.txt (added).
    If they can't change any test's result: --resume-ignoring 'README.md' --resume-ignoring 'notes.txt'
    Mutants in a changed source file are tested again either way.
Nothing was copied or removed.
```

It then exits with status 255, as after an error, but without asking for a bug report. A project
file that changes while SwiftMutator copies the project is refused after the copy, so that message
doesn't end with `Nothing was copied or removed.`

| Since the last session | Resuming |
|---|---|
| A configuration key changed, other than `mutationTestWorkers`, `stopAtFirstFailure` and `buildTimeout` | Refused: start a new run |
| `--operators`, `--files-to-mutate` or `--skip-coverage` changed | Refused: start a new run |
| `--since`'s merge base or `--changed-lines` changed, or `--since` given in one session only | Refused: start a new run. `--reuse` doesn't compare them |
| `mutationTestWorkers`, `stopAtFirstFailure` or `buildTimeout` changed | Goes ahead, and says so: `ℹ️ mutationTestWorkers was 4 and is 2 now, which no result depends on.` |
| SwiftMutator, the toolchain or the SDK changed | Refused, unless `--force-resume` is given |
| Project files changed, were added or were removed | Refused, unless a `--resume-ignoring` glob matches each one |
| Another SwiftMutator holds the file, because its run is still going | Refused, naming the process and host that wrote the file's last session |
| Coverage was gathered in one session only, or this session discovers other mutants | Goes ahead, and warns: `⚠️ 412 earlier results no longer count, as this session doesn't discover their mutants: coverage couldn't be gathered then, and is now.` |

A run of a test plan (`run-without-mutating`) can't be resumed, nor can a results file written
before `--resume` existed, as it records no project files. `-o` can't name the results file itself.
`--force-resume` and `--resume-ignoring` work only with `--resume`; without it they are a usage
error, with status 64.

- **`--force-resume`** reuses the results although the SwiftMutator build (its executable's
  SHA-256), the test command's version (`swift --version` or `xcodebuild -version`) or SHA-256, or
  `SDKROOT`, `DEVELOPER_DIR` or `TOOLCHAINS` changed. A value that couldn't be read counts as changed.
  Rebuilding SwiftMutator from the same code at the same path gives the same SHA-256, so it needs no
  force, but a build at another path gets a different one. The session's header records what it ran
  with, so the command that continues it leaves `--force-resume` out.
- **`--resume-ignoring <glob>`** reuses the results although project files the glob matches changed.
  It can be given more than once. Quote a glob, so that the shell doesn't expand it. `*` also matches
  `/`, so `--resume-ignoring 'Docs/*'` matches every file under `Docs`, and `'*.md'` every Markdown
  file. A leading `./` is ignored. The command that continues the run keeps these flags, as the same
  files may well change again.
- **Which files count.** The files git lists in your project, tracked ones and untracked ones that
  aren't ignored, plus every Swift file and `.swift-version`, and the root `Package.resolved`, ignored
  or not. Outside a git repository, or in a folder that its repository ignores, every file. Build
  products, such as `.build`, never count, and nor does the configuration file the run loads, such as
  `muter.conf.yml`: its settings are compared one by one, as the table above says.
  [Project](Docs/results-file.md#project) has the details.
- **Local packages outside the project count too.** SwiftMutator copies only your project, so a
  package that a `Package.swift` names with `.package(path: "../Core")`, or an Xcode project with a
  local package reference, is built from where it is, as it is then. Its files count under their
  path from the project, such as `../Core/Sources/Core/Core.swift`. Only literal paths are followed.
  Nothing else outside the project counts, such as sources an Xcode project references there: after
  changing a file like that, which a test can read, start a new run rather than resume.
- **A waiver is your call.** Mutants in a changed Swift file are always tested again, but a change
  can also change the results of mutants elsewhere: a test file, a fixture a test reads, or a source
  file the mutated code calls. Waive only files that no test's result depends on.

## Reusing an earlier run

`run --reuse` starts a new run from an earlier run's results, so a run after a small change tests
only what the change can affect ([#71](https://github.com/Joseph-Cursio/SwiftMutator/issues/71)).
It takes the earlier run's results file, or the log folder that holds it, finished or not, and
writes a results file of its own in its own log folder: the earlier file is only read.

```
swift-mutator run --skip-coverage -o report.txt --reuse '/…/Oct 31, 2026 at 7:08 PM/results.jsonl'
♻️ Reusing the results in /…/results.jsonl: 1816 results still hold, so 647 mutants are left to test (9 timeouts, 638 as test files changed).
ℹ️ 1 test file changed, so every survivor is tested again, and every kill that no unchanged test still holds.
```

It checks the earlier run as a resume does (see [When a resume is refused](#when-a-resume-is-refused)),
with `--force-reuse` for `--force-resume`. Changed project files never refuse it. Instead they decide
which results it keeps, for each result by what changed since the session that tested it:

- **What it keeps.** A result that a resume would keep: same file, place, operator and change, and
  the file's SHA-256 unchanged. Then:
  - **A timeout** is always tested again: it may have been the load the earlier run was under.
  - **A changed file other than a test file**, such as another source file, `Package.resolved` or a
    fixture, can change any mutant's result, so every result tested before the change is tested
    again. SwiftMutator names the files, with the `--reuse-ignoring` flags that would let them
    through.
  - **Changed test files** test every survivor again, as a changed test can kill it. A kill is kept
    if one of the tests that killed it still holds: its issue was recorded in a test file that is the
    same, unchanged, in both runs (Swift Testing names it, by its name alone, which must be the only
    file of that name), that file still declares the test, no changed test file names the test, and
    the file doesn't name the type of a changed test file, by its file's name up to any `+`, as
    `ParsingTests+Helpers.swift` extends `ParsingTests`. A kill by XCTest
    tests, whose lines name no file, is tested again.
  - Anything else is kept.
- **Test files** are the Swift files that import Testing or XCTest, in a folder named `Tests` or
  ending in `Tests`, such as `MyAppTests`, or outside them if their names end in `Tests.swift`. A
  test's fixtures and resources aren't test files, Swift ones included, nor are helpers that import
  neither, as a test file can't name what it reads from them, so their changes count as other files'.
  So does a removed Swift file in a test folder, or named like a test, as nothing shows what it was,
  and no glob lets its removal through. A local package's own tests, outside the project, are left
  out: the project never builds them. In an Xcode project, adding or removing a test file changes
  `project.pbxproj`, which isn't a test file, so every result is tested again.
- **`--reuse-ignoring <glob>`** lets changes to files other than test files through, as
  `--resume-ignoring` does for a resume. It never lets a test file's change through.
- **The baseline** runs whenever anything changed, even when every result is kept, so a changed test
  that now fails stops the run. Only with no change at all, and nothing to test, does it run none.
- **The new file** starts with the results it keeps, each with `reusedFrom`, which says where it was
  tested ([Mutant](Docs/results-file.md#mutant)), and their logs are copied into the new log folder.
  So the new file stands alone: `swift-mutator report` of it gives the run's own report, and a later
  `--reuse` or `--resume` of it works as of any run's. A stopped reuse continues with
  `--resume` of the new file, which its Continue line names, with each `--reuse-ignoring` as a
  `--resume-ignoring`. Stopped before its baseline passed, it has no file yet: run the same
  `--reuse` command again.
- **The reports mark reused results.** The plain and HTML reports add a Reused column, with "yes",
  or "yes, despite changes" for a result that `--reuse-ignoring`, `--force-reuse` or their resume
  counterparts let a change through for since it was tested; a waiver marks only the results tested
  before the change it let through. The JSON report gives each its
  `reusedFrom`. The Xcode format doesn't mark them.
- **Run a full run now and then**, for example weekly. A result can depend on code the rules above
  can't see changed, such as a test helper whose type isn't named after its file, and the timeouts'
  load differs from run to run.
- **What it saved on SwiftProjectLint**, with 4 workers: with nothing changed, 4.2 min against
  27.3 min for a full run; after one test file changed, 19.0 min against 26.6 min, as it tests every
  survivor again. Every result it kept matched a full run's
  ([Docs/reuse-2026-10.md](Docs/reuse-2026-10.md)).
- **Same machine.** The configuration's `executable` and `arguments` are compared exactly, as for a
  resume, so a results file from another Mac, with other paths, is refused.

## Development

`make test` runs the unit tests (the `muterTests` target). CI runs them on every pull request
and every push to `main`, on two Xcode versions (see [ci.yml](.github/workflows/ci.yml)).
[CONTRIBUTING.md](CONTRIBUTING.md) covers the acceptance and regression tests, which CI doesn't
run.

## License

MIT, as Muter is. See [LICENSE](LICENSE).
