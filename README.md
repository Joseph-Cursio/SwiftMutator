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
- **Mutants inside macros:** a mutant in a macro's arguments, as in `#Predicate { $0.id == id }`, is
  switched around the macro, not inside it, where the macro would expand the switch along with the
  mutant and fail to build. A body whose value is the macro returns it from each branch. A macro at a
  file's or a type's top level, such as `#Preview`, has nothing around it that can hold a switch, so
  its mutants are left out.
- **Parallel workers:** `mutationTestWorkers: N` tests N mutants at once on SwiftPM projects,
  each in its own APFS clone of the mutated project. Each clone is built once before testing, which
  costs one extra build per worker but keeps tests that write files next to their sources from
  sharing them across workers. An xcodebuild project that tests on a simulator gets one simulator
  per worker instead, from one build (see [xcodebuild workers](#xcodebuild-workers)).
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
  based on how long your tests take, so a mutant that loops forever can't hang the run.
  SwiftMutator times one run of a mutant's test command with no mutant on, just after the
  baseline, and allows 5× that, once more for each worker beyond the first, and at least 20 s.
  For a SwiftPM project that run is the test bundles run directly or `swift test … --skip-build`.
  For an xcodebuild project it is `test-without-building` from `muter.xctestrun`, with no mutant
  switched on, on the first worker, after the workers' runs with no mutant on, so it doesn't pay
  for a simulator's first install and launch. For another build system, or when that run fails, it
  allows 3× the baseline, build included, and at least 10 s, or 3× a lone xcodebuild worker's run
  with no mutant on, on [a simulator of its own](#one-worker-on-a-simulator-of-its-own), when that
  took longer: the baseline may have spread its tests over parallel testing's clones, and the
  worker tests one at a time. A timeout counts as a survivor, so if your tests set limits of their
  own, such as Swift Testing's `.timeLimit`, which is at least a minute, set `mutationTestTimeout`
  above them: otherwise a mutant that only your tests' limit would catch ends as a timeout. With
  several workers, each timeout is run again at lower load once the other mutants are tested: see
  [Timeouts are run again](#timeouts-are-run-again).
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
  with mutants that can't be read. Under xcodebuild, a mutant whose `muter.xctestrun`, or its
  worker's `muter-worker<n>.xctestrun`, can't be written stops mutation testing, since the file
  left by the run before would switch that mutant on. These prove a switch is there, not that a
  run switched it on.
- **xcodebuild mutant runs leave no derived data behind:** each mutant's `xcodebuild
  test-without-building` keeps its derived data in `<project>_mutated.DerivedData`, beside the copy,
  emptied before each run and removed when the run ends, and each other worker's in
  `<project>_mutated_worker<n>.DerivedData`. Muter's runs each add a folder of 3–67 MB
  to `~/Library/Developer/Xcode/DerivedData`, which nothing removes. The runs
  also pass `-collect-test-diagnostics never`, so a failing run doesn't spend seconds collecting
  diagnostics no one reads, but only when `executable` lists that option in its `-help`, which
  SwiftMutator asks once per run. Without it, as for an older Xcode or a wrapper that doesn't pass
  it on, the runs collect diagnostics as before.
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
leaves everything as it was. It exits with status 6: run the same command again once that run has
ended. The lock goes when SwiftMutator exits, however it exits, so it never needs clearing; the
file stays, made with the permissions your umask gives new files, so anyone who can remove the copy
can lock it.

`swift-mutator mutate-without-running` writes a test plan without testing anything, and
`swift-mutator run-without-mutating` tests it (see [Test plans](#test-plans)). `--mutant` tests one
mutant on its own (see [Testing one mutant](#testing-one-mutant)).

### Exit status

`run`, `mutate-without-running` and `run-without-mutating` exit with:

- **0** when the run finished, whatever its score, and when there is nothing to mutate, as for a
  `--since` change with no Swift file, or a `--shard` that holds no mutant.
- **5** when a `--resume` or `--reuse` is refused, as the results might not hold for this run
  (see [When a resume is refused](#when-a-resume-is-refused)). Nothing was tested. The message says
  what would let it through, such as a flag; a new run without `--resume` or `--reuse` isn't
  refused for these reasons.
- **6** when another SwiftMutator run holds a lock this one needs: on the project's copy, or on the
  results file that `--resume` names. The same command goes ahead once that run has ended.
- **7** when `run-without-mutating` refuses a test plan that might not describe the project, or
  can't be tested as it is: one in a newer format, run in another folder than its project's that
  has a configuration, one whose mutated files changed in the project since it was made, or whose
  copy of the project isn't there (see [The test plan](Docs/test-plan.md#when-a-plan-is-refused)).
  Nothing was tested. The message says what would let it through, such as `--plan-ignoring`. A
  folder without `muter.conf.yml`, and no `--configuration`, stops on that first, with 255.
- **64** for a usage error, such as `--workers 0`. `run-without-mutating` without a test plan's
  path exits with 1.
- **255** for any other error, a failed baseline and an abort, such as 5 build errors in a row,
  included.
- **128 plus the signal** when a signal stopped the run: 130 for SIGINT, 143 for SIGTERM and 129 for
  SIGHUP (see [Stopping a run](#stopping-a-run)).

Earlier SwiftMutators exited with 255 for a refused resume or reuse, and for a run refused by
another's lock, so a script that checked for 255 there needs to check for 5 and 6 instead. `report` has statuses of its
own (see [Results file](#results-file) and
[Exit status](Docs/results-file.md#exit-status)).

## Test plans

`swift-mutator mutate-without-running` makes the copy, puts every mutant's switch into it, and
writes a test plan, `muter-mappings.json`, without testing anything, so you can fix the copy by hand
first, such as code the rewriting left unable to compile. `swift-mutator run-without-mutating
muter-mappings.json` then tests it. See [The test plan](Docs/test-plan.md).

- **Choosing the mutants.** Like `run`, `mutate-without-running` takes `--files-to-mutate` and
  `--operators`. The plan records them, and so does the results file of a run that tests it.
- **Fixing the copy by hand.** The run tests the copy as it is, and says which files with mutants
  differ from what `mutate-without-running` wrote. Its results file records each file's SHA-256 as
  tested.
- **Run it from the project folder,** as `mutate-without-running` was: the plan's paths are
  relative, and it finds its copy and loads `muter.conf.yml` from there. The configuration comes
  first: a folder without one, as the project's `Sources`, stops on the missing file, with exit
  status 255, before the plan is read. A folder with a configuration that holds none of the files the
  plan mutates is refused, with exit status 7.
- **A changed project.** A file the plan mutates that changed in the project since the plan was made
  refuses the plan, with exit status 7. Make the plan again, or give `--plan-ignoring <glob>` to test
  the copy as it is. A change to any other file, such as a test, is only said.
- **Resuming.** A stopped run of a plan is continued by `run-without-mutating` with the same plan and
  `--resume`, as its summary's Continue line gives it (see
  [Resuming a run of the plan](Docs/test-plan.md#resuming-a-run-of-the-plan)).
- **One mutant.** `run-without-mutating muter-mappings.json --mutant <mutant>` tests only that
  mutant of the plan, in the plan's copy as it is, and leaves the copy unchanged (see
  [Testing one mutant](#testing-one-mutant)).
- **A later run removes the copy.** A later `swift-mutator run` or `mutate-without-running` of the
  project removes `<project>_mutated`, with any fix in it. `run --mutant` doesn't: it has a copy of
  its own.

## Testing one mutant

`--mutant` on `run` or `run-without-mutating` tests one mutant on its own: to check a verdict, a new
test meant to kill it, or a fix made by hand in a test plan's copy. Name it as the progress lines
and reports name it, `path:line[:column] [Operator]`, with as much of its path as tells its file
apart:

```
swift-mutator run --mutant 'Rules.swift:42:17'
swift-mutator run-without-mutating muter-mappings.json --mutant 'Sources/Foo/Rules.swift:42:17 RelationalOperatorReplacement'
```

It runs the baseline, then the mutant's tests with `stopAtFirstFailure` off, so the log names every
test that fails, and prints, in place of the report:

```
🔬 Sources/Foo/Rules.swift:42:17 RelationalOperatorReplacement (changed == to !=)
Switch: Rules_9c41…_RelationalOperatorReplacement_42_17_1388
Change:
  -42:         guard rule.kind == .error else { return }
  +42:         guard rule.kind != .error else { return }
Tests (log: /…/Foo_muter_logs/…/RelationalOperatorReplacement @ Rules.swift-42-17 9c41….log):
  ✘ Test errorsAreReported() recorded an issue at RulesTests.swift:12:9: Expectation failed
  …
Verdict: killed by errorsAreReported() (1 failed test), in 3.8 s
Mutated project kept, with the mutant switched off: /Users/me/Foo_mutant
To run its tests with it on:
  printf '%s\n' 'Rules_9c41…' > '/Users/me/Foo_mutant.active-mutant' && cd '/Users/me/Foo_mutant' && IS_MUTER_RUNNING=YES SWIFTMUTATOR_ACTIVE_MUTANT_FILE='/Users/me/Foo_mutant.active-mutant' /usr/bin/swift test
```

- **The change** is the mutant's line in your project's file, before and after. When that line
  can't be found, as for code that spans lines, or a plan's file that changed since the plan was
  made or that the plan doesn't record, as a plan in format 0 doesn't, it is the code the mutant
  changes, as the mutant records it.
- **The log** is printed whole up to 400 lines, and otherwise from its last 200; the log folder
  keeps it whole.
- **Exit status** is 0 whatever the verdict, which the results file records too. A reference that
  doesn't read as a mutant is a usage error, 64. One that names no mutant exits with 255 and lists
  the mutants near it, ready to paste, whatever operator it names, and one that names several lists
  them. One of several mutants an operator makes at the same place is refused too: they share one
  switch, so none can be tested on its own, and the lists name such a place without a `--mutant`
  to paste. An absolute path may be spelled through a link, as `/tmp` is `/private/tmp`.
- **`run --mutant`** skips coverage, finds every mutant, and puts only that mutant's switch into a
  copy of its own, `<project>_mutant`, which it keeps for a look afterwards. A test plan's
  `<project>_mutated`, and any fix in it, is left alone. `<project>_mutant` stays until the next
  `run --mutant`.
- **`run-without-mutating --mutant`** tests the plan's copy as it is, without rewriting it. The
  project is checked against the plan as for a whole run, but only a change to that mutant's file
  refuses it: one to a file with the plan's other mutants is only said.
- For an xcodebuild project, only the switch's environment variable is named, not a command.
- `--mutant` can't be given with `--operators`, `--files-to-mutate`, `--since`, `--shard`,
  `--sample`, `--resume` or `--reuse`. A run of one mutant prints no Continue line: the same command
  tests it again. Its reports, the one `-o` saves and those `report` makes of its results file,
  say its score isn't the project's, and the JSON report gives the mutant as `mutant`.

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
| `mutationTestWorkers` | How many mutants to test at once (SwiftPM projects, and xcodebuild projects that test on a simulator, which get one simulator per worker; default 1) |
| `mutationTestTimeout` | Seconds before a mutant's test run is stopped (default: based on a timed test run; see above) |
| `oneWorkerSimulator` | Whether one xcodebuild worker tests on a simulator SwiftMutator makes (absent: when the project and its baseline show it is faster; true: whenever the destination is a simulator; false: never; see [One worker on a simulator of its own](#one-worker-on-a-simulator-of-its-own)) |
| `stopAtFirstFailure` | Stop a mutant's test run at its first failed test, or at a test process's crash, either of which already decides that it is killed (SwiftPM projects only; never the baseline; default true) |
| `suspectTestFilePercent` | The share of the files with a killed mutant naming a test, from 1 to 100, that a test must have failed for mutants in to be suspect (default 15; see [Killing tests and suspect tests](#killing-tests-and-suspect-tests)) |
| `suspectTestMinimumFiles` | How many files with such a kill there must be, at least 1, before a test can be suspect, and how many of them it must have failed for mutants in (default 10) |
| `controlRunEvery` | How many mutants to test for each control run, a run with no mutant on among theirs, whose failed tests are flaky (a whole number; 0 for none; default 100; see [Control runs](#control-runs)) |
| `buildTimeout` | Seconds before the coverage run, which builds your project and runs its tests with coverage on, is stopped. Mutation testing then goes on without coverage, as after any coverage failure. For now it limits only the coverage run, not the baseline or other builds (default: no limit) |

`--workers N` and `--timeout S`, on `run` and `run-without-mutating`, set `mutationTestWorkers`
and `mutationTestTimeout` for one run, in place of the file's
([#73](https://github.com/Joseph-Cursio/SwiftMutator/issues/73)). `--workers` must be at least 1,
and `--timeout` above 0 and at most a day, 86,400 seconds. The run records and compares them as it does the keys: a resume with a
`--timeout` at least as long as every session's limit tests only the timeouts again (see
[Timeouts are run again](#timeouts-are-run-again)), one that is shorter is refused, and another
`--workers` is only said. A run that tests several mutants at
once says so, and one that uses fewer workers than asked says why:

```
👷 Testing 3 mutants at a time, though 4 workers were asked for: only 3 are left to test.
👷 Testing one mutant at a time, though 4 workers were asked for: a Mac app's test runs share its UserDefaults, saved state and container, so workers would see each other's.
```

### Timeouts are run again

With every worker's tests competing for the same cores, a slow test can pass the time limit that it
keeps to under less load, and its mutant ends as a timeout, which the score counts as a survivor
([#76](https://github.com/Joseph-Cursio/SwiftMutator/issues/76)). So a run on several workers runs
each of its timeouts again once every other mutant is tested: in job order, on a quarter of the
workers, at least one, and under the same limit. A mutant that loops forever times out again, at
the cost of a second limit; one that was only slow is killed or survives. The progress bar and lines
don't count the reruns, which are said apart:

```
🔁 Running 19 timeouts again, one at a time, under the same 24 s limit: at most 8 min.
🔁 1 of 19 survived at ConfigurationPersistenceProtocol.swift:36:56 (removed line), in 13.3 s
…
🔁 6 of 19 timed out again at LargeStackWorkers.swift:103:31 (removed line), in 24 s
…
🔁 Ran 19 timeouts again, and 15 changed: 15 survived, 4 timed out again.
```

That was SwiftProjectLint's `--sample 200 --seed 157871` under `--timeout 24`, on 4 workers, where
one test run alone takes about 14 s. The reruns took 5 of the run's 15 minutes. All 15 that changed
survive in a whole run under the default limit, and of the 4 that timed out again, 3 time out there too;
the fourth is killed there, after more than 24 s.

The rerun's result is the one the report gives. The results file keeps both: the rerun's line, with
`rerun`, follows the first run's, and each names a log of its own, the rerun's with ` (rerun)` before
`.log` (see [Docs/results-file.md](Docs/results-file.md)). A run on one worker, as an xcodebuild
run that doesn't test on a simulator always is, has no lower load to offer, and runs nothing again.

A timeout that holds up at lower load may still be a mutant that only takes longer than the limit,
such as one whose tests fail after a slow retry. To give the timeouts more time without testing
everything again, resume the run with a longer limit: `--resume` with a `--timeout` at least as long
as the limit of every session in the results file, which its header records as `timeoutSeconds`. It
goes ahead, tests every timeout under a shorter limit again, and keeps every other result, as a run
that ended in time ends the same under a longer limit:

```
♻️ Resuming the run in /…/results.jsonl: 196 results still hold, so 4 mutants are left to test (4 timeouts under a shorter limit).
ℹ️ mutationTestTimeout was not set and is 60 now, no shorter than any session's limit: the timeouts under a shorter one are tested again.
```

A shorter limit is refused, as a result that ended in time under the longer one may not under it,
and so is a resume without `--timeout` after one with it, as the default only the baseline sets, and
a new limit for a file that holds results `--reuse` kept, as it doesn't record the limit they were
tested under. A finished run can be resumed this way too. `--reuse` takes a longer limit by the same
rule, and tests every timeout again in any case.

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

#### xcodebuild workers

An xcodebuild project whose first `-destination` is a simulator, such as
`platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5`, or one named by its `id=` alone, tests N
mutants at once with `mutationTestWorkers: N` or `--workers N`
([#103](https://github.com/Joseph-Cursio/SwiftMutator/issues/103)). With one worker, the default,
SwiftMutator also tests on a simulator of its own when that should be faster: on
MacCloud_client_iOS, a mutant's run took 7 s on one, against 22 s on the destination (see [One
worker on a simulator of its own](#one-worker-on-a-simulator-of-its-own), below).

- **One simulator per worker, worker 0 included,** like the one the destination names, which no
  mutant runs on. Before the baseline, SwiftMutator makes them, named
  `swiftmutator-<project hash>-<pid>-<start>-w<n>`, and boots them while the baseline builds and
  runs. SwiftMutator never shuts your own simulator down: if it is shut down, each is a clone of
  it, with its settings and data; if it is booted, a booted simulator can't be cloned, so each is
  a new one of its kind and runtime, without your simulator's data, such as its locale, keychain,
  permissions and installed apps. The baseline is your own test command, though, so with parallel
  testing on, xcodebuild shuts your simulator down to clone it, as it does without SwiftMutator. Every one is deleted when the run ends (see [Stopping a run](#stopping-a-run)).
- **One build.** Every worker tests in the mutated project, from the build the baseline made, so
  no copy is made or built. Each has its own `.xctestrun`, `muter.xctestrun` for worker 0 and
  `muter-worker<n>.xctestrun` for the others, which its mutant is switched on in, and its own
  derived data. Paths compiled into the tests, such as `#filePath`, point into the mutated project,
  so tests that write next to their sources share those files across workers; on iOS, a test's
  writes to its app's container are its simulator's own.
- **Tests run one at a time within a worker**, with `-parallel-testing-enabled NO`, as they do on
  a lone worker's simulator. Otherwise xcodebuild shuts each worker's simulator down and clones it
  again on every run. That can make a
  large suite slower per run, and tests that depend on their order can give other verdicts than
  on one worker.
- **A run with no mutant on, on each simulator,** follows the baseline, all at once and with no
  time limit, so no mutant's limit pays for a simulator's first install and launch, which took 30
  to 93 s. Its log is kept as `no-mutant run worker <n>.log`. It shows that the tests pass one at a
  time on a simulator SwiftMutator made. A run of these that the simulator failed to launch runs
  again, once, as a mutant's does (below), and its log is kept with ` (launch failed)` before
  `.log`.
- **A fallback to one worker.** If the destination names no one simulator, or a simulator can't be
  made or booted, or a run with no mutant on fails, the simulators are deleted and the run tests
  one mutant at a time on your destination, as without workers, and says why:

  ```
  👷 Testing one mutant at a time, though 4 workers were asked for: worker 2's run with no mutant on, on its simulator, didn't pass (its log is no-mutant run worker 2.log).
  ```

  A lone worker falls back the same way, and says so:

  ```
  👷 Testing one mutant at a time on the test command's destination: worker 0's run with no mutant on, on its simulator, didn't pass (its log is no-mutant run worker 0.log).
  ```

  A Mac, Mac Catalyst, physical-device or `generic/…` destination always tests one at a time: a
  Mac app's test runs share its `UserDefaults`, saved state and container, and SwiftMutator makes
  only simulators.
- **A run the simulator failed to launch runs again**, once, on the same worker, as on one worker:
  its log shows no failed test, only such a line as `Application failed preflight checks`. The
  second run is the one recorded, and the first run's log is kept with ` (launch failed)` before
  `.log`. A run whose simulator is gone stops mutation testing, keeping the results so far, and
  keeps its log with ` (simulator gone)` before `.log`: resume it, and new simulators are made. If
  the simulator your `-destination` names was the one deleted, make it again first. A baseline the
  simulator failed to launch runs again too, once, on any number of workers, and its first log is
  kept as `baseline run (launch failed).log`.
- **Memory.** Each booted simulator holds memory. 2 to 4 workers suit most Macs.

##### One worker on a simulator of its own

`oneWorkerSimulator`, automatic by default. With parallel testing on in the scheme or test plan,
xcodebuild shuts your simulator down, clones it and boots the clone for every mutant's run, about
15 s each time. One worker skips that on a simulator SwiftMutator makes, as a worker's, which tests
one test at a time and stays booted. It does when the first `-destination` is a simulator, 6 or
more mutants are to test, and the scheme or test plan has parallel testing on for a test target, as
the `.xctestrun` the baseline builds shows, and says so:

```
👷 Testing one mutant at a time, on a simulator of its own.
```

- **It checks the baseline first.** The baseline's lines such as `Test case 'SumTests.sum()' passed
  on 'Clone 1 of iPhone 17 Pro - App (123)' (0.010 seconds)` show how many clones its tests ran on
  and how long they took, on the first `-destination`'s device, the only one a mutant's run tests
  on. If they spread more than 10 s of tests over several clones, which one at a time on one
  simulator could make slower, or the baseline printed no such line, the simulator is deleted
  before its run with no mutant on, and the run tests on your destination, saying why:

  ```
  👷 Testing one mutant at a time on the test command's destination: the baseline's parallel testing spread 42.5 s of tests over 4 clones, which one at a time on one simulator could make slower; `oneWorkerSimulator: true` tests on one anyway.
  ```
- **Arguments that tune parallel testing keep your destination.** `-parallel-testing-enabled YES`,
  `-parallel-testing-worker-count`, `-maximum-parallel-testing-workers` or
  `-parallelize-tests-among-destinations` in `arguments` reach only the baseline, never a mutant's
  run, so the baseline doesn't show how a mutant's run would test, and the run says so.
  `-parallel-testing-enabled NO` doesn't keep it: the baseline then runs one test at a time, and
  isn't checked.
- **The key.** `oneWorkerSimulator: true` uses a simulator whenever the destination is one and there
  are 2 or more mutants to test, without these checks; `false` never uses one. More than one worker
  uses simulators whatever it says.
- **What it leaves alone.** `--mutant` and a lone mutant to test run on your destination, as do Mac,
  Mac Catalyst, physical-device and `generic/…` destinations, and destinations that name no one
  simulator, such as a device's bare `id=`. None of them prints anything about it, but a destination
  that isn't one simulator, when `oneWorkerSimulator: true` asked for one, says why. A Mac, Mac
  Catalyst, physical-device or `generic/…` destination says:

  ```
  👷 Testing one mutant at a time on the test command's destination: a simulator of its own needs a first `-destination` that is a simulator.
  ```

  and one that names no available simulator, or more than one, such as a device's bare `id=`, says
  that:

  ```
  👷 Testing one mutant at a time on the test command's destination: no available simulator matches `-destination id=00008140-001A2B3C4D5E6F70`, or more than one does.
  ```
- **As with workers**, a booted destination gives a new simulator of its kind, without your
  simulator's data, and the simulator is deleted when the run ends.
- **Kills read differently.** A mutant that parallel testing reports as a crash of its test
  process, a `runtimeError` with no tests named, reads as `failed` on a simulator of its own, with
  the tests that killed it in `killedBy`. Which mutants are killed doesn't change.

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

## Splitting a run across machines

`run --shard k/n` tests only the kth of n shards of the mutants, so n runs, on as many machines,
test each mutant once between them
([#74](https://github.com/Joseph-Cursio/SwiftMutator/issues/74)). Every run still copies the
project, gathers coverage and runs the baseline, so two machines take a little more than half as
long as one.

```
swift-mutator run --shard 1/2
✅ In total, SwiftMutator discovered 2463 mutants, and shard 1 of 2 holds 1228 of them, in 287 files
```

- **Which mutants a shard holds** follows from where each one is, by a hash of its path, operator,
  line and column. No plan is passed between the machines: each discovers the mutants itself, and
  keeps its own. Every machine needs the same project, configuration, SwiftMutator build and
  toolchain: commit the configuration rather than running `init` on each machine, which writes the
  test command's full path, and build SwiftMutator once and share the binary, as every build has a
  SHA-256 of its own.
- **Shards are about even** in mutants, not in time: survivors take longest, and they fall where
  they fall.
- **A shard with no mutant isn't a failure.** With fewer mutants than shards, as for a small
  `--since` change, a shard can hold none. SwiftMutator then says so, writes no report or results
  file, and exits with 0. In CI, upload its results file with `if-no-files-found: ignore`.
- **`--shard 1/1`** is the whole run, so a matrix of one entry needs no special case.
- **One shard at a time on one machine.** Every shard of a project uses the same mutated copy,
  `<project>_mutated`, so a second one started while the first runs is refused.
- **It combines** with `--since`, `--changed-lines`, `--files-to-mutate` and `--operators`, which
  choose the mutants that are split.
- **Resuming.** The results file's header records the shard, and a resume must give the same one;
  the Continue line keeps it. `--reuse` keeps the earlier run's results for this shard's mutants,
  whichever shard, or whole run, that was.
- **The reports say so.** The plain and HTML reports say which shard was tested, of how many
  mutants in all, and the JSON report gives it as `shards`.
- **At most 1000 shards.** Each header counts every shard's mutants, so it stays short.
- **`report` merges the shards.** Give it every shard's results file, or log folder, and it makes
  the whole run's report, in any format:

  ```
  swift-mutator report shard-1/results.jsonl shard-2/results.jsonl -f html -o report.html
  Report of 2463 of 2463 mutants, merged from the results files of 2 of 2 shards.
  Shard 1 of 2, 1228 of its 1228 mutants, from shard-1/results.jsonl: the run finished.
  Shard 2 of 2, 1235 of its 1235 mutants, from shard-2/results.jsonl: the run finished.
  ```

  - **What it refuses.** It checks each shard against shard 1, or the lowest one given, as a
    resume checks a run: the configuration, the operators, `--files-to-mutate`, `--skip-coverage`
    and `--since`, the SwiftMutator build and the toolchain, and the project's files. It refuses
    files that aren't shards, shards of different splits, a shard given twice, a header whose
    counts don't hold together, and a mutant with a result in two files. `--force-merge` lets a
    different build or toolchain through, and `--merge-ignoring <glob>` project files that differ,
    such as a file one machine left in its checkout. Each refusal says which.
  - **What it says.** On standard error, as for one file: how many mutants the report covers, and
    how each shard's run ended and, if it was resumed or reused, which sessions tested its results.
    A shard whose file isn't given is named with the mutants it holds. A shard that holds no mutant
    has no file, and is only said.
  - **When it fails.** It exits with 255, as for a run that stopped on an error, whenever the
    report is known to lack results: a shard stopped on an error, has fewer results than mutants,
    as when its job was cancelled or killed, or holds mutants but its file isn't given. So a CI job
    that checks the merged report fails as one that checked every shard would.
  - **One shard's file alone** is a merge of one, so a CI glob that finds one file is judged as one
    that finds two: its report says it covers that shard, and `report` fails if the others hold
    mutants. If they hold none, as in a small `--since` change, it is the whole run's report. The
    merge flags are accepted with one file, and do nothing. With no file at all, every shard was
    empty, and there is nothing to report.
  - **The report** is the whole run's: the mutants in the order a whole run tests them, the
    coverage and paths of the lowest shard given, and the longest shard's time, as the shards are
    meant to run at once. If some shards are missing, it says which ones it covers. If the
    machines' coverage differed, so that their discoveries did, `report` says so: a mutant only
    some of them discovered may have no result.
  - **Not yet:** a merged results file. `--reuse` takes one shard's file, which keeps the results
    of that shard's mutants only.
- **In CI**, run the shards as a matrix, one job per shard, then merge them in a job after it.
  - Every shard needs the same binary: build SwiftMutator once, or install one release.
  - Each shard's results file is in `<project>_muter_logs/<run>/results.jsonl`, beside the
    checkout, and the run prints its path. Upload it, allowing for none, as an empty shard writes
    none.
  - The merging job downloads them, outside any checkout a later run uses, and gives them all to
    `report`. If none was written, as when every shard was empty, skip it: `report` given no file
    is a usage error, with status 64.
  - A worked GitHub Actions recipe is [#124](https://github.com/Joseph-Cursio/SwiftMutator/issues/124).

## Testing a sample of the mutants

`run --sample N` tests about N of the mutants discovered, as for a trend check between whole runs,
such as a nightly score ([#75](https://github.com/Joseph-Cursio/SwiftMutator/issues/75)). Every run
still copies the project, gathers coverage and runs the baseline, so a sample saves the time of the
mutants it leaves out.

```
swift-mutator run --sample 200
✅ In total, SwiftMutator discovered 871 mutants, and the sample of 200 holds 200 of them, in 76 files
🎲 SwiftMutator chose the sample's seed, 157871: --seed 157871 takes the same sample again.
```

On SwiftProjectLint, a sample of 200 of its 871 mutants took 16 minutes, stopped and resumed once,
where the whole run takes 46. It scored 78%, and the whole run 77%; the report gave the margin as
5.0 points. Every one of the 200 verdicts was the whole run's.

- **Which mutants** follows from the seed and where each mutant is, by a hash of the seed and the
  mutant's path, operator, line and column. The same seed takes the same sample on any machine, and
  after a small change mostly the same one, so a trend line moves with the tests rather than with
  the sample. Give `--seed S` to keep it; without one, SwiftMutator chooses one and says which.
- **About N:** a place's repeats are in the sample or out of it together, so it can hold a few more
  than N. With no more than N mutants, it holds them all, and is the whole run.
- **The reports say how close the score is.** The plain and HTML reports say the score is from a
  sample of N of M mutants, and give its 95% margin; the JSON report gives them as `sample`. The
  margin narrows with the finite-population correction. A run that stopped before every mutant had
  a result gets none: its results are the first files', not a random part of the sample. A shard's
  hash doesn't depend on the seed, so a shard's mutants are a random part of the sample: its own
  report, and a merge of some of the shards, give a margin from their results, unless a shard given
  has some of its results but not all.
- **It combines** with `--since`, `--changed-lines`, `--files-to-mutate` and `--operators`, which
  choose the mutants it is taken from, and with `--shard`, which splits the sample. A sampled split
  needs `--seed`, so that its shards share one sample, and `report` merges them.
- **Resuming.** The results file's header records the sample, and a resume must take the same one,
  so it needs `--seed`; the Continue line gives it, chosen or not. `--reuse` keeps the earlier run's results for
  this sample's mutants, whatever sample, or whole run, that was. After a change, new mutants can
  rank before some the sample took, and push them out. Their results no longer count, but they are
  said apart from those of mutants that are gone:
  `ℹ️ 2 earlier results no longer count, as the sample no longer takes their mutants.`

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
A run that keeps nothing there, such as a refused `--resume` or a `--since` run with no Swift file
changed, leaves no folder of its own in `<project>_muter_logs`. A resumed session's folder holds no
results file, but `resumed session.txt`, a note naming the file it adds to.

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

- **What it takes.** The results file, or a log folder of any of the run's sessions. `-f` and `-o`
  work as in `run`. Without `-o` the report goes to standard output alone, so
  `-f json > report.json` gives valid JSON.
- **A finished run** gets its own report back, in any format. Only what depends on when and where a
  report is made can differ, such as the time in the HTML report's footer. A run by an older
  SwiftMutator, which tested a file's mutants by operator and put line 10 before line 9, gets them
  in line order.
- **A run that was stopped, crashed or is still going** gets a report of the mutants it has tested.
- **On standard error** it says how many of the run's mutants the report covers, how the run ended,
  and where it saved the report. A run that stopped on its fifth build error in a row, for example,
  gives `Report of 1103 of 2497 mutants, from …: the run stopped on an error (tooManyBuildErrors).`
  For a resumed or reused run, the next line says which sessions tested its results and how many
  were kept by `--reuse`: `Of these, 1394 were tested in the last session, session 2, and 1103 in
  session 1.`
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

Some tests print text shaped like a failed test, such as a test of a test reporter. When the
passing baseline prints such a line, no line counts as a failed test for stopping a run or for
counting a timed-out run killed. The tests those lines name are left out of every mutant's list,
and the results file's header names them in `failedTestLookalikes`. The other tests that fail are
still named.

**Suspect tests.** Some tests fail whatever the mutant, because they are timing-sensitive or flaky
under the load of several workers. Such a test makes a mutant count as killed when no test checks
it, which raises the score. SwiftMutator calls a test *suspect* when it failed for mutants in at
least 15% of the files that have a killed mutant naming a test, and in at least 10 of those files.
A test of the mutated code rarely does that. With fewer than 10 such files the report gives no
verdict, and says so. `suspectTestFilePercent` and `suspectTestMinimumFiles` change the 15% and
the 10. They change only what the reports say, so a resume lets them change. The results file
records them, and `swift-mutator report` uses those of the run's last session.

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
  - The default thresholds come from one project's runs. In SwiftProjectLint's, no test of the
    mutated code reached more than 8.8% of the files, in whole runs or in 1,634 smaller ones. The
    tests that failed under load reached 23–97%. A project whose good tests reach further, such as
    one with broad end-to-end tests, may need a higher `suspectTestFilePercent`.
  - The rule misses a test that fails in fewer than about 3% of runs, or about 5% when runs stop
    at their first failed test. Such a test is worth about 1 point of score at most: on
    SwiftProjectLint, 0.16. A control run catches one only if it fails there: 25 control runs
    give a test that fails in 3% of runs about an even chance.

#### Control runs

Every so often, among the mutants, SwiftMutator runs the tests with no mutant on: a *control run*.
It runs on whichever worker is free, under the mutants' time limit and the same load as theirs, and
never stops at its first failed test. A passing baseline shows the tests pass alone. A control run
shows whether they still pass beside the other workers' runs. A test that fails in one is *flaky*:
it is suspect however few files it failed for mutants in, and a kill only suspect tests were
recorded failing for counts as one without them, as above.

- **How many.** One for each 100 mutants a session tests, by default, so none below 100. Control
  run k starts halfway through its stretch of 100, so none runs as the workers start or drain.
  `controlRunEvery: 50` runs one for each 50, and `controlRunEvery: 0` none. `--mutant` runs none.
- **The cost.** A control run takes as long as a survivor's run. On SwiftProjectLint on 31
  October, a survivor took 6.9 s and a mutant 2.4 s on average, so one for each 100 mutants adds
  about 3%.
- **What it says.** A control run that doesn't pass is said as it ends, with its first failed test:

  ```
  ⚠️ Control run 2 of 24, with no mutant on, failed: testAnalyzeProjectPerformance() at ProjectLinterTests.swift:98:9. A test that fails with no mutant on is flaky, and the reports count a kill only such tests failed for as suspect. Its log is control run 2.log.
  ```

  The Killing Tests section says how many control runs didn't pass and names the flaky tests, and
  the Suspect column says `flaky` for one. The warning names them apart from the tests the 15% rule
  found: `1 test may fail whatever the mutant: it failed in a control run, with no mutant on
  (testAnalyzeProjectPerformance() in 3 of 24).`
- **The record.** Each control run is a `control` line in the results file, with the tests it
  failed (see [the results file](Docs/results-file.md#control)), and its log is kept as
  `control run <k>.log`. A resumed run's report counts every session's, and a merge of shards'
  every shard's. A run that `--reuse` starts doesn't count the reused run's.
- **Lookalike lines.** The tests the passing baseline's lines showed failing aren't flaky, as they
  aren't a mutant's killing tests.

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
   in full. A run of a test plan's command is `run-without-mutating` again, with the plan and
   `--resume`.
5. Removes its worker clones, `<project>_mutated_worker<n>`, the active-mutant files beside the
   mutated project and the clones, and an xcodebuild run's derived data,
   `<project>_mutated.DerivedData` and `<project>_mutated_worker<n>.DerivedData`, with its workers'
   `muter-worker<n>.xctestrun` files. The mutated project, `<project>_mutated`, is kept, as after a
   finished run. Last, it deletes the simulators an xcodebuild run made for its workers, named
   `swiftmutator-<project hash>-<pid>-<start>-w<n>`, which takes a few seconds when they are
   booted. A finished run deletes them the same way.
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
  already written it, and worker clones, their active-mutant files, derived data and worker
  simulators can be left behind. A SIGHUP after a first SIGHUP is ignored, because zsh sends two
  when its terminal closes: closing a terminal stops a run the same way as one Ctrl-C.
- **Suspending.** Ctrl-Z suspends SwiftMutator with every process it started, which the terminal's
  Ctrl-Z doesn't reach: each leads a process group of its own. `fg` or `bg` continues them all. No
  time limit counts the time suspended, and no test run's duration includes it, though a test that
  measures time itself can still see it pass. Under xcodebuild, a simulator runs the tests in a
  process of its own, which SwiftMutator didn't start, and doesn't suspend. A run that is
  stopping isn't suspended: it is about to end.
- **Leftovers.** The next `run` removes `<project>_mutated` and any worker clones, active-mutant
  files and `.DerivedData` folders an earlier run left behind, such as one stopped at once, killed
  with SIGKILL, or crashed. The next xcodebuild run, before its baseline, deletes the worker
  simulators an earlier run of the project left, and those of any run, of any project, whose
  process has ended; a run of another project that is still under way keeps its own. Until then, a
  booted one holds memory. No other simulator is touched: only SwiftMutator's own are named
  `swiftmutator-<project hash>-…`.
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

`--resume` takes the results file, or a log folder of any of the run's sessions. SwiftMutator
copies, discovers and builds the project as any run does, then says which results it keeps:

```
♻️ Resuming the run in /…/results.jsonl: 1098 results still hold, so 1399 mutants are left to test (1394 never tested, 5 build errors).
```

It runs the baseline again and tests only the mutants left, which are what the progress bar, or the
line per mutant, counts. Their results go into the same file, as a new session, so the file stays in
the first session's log folder. The new session's own log folder holds its logs and a note,
`resumed session.txt`, whose first line is the file's path, so `report`, `--resume` and `--reuse`
take that folder too. The report at the end covers every mutant, kept or tested, and so does
`swift-mutator report` of the file.

- **What it saves.** The copy, the build, the baseline and the worker clones are made again. On
  SwiftProjectLint's 2,497 mutants on 6 October, on an 8-core Mac, they took 5–9% of a run, so
  resuming a run stopped halfway should have saved about 33–46 minutes, roughly 46% of a new run.
  On 31 October, on an 18-core Mac, a whole 4-worker run took 27 minutes with 2 of setup, so it
  would save about 12. On a small project they are most of the run:
  for lab runs of 43 and 151 mutants, the estimate is 12–18%.
- **What it keeps.** A result is kept when discovery finds its mutant again in the same file, at the
  same place, with the same operator and the same change (`snapshot`), and the file's SHA-256 hasn't
  changed. Killed mutants, survivors and timeouts are kept: the score counts a timeout as a survivor,
  so a kept one can't raise it. A timeout of a session on several workers is kept only once it was
  [run again](#timeouts-are-run-again): one that a stop, or a SwiftMutator from before reruns, left
  unconfirmed is tested again, and retesting can only raise the score. These are tested again:
  - build errors, including test runs that couldn't start;
  - mutants in a file that changed, and mutations that changed;
  - mutants whose place and operator appear more than once in a file, as they share a switch ID;
  - timeouts of a session on several workers that weren't run again, which the summary counts as
    `2 timeouts not run again at lower load`;
  - under a longer `--timeout` than a session's limit, that session's timeouts, which the summary
    counts as `4 timeouts under a shorter limit`;
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
  tested, the timeouts of a run on several workers by a SwiftMutator from before reruns, and, under
  a longer `--timeout`, the timeouts under a shorter limit, so this is how to test build errors
  again, or timeouts with more time. With nothing left to test, it says `nothing is
  left to test`, builds nothing, runs no baseline and prints the report.
- **A run of a test plan** is resumed by `run-without-mutating` with the same plan and `--resume`,
  which the command its summary ends with gives. It compares the plan and the plan's copy, not your
  project: see [The test plan](Docs/test-plan.md#resuming-a-run-of-the-plan).

### When a resume is refused

A result is reused only if this run would give the same one, so SwiftMutator compares this run with
the file's last session. It checks before it removes or copies anything, and names every reason in
one message:

```
SwiftMutator won't resume the run in '/…/results.jsonl', so that no result is reused that this run might not reproduce:
  - mutationTestTimeout was 120 and is 60 now. A time limit shorter than a session's, or none, needs a new run: one at least as long as every session's only tests timeouts again.
  - The toolchain (toolchain.testCommandVersion) was "Apple Swift version 6.3.3 …" and is "Apple Swift version 6.4 …" now. --force-resume reuses the results anyway.
  - 2 project files changed since the run stopped: README.md (changed), notes.txt (added).
    If they can't change any test's result: --resume-ignoring 'README.md' --resume-ignoring 'notes.txt'
    Mutants in a changed source file are tested again either way.
Nothing was copied or removed.
```

It then exits with status 5, without asking for a bug report, so a script can tell a refusal from
an error: nothing was tested ([Exit status](#exit-status)). A project file that changes while
SwiftMutator copies the project is refused after the copy, so that message doesn't end with
`Nothing was copied or removed.`

| Since the last session | Resuming |
|---|---|
| A configuration key changed, other than `mutationTestWorkers`, `stopAtFirstFailure`, `buildTimeout`, `oneWorkerSimulator`, `suspectTestFilePercent`, `suspectTestMinimumFiles` and `controlRunEvery` | Refused: start a new run |
| `mutationTestTimeout` (or `--timeout`) is at least as long as every session's `timeoutSeconds` | Goes ahead, says so, and tests the timeouts under a shorter limit again |
| `--operators`, `--files-to-mutate` or `--skip-coverage` changed | Refused: start a new run |
| `--since`'s merge base or `--changed-lines` changed, or `--since` given in one session only | Refused: start a new run. `--reuse` doesn't compare them |
| `--shard` changed, or given in one session only | Refused: start a new run. `--reuse` doesn't compare it |
| `mutationTestWorkers`, `stopAtFirstFailure`, `buildTimeout`, `oneWorkerSimulator`, `suspectTestFilePercent`, `suspectTestMinimumFiles` or `controlRunEvery` changed | Goes ahead, and says so: `ℹ️ mutationTestWorkers was 4 and is 2 now, which no result depends on.` |
| SwiftMutator, the toolchain or the SDK changed | Refused, unless `--force-resume` is given |
| Project files changed, were added or were removed | Refused, unless a `--resume-ignoring` glob matches each one |
| Another SwiftMutator holds the file, because its run is still going | Refused with status 6, naming the process that holds it, and its host: wait for that run to end. If an older SwiftMutator holds it, which doesn't say, it names the process and host that wrote the file's last session, which may not be the one |
| Coverage was gathered in one session only, or this session discovers other mutants | Goes ahead, and warns: `⚠️ 412 earlier results no longer count, as this session doesn't discover their mutants: coverage couldn't be gathered then, and is now.` |

A results file written before `--resume` existed can't be resumed, as it records no project files.
Nor can a run of a test plan by `run`, or a run without one by `run-without-mutating` (see
[Resuming a run of a test plan](Docs/test-plan.md#resuming-a-run-of-the-plan)). `-o` can't name the
results file itself. `--force-resume` and `--resume-ignoring` work only with `--resume`; without it
they are a usage error, with status 64.

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
  files may well change again. A run of a test plan compares the plan's copy, not the project, so
  there the glob matches the copy's files (see
  [Resuming a run of the plan](Docs/test-plan.md#resuming-a-run-of-the-plan)).
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
It takes the earlier run's results file, or a log folder of any of its sessions, finished or not,
and writes a results file of its own in its own log folder: the earlier file is only read.

```
swift-mutator run --skip-coverage -o report.txt --reuse '/…/Oct 31, 2026 at 7:08 PM/results.jsonl'
♻️ Reusing the results in /…/results.jsonl: 1816 results still hold, so 647 mutants are left to test (9 timeouts, 638 as test files changed).
ℹ️ 1 test file changed, so every survivor is tested again, and every kill that no unchanged test still holds.
```

It checks the earlier run as a resume does (see [When a resume is refused](#when-a-resume-is-refused)),
with `--force-reuse` for `--force-resume`, and a refused `--reuse` exits with status 5 as a refused
resume does. Changed project files never refuse it. Instead they decide which results it keeps, for
each result by what changed since the session that tested it:

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
  So the new file stands alone: `swift-mutator report` of it gives the run's own report, and says
  on standard error how many results were kept, and the file each was first tested in. A later
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
