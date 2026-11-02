# The slow acceptance tier

Whole SwiftMutator runs on a pinned SwiftProjectLint, each checked mutant by mutant against reference verdicts ([#174](https://github.com/Joseph-Cursio/SwiftMutator/issues/174)). The unit, acceptance and regression tests run small sample projects. Several bugs only ever showed in whole runs of a real project: workers sharing `UserDefaults` (#92), test-bundle order (#64), crash handling, and whether `--reuse` (#71) keeps only results a fresh run would give. A suite takes about 6½ hours on an 18-core M5 Pro, so it isn't run on every PR. Run it before a release, or when a change touches how mutants are discovered, tested or recorded.

```bash
make slow-acceptance-test
```

## What it checks

Each scenario is a whole run, with 4 workers and `--skip-coverage`. A check passes only when every mutant's verdict is the reference's, and its mutation too (`before` and `after`):

- **A different mutation** always fails.
- **A verdict that differs only by a timeout**, a kill or a survivor that timed out or the other way round, is reported. A check fails only on more than 3 in a run (`MAX_TIMEOUT_FLIPS`). SwiftProjectLint's tests now and then hang, or slow down past the time limit, under a random mutant, about one a run.
- **Any other different verdict** fails, unless `allowlist.json` names the mutant with a reason.

Times are recorded, and never fail a check.

| Scenario | The run | It checks | Time |
|---|---|---|---|
| `full` | A plain run | The same mutants as the reference, each with its mutation and verdict | 46 min |
| `release` | Tests built with `-c release -Xswiftc -enable-testing` | As `full` | 22 min |
| `no-stop` | `stopAtFirstFailure: false` | As `full` | 1 h 53 min |
| `reuse-nochange` | `--reuse` of `full`'s results, nothing changed | As `full`; and it kept exactly what `ResumePlan` keeps: every result but timeouts, build errors and repeated places | 12 min |
| `reuse-testchange` | A test file's suites disabled, then `--reuse` of `full` | No kill only that file's tests made is kept, some other kill is, no survivor is; its verdicts are those of a full run of the same edited tree (`full-testchange`), and the edit moved some | 37 min, and 50 for `full-testchange` |
| `reuse-sourcechange` | A comment added to a source file with no mutants: `--reuse`, stopped once its header is written; then `--reuse --reuse-ignoring` that file | The first plans to test everything again; the second keeps what `reuse-nochange` keeps, and records the waiver | 1 min, then 12 |
| `stop-resume` | A run stopped by SIGINT, to its process group as Ctrl-C does, a third of the way through; then the `▶️ Continue:` command it printed | The stop ended session 1, which recorded no run the stop cancelled; session 2 tested whatever session 1 left, and every key it retired; the results then match the reference | 20 min, then 29 |
| `since` | `--since SINCE_BASE --changed-lines`; then `--since HEAD` | Every mutant on a line `git diff -U0` adds or changes is tested, and none outside the changed files; with nothing changed, nothing is mutated, and the run exits 0 without a results file | 4 min |

`verdicts.py` reads a results file as SwiftMutator does: in order, a `mutant` line setting its key's result, and a `retired` line dropping the keys it lists. `make slow-acceptance-selftest` runs its own tests, in seconds, on results files it writes.

## The target

`target.env` names the target and its pin: SwiftProjectLint's `main` once its tests stopped giving different verdicts from run to run (SwiftProjectLint#324). Its causes, which that PR fixed:
- tests that walked their files in hash-seed order;
- tests that shared `UserDefaults.standard` across test processes.

Its `Package.resolved` isn't in git, and several of its dependencies take `from:` versions. So the pin's resolved versions are kept here, in `reference/<pin>.Package.resolved`, and every run resolves from that file alone.

- **Excludes and skipped tests.** `target.env` lists them, each with its reason.
  - The rules package is left out. It holds 2,952 of the pin's 3,823 mutants, and a run of them all takes about 6 h. The other 871 still take every scenario through the behaviour it checks.
  - Some tests fail in the mutated copy whatever the mutant, and are skipped:
    - tests that parse the project's own sources from disk, once those sources hold mutant switches;
    - a deeply recursive test, which overflows a test thread's stack once the switches enlarge each frame.
  - Tests that gave a mutant another verdict than the reference's, whatever the mutant, are skipped too: a speed ratio timed under the workers' load, and a kill no reference run made.
  - `--preflight` runs once, stopping when the baseline passes, to show that the list is enough.
- **Scenario choices.** `TEST_CHANGE_FILE`, `SOURCE_CHANGE_FILE` and `SINCE_BASE` are chosen when the reference is made.

## Running it

- **Where.** Everything happens in a work folder, by default `~/Library/Caches/SwiftMutatorSlowTier/<time>`. It holds a fresh clone of the target, each run's configuration (outside the clone, so the reuse checks never see it), and each run's console, report and load samples. `summary.md` there gives each check and each run's time.
- **Choosing.** `--scenarios full,since` runs some of the scenarios, and `--work DIR` reuses a work folder. A reuse scenario makes `full` first if this suite hasn't.
- **Idle and awake.** Each run starts only once the 1-minute load average is under 4 (`MAX_LOAD`). The driver keeps the Mac awake from start to end, the waits included: a Mac that sleeps goes on only in short dark wakes, and the tests it runs then time out. Builds or other measurements meanwhile make runs slower, and can turn a slow kill into a timeout.
- **Exit status.** The driver exits 1 when a check fails, and 2 when the setup does.

## Making the reference

A new pin, or a SwiftMutator change that rightly changes verdicts, needs a new reference:

1. **Pin.** Set `PIN` in `target.env` to a commit on the target's `main`.
2. **Preflight.** Run `./AcceptanceTests/slow/slow-acceptance.sh --preflight`. If the baseline fails, add the failing test to `SKIP_TESTS`, or its file to `EXCLUDES`, with a reason.
3. **Reference.** Run `make slow-acceptance-reference RUNS=5`: five full runs, about 4 hours. It writes:
   - `reference/<pin>.json`: each mutant's majority verdict and its mutation;
   - `reference/<pin>.Package.resolved`;
   - the full runs' median time, in `reference/<pin>-times.json`.

   It refuses runs that discover different mutants or mutations. It also refuses a mutant the runs disagree on, unless `allowlist.json` names it with a reason, or the runs differ only by a minority of timeouts.
4. **Scenario choices.** Choose `TEST_CHANGE_FILE` (the reference run prints a candidate), `SOURCE_CHANGE_FILE` and `SINCE_BASE`, as `target.env` describes.
5. **Times.** The first idle suite records each other scenario's time: `verdicts.py times <work>/runs.tsv --baseline reference/<pin>-times.json --update`.

## Not covered

- **An XCTest or Xcode target.** SwiftProjectLint exercises only SwiftPM and Swift Testing.
- **Linux.**
- **A schedule.** It runs on demand, on a local Mac: hosted macOS runners are several times slower, and too noisy for the times.
