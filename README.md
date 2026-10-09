# SwiftMutator

[![CI](https://github.com/Joseph-Cursio/SwiftMutator/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Joseph-Cursio/SwiftMutator/actions/workflows/ci.yml)

Automated [mutation testing](https://en.wikipedia.org/wiki/Mutation_testing) for Swift.

SwiftMutator is based on [Muter](https://github.com/muter-mutation-testing/muter) by the Muter
contributors, and keeps its history. Muter introduces small changes (*mutants*) into your
code, such as `==` becoming `!=` or a call being removed, and runs your tests against each one.
A mutant your tests don't catch shows a behavior your tests don't check. The mutation score is
the share of mutants caught.

## Why a separate project

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
- **One environment for every `swift test` run:** a mutant is switched on by its ID in a hidden
  `.swiftmutator-active-mutant` file in the worker's folder, not by a variable of its own. SwiftPM
  keys its cache of compiled package manifests on the whole environment, so runs no longer
  recompile every `Package.swift`, which saves about 6 s per mutant with 4 workers. A wrapper
  script around `swift test` gets this only with `buildSystem: swift`; other wrappers and
  `xcodebuild` keep a variable per mutant. A SwiftPM test plan made by an older SwiftMutator is
  refused: make it again with `swift-mutator mutate-without-running`.
- **A default timeout:** without `mutationTestTimeout`, a mutant's test run stops after a limit
  based on how long your tests take, so a mutant that loops forever can't hang the run. For a
  SwiftPM project, SwiftMutator times one run of `swift test … --skip-build` with no mutant on,
  just after the baseline, and allows 5× that, once more for each worker beyond the first, and at
  least 20 s. For another build system, or when that run fails, it allows 3× the baseline, build
  included, and at least 10 s. A timeout counts as a survivor, so if your tests set limits of their
  own, such as Swift Testing's `.timeLimit`, which is at least a minute, set `mutationTestTimeout`
  above them: otherwise a mutant that only your tests' limit would catch ends as a timeout.
- **Coverage with several test bundles:** Swift 6.4's build system makes a test bundle for each
  test target, which Muter's coverage step can't read, so it tested every mutant, even in code no
  test runs. SwiftMutator exports the coverage of every bundle at once, leaves out the files no
  test runs and skips the mutants in code no test runs. If coverage can't be gathered, it says
  why, and tests every mutant as before. `--skip-coverage` turns the step off.
- **Logging through the injected printer**, so log output can be captured and tested.

Fixes that apply to Muter are offered upstream too.

## Build and run

```bash
swift build -c release --product swift-mutator
.build/release/swift-mutator init      # writes muter.conf.yml in the current project
.build/release/swift-mutator run       # runs mutation testing
```

`make install` installs `swift-mutator` into `/usr/local/bin`.

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

SwiftMutator reads Muter's `muter.conf.yml`, so existing Muter configurations work unchanged.
The options are documented in [Muter's README](Docs/Muter-README.md#configuration-options);
SwiftMutator adds:

| Key | Meaning |
|---|---|
| `mutationTestWorkers` | How many mutants to test at once (SwiftPM projects only; default 1) |
| `mutationTestTimeout` | Seconds before a mutant's test run is stopped (default: based on a timed test run; see above) |
| `stopAtFirstFailure` | Stop a mutant's test run at its first failed test, which already decides that it is killed (SwiftPM projects only; never the baseline; default true) |

## Results file

SwiftMutator saves each mutant's result as soon as it is tested, as one line of JSON in
`results.jsonl` in the run's log folder, `<project>_muter_logs/<run>/`. A run that is stopped or
crashes keeps every result it finished. The file's first line records the SwiftMutator build, the
toolchain and the settings the run used, and each killed mutant's line names the tests that failed.
`run --resume` continues a stopped run from it (see [Resuming a run](#resuming-a-run)).
[Docs/results-file.md](Docs/results-file.md) describes the format, with `jq` recipes such as the
tests that killed the most mutants.

`swift-mutator report` makes a run's report from its results file, in any format. The log folder
is beside the project, not in it, so from the project's folder, where `run` is run:

```bash
swift-mutator report "../SwiftProjectLint_muter_logs/Oct 4, 2026 at 1:16 PM" -f html -o report.html
```

- **What it takes.** The results file, or the run's log folder that holds it. `-f` and `-o` work as
  in `run`. Without `-o` the report goes to standard output alone, so `-f json > report.json` gives
  valid JSON.
- **A finished run** gets its own report back, in any format. Only what depends on when and where a
  report is made can differ, such as the time in the HTML report's footer.
- **A run that was stopped, crashed or is still going** gets a report of the mutants it has tested.
- **On standard error** it says how many of the run's mutants the report covers, how the run ended,
  and where it saved the report. A run that stopped on its fifth build error in a row, for example,
  gives `Report of 1103 of 2497 mutants, from …: the run stopped on an error (tooManyBuildErrors).`
- **It exits with status 1** when the file can't be read or isn't a results file.

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
5. Removes its worker clones, `<project>_mutated_worker<n>`. The mutated project,
   `<project>_mutated`, is kept, as after a finished run.
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
  once. SwiftMutator does the same by itself if stopping takes more than 30 seconds. It still kills
  every process it started and exits by the first signal, but the end line and the partial report
  are there only if it had already written them, and worker clones can be left behind. A SIGHUP
  after a first SIGHUP is ignored, because zsh sends two when its terminal closes: closing a
  terminal stops a run the same way as one Ctrl-C.
- **Leftovers.** The next `run` removes `<project>_mutated` and any worker clones an earlier run
  left behind, such as one stopped at once, killed with SIGKILL, or crashed. SIGKILL and crashes
  can't be handled, so the test processes of such a run go on until they end by themselves, with no
  time limit.
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
  SwiftProjectLint's 2,497 mutants they take 5–9% of a run, so resuming a run stopped halfway should
  save about 33–46 minutes, roughly 46% of a new run. On a small project they are most of the run:
  for lab runs of 43 and 151 mutants, the estimate is 12–18%.
- **What it keeps.** A result is kept when discovery finds its mutant again in the same file, at the
  same place, with the same operator and the same change (`snapshot`), and the file's SHA-256 hasn't
  changed. Killed mutants, survivors and timeouts are kept: the score counts a timeout as a survivor,
  so a kept one can't raise it. These are tested again:
  - build errors, including test runs that couldn't start;
  - mutants in a file that changed, and mutations that changed;
  - mutants whose place and operator appear more than once in a file, as they share a switch ID;
  - mutants never tested, including any that discovery finds for the first time.
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
| A configuration key changed, other than `mutationTestWorkers` and `stopAtFirstFailure` | Refused: start a new run |
| `--operators`, `--files-to-mutate` or `--skip-coverage` changed | Refused: start a new run |
| `mutationTestWorkers` or `stopAtFirstFailure` changed | Goes ahead, and says so: `ℹ️ mutationTestWorkers was 4 and is 2 now, which no result depends on.` |
| SwiftMutator, the toolchain or the SDK changed | Refused, unless `--force-resume` is given |
| Project files changed, were added or were removed | Refused, unless a `--resume-ignoring` glob matches each one |
| Another SwiftMutator holds the file, because its run is still going | Refused, naming the process and host that wrote the file's last session |

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

## Development

`make test` runs the unit tests (the `muterTests` target). CI runs them on every pull request
and every push to `main`, on two Xcode versions (see [ci.yml](.github/workflows/ci.yml)).
[CONTRIBUTING.md](CONTRIBUTING.md) covers the acceptance and regression tests, which CI doesn't
run.

## License

MIT, as Muter is. See [LICENSE](LICENSE).
