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
- **A default timeout:** without `mutationTestTimeout`, a mutant's test run stops after 3× the
  baseline (at least 10 s), so a mutant that loops forever can't hang the run.
- **Logging through the injected printer**, so log output can be captured and tested.

Fixes that apply to Muter are offered upstream too.

## Build and run

```bash
swift build -c release --product swift-mutator
.build/release/swift-mutator init      # writes muter.conf.yml in the current project
.build/release/swift-mutator run       # runs mutation testing
```

`make install` installs `swift-mutator` into `/usr/local/bin`.

## Configuration

SwiftMutator reads Muter's `muter.conf.yml`, so existing Muter configurations work unchanged.
The options are documented in [Muter's README](Docs/Muter-README.md#configuration-options);
SwiftMutator adds:

| Key | Meaning |
|---|---|
| `mutationTestWorkers` | How many mutants to test at once (SwiftPM projects only; default 1) |
| `mutationTestTimeout` | Seconds before a mutant's test run is stopped (default: 3× the baseline, at least 10) |
| `stopAtFirstFailure` | Stop a mutant's test run at its first failed test, which already decides that it is killed (SwiftPM projects only; never the baseline; default true) |

## Results file

SwiftMutator saves each mutant's result as soon as it is tested, as one line of JSON in
`results.jsonl` in the run's log folder, `<project>_muter_logs/<run>/`. A run that is stopped or
crashes keeps every result it finished. The file's first line records the SwiftMutator build, the
toolchain and the settings the run used, and each killed mutant's line names the tests that failed.
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
   file is, and the `swift-mutator report` command that makes a report of them all from it, in any
   format. The command is left out when no mutant was tested, or when the results file couldn't be
   written in full.
5. Removes its worker clones, `<project>_mutated_worker<n>`. The mutated project,
   `<project>_mutated`, is kept, as after a finished run.
6. Exits by the same signal, so the shell sees status 130 for SIGINT, 143 for SIGTERM or 129 for
   SIGHUP, and a script or loop that runs SwiftMutator stops too.

A stop before the baseline has passed has nothing to keep: the results file starts only after it.

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

## Development

`make test` runs the unit tests (the `muterTests` target). CI runs them on every pull request
and every push to `main`, on two Xcode versions (see [ci.yml](.github/workflows/ci.yml)).
[CONTRIBUTING.md](CONTRIBUTING.md) covers the acceptance and regression tests, which CI doesn't
run.

## License

MIT, as Muter is. See [LICENSE](LICENSE).
