# The slow acceptance tier

Whole SwiftMutator runs on pinned real projects, each checked mutant by mutant against reference verdicts ([#174](https://github.com/Joseph-Cursio/SwiftMutator/issues/174)). There are three targets, the files in `targets/`:
- **`swiftprojectlint`**, the default: SwiftPM and Swift Testing.
- **`yams-swiftpm`**: XCTest, through `swift test`.
- **`yams-xcodebuild`**: an Xcode project, through `xcodebuild`.

The unit, acceptance and regression tests run small sample projects. Several bugs only ever showed in whole runs of a real project: workers sharing `UserDefaults` (#92), test-bundle order (#64), crash handling, and whether `--reuse` (#71) keeps only results a fresh run would give. SwiftProjectLint's suite takes about 12 hours on an 18-core M5 Pro, so it isn't run on every PR. Run it before a release, or when a change touches how mutants are discovered, tested or recorded. Run the Yams targets too when a change touches XCTest's results or `xcodebuild`.

```bash
make slow-acceptance-test
```

```bash
make slow-acceptance-test SLOW_TARGET=yams-xcodebuild
```

```bash
make slow-acceptance-test-all
```

## What it checks

Each scenario is a whole run, with `--skip-coverage`, and the operators and workers the target's file pins. A check passes only when every mutant's verdict is the reference's, and its mutation too (`before` and `after`). A verdict is SwiftMutator's own: killed, survived, timed out, or not covered, a survivor whose code it saw didn't run (`activated: false`), which its reports count apart:

- **A different mutation** always fails.
- **A verdict that differs only by a timeout**, a kill or a survivor that timed out or the other way round, is reported. A check fails only on more than 3 in a run (`MAX_TIMEOUT_FLIPS`). SwiftProjectLint's tests now and then hang, or slow down past the time limit, under a random mutant, about one a run.
- **Any other different verdict** fails, unless the target's allowlist, `targets/<target>.allowlist.json`, names the mutant with a reason.

Times are recorded, and never fail a check. `--list` shows a target's scenarios, and the summary marks each scenario a target can't take, with its reason.

| Scenario | The run | It checks | swiftprojectlint | yams-swiftpm | yams-xcodebuild |
|---|---|---|---|---|---|
| `full` | A plain run | The same mutants as the reference, each with its mutation and verdict | 1 h 40 min | 4.5 min | … |
| `release` | Tests built for release: `-c release -Xswiftc -enable-testing`, or the target's `XCODEBUILD_RELEASE_ARGUMENTS` | As `full` | 32 min | … | … |
| `no-stop` | `stopAtFirstFailure: false` | As `full` | 2 h 35 min | … | not applicable: `swift test` only |
| `reuse-nochange` | `--reuse` of `full`'s results, nothing changed | As `full`; and it kept exactly what `ResumePlan` keeps: every result but timeouts, build errors and repeated places | 50 min | … | … |
| `reuse-testchange` | A test file's tests disabled, then `--reuse` of `full` | No kill only that file's tests made is kept, some other kill is, no survivor is (for XCTest, no kill is kept at all), and the console says why: as test files changed; its verdicts are those of a full run of the same edited tree (`full-testchange`), and the edit moved some | 1 h 33 min, and 1 h 41 min for `full-testchange` | … | not applicable: `yams-swiftpm` checks it |
| `reuse-sourcechange` | A comment added to a source file with no mutants: `--reuse`, stopped once its header is written; then `--reuse --reuse-ignoring` that file | The first plans to test everything again; the second keeps what `reuse-nochange` keeps, and records the waiver | 1 min, then 49 | … | … |
| `stop-resume` | A run stopped by SIGINT, to its process group as Ctrl-C does, a third of the way through; then the `▶️ Continue:` command it printed | The stop ended session 1, which recorded no run the stop cancelled; session 2 tested whatever session 1 left, and every key it retired; the results then match the reference | 27 min, then 1 h 23 min | … | … |
| `since` | `--since SINCE_BASE --changed-lines`; then `--since HEAD` | Every mutant on a line `git diff -U0` adds or changes is tested, and none outside the changed files; with nothing changed, nothing is mutated, and the run exits 0 without a results file | 21 min | … | … |

`verdicts.py` reads a results file as SwiftMutator does: in order, a `mutant` line setting its key's result, and a `retired` line dropping the keys it lists. `make slow-acceptance-selftest` runs its own tests, in seconds, on results files it writes. They include each of SwiftProjectLint's configurations, which must stay byte for byte those in `selftest/`.

## The targets

A target's file, `targets/<target>.env`, names the project and its pin, and sets what the driver lets it set: the build system, its arguments, operators, workers, excludes, skipped tests, and the scenario choices. The driver's own defaults, at the top of `slow-acceptance.sh`, are a SwiftPM target on `main`. Each target keeps its own reference, `reference/<stem>.json`, and its own allowlist.

All three share these rules:
- **Operators.** The target's file pins the operators every run mutates with, so a new operator doesn't change the tier's mutants: it joins a target only when it's added to its `OPERATORS` and the reference is made again. The reference records its operators, and the driver refuses to start a suite against one made with others ([#280](https://github.com/Joseph-Cursio/SwiftMutator/issues/280)). A change to what a pinned operator mutates still fails every check it touches, as a different mutation should.
- **Excludes and skipped tests.** The target's file lists them, each with its reason. `--preflight` runs once, stopping when the baseline passes, to show that the list is enough.
- **Scenario choices.** `TEST_CHANGE_FILE`, `SOURCE_CHANGE_FILE` and `SINCE_BASE` are chosen when the reference is made.

### swiftprojectlint

SwiftProjectLint's `main` once its tests stopped giving different verdicts from run to run (SwiftProjectLint#324). Its causes, which that PR fixed:
- tests that walked their files in hash-seed order;
- tests that shared `UserDefaults.standard` across test processes.

Its `Package.resolved` isn't in git, and several of its dependencies take `from:` versions. So the pin's resolved versions are kept here, in `reference/<pin>.Package.resolved`, and every run resolves from that file alone.

- **Excludes.** Three packages are left out: rules, visitors and config. Under the ten operators, visitors and config alone hold 1,936 of the 3,064 mutants outside the rules package. The other 1,128 still take every scenario through the behaviour it checks.
- **Skipped tests.** Some tests fail in the mutated copy whatever the mutant:
  - tests that parse the project's own sources from disk, once those sources hold mutant switches;
  - a deeply recursive test, which overflows a test thread's stack once the switches enlarge each frame.

  Tests that gave a mutant another verdict than the reference's, whatever the mutant, are skipped too: a speed ratio timed under the workers' load, and a lint's 30-second ceiling, which a loaded machine trips. One more is skipped for a kill that depends on test order, which `targets/swiftprojectlint.allowlist.json` now covers.

### yams-swiftpm and yams-xcodebuild

[Yams](https://github.com/jpsim/Yams), a YAML library, at one pin on its `main`, run two ways. It is small, has no dependencies, and its tests are XCTest. It ships an Xcode project whose scheme tests it on macOS. Each way has 594 mutants under the ten operators, with nothing excluded.

- **`yams-swiftpm`** runs `swift test` with 4 workers. XCTest names a test `-[Module.Class testA]`, with no file, so after a test file changes SwiftMutator keeps no kill (`ReuseChanges.killHolds`). `reuse-testchange` checks that rule here: it renames each `func test…` in `TEST_CHANGE_FILE`, and each reference to it, as in an `allTests` list, so XCTest no longer runs them.
- **`yams-xcodebuild`** runs `xcodebuild test` on the project's scheme, on this Mac. SwiftMutator tests one mutant at a time on a Mac destination, so a run takes much longer. Its arguments, in its file, each with a reason:
  - only one of the test plan's two configurations;
  - parallel testing off;
  - Debug, as `swift test` builds;
  - `CI=true`, which skips the project's SwiftLint build phase;
  - macOS 12 at the least, which Xcode 27 requires.

  Two scenarios don't apply. `no-stop` can't, as `stopAtFirstFailure` works only with `swift test`. `reuse-testchange` would check the rule `yams-swiftpm` checks, at the cost of two full runs.
- **Skipped tests.** One, in both: a date test round-trips the current time, so whether it kills a mutant depends on the clock.
- **No resolved packages.** Yams has no dependencies, so `PINS_PACKAGES=no` and no `Package.resolved` is kept.

## Running it

- **Where.** Everything happens in a work folder, by default `~/Library/Caches/SwiftMutatorSlowTier/<time>-<target>`. It holds a fresh clone of the target, each run's configuration (outside the clone, so the reuse checks never see it), and each run's console, report and load samples. `summary.md` there gives each check and each run's time, and `runs.tsv` each run's load and how its workers tested: from one build (`shared`), each from a clone (`clones`), or one mutant at a time (`one`). SwiftMutator chooses between the first two from the run with no mutant on.
- **Choosing.** `--target T` picks a target, `--scenarios full,since` runs some of its scenarios, and `--work DIR` reuses a work folder. The folder remembers its target, and the driver refuses another. A reuse scenario makes `full` first if this suite hasn't.
- **Idle and awake.** Each run starts only once the 1-minute load average is under 4 (`MAX_LOAD`). The driver keeps the Mac awake from start to end, the waits included: a Mac that sleeps goes on only in short dark wakes, and the tests it runs then time out. Builds or other measurements meanwhile make runs slower, and can turn a slow kill into a timeout.
- **Exit status.** The driver exits 1 when a check fails, and 2 when the setup does. `make slow-acceptance-test-all` runs each target in turn, and fails if any does.

## Making the reference

A new pin, a change to `OPERATORS`, or a SwiftMutator change that rightly changes verdicts or mutations needs a new reference, made for each target it touches:

1. **Pin.** Set `PIN` in the target's file to a commit on the target's `main`.
2. **Preflight.** Run `./AcceptanceTests/slow/slow-acceptance.sh --target T --preflight`. If the baseline fails, add the failing test to `SKIP_TESTS`, or its file to `EXCLUDES`, with a reason.
3. **Reference.** Run `make slow-acceptance-reference SLOW_TARGET=T RUNS=5`: five full runs, about 9 hours for SwiftProjectLint. It writes:
   - `reference/<stem>.json`: each mutant's majority verdict and its mutation;
   - `reference/<stem>.Package.resolved`, for a target whose packages are pinned;
   - the full runs' median time, in `reference/<stem>-times.json`.

   The stem is the pin, or the target's `REFERENCE_STEM`. It refuses runs that discover different mutants or mutations, that mutated with operators other than `OPERATORS`, that ran with another configuration than the first (skipped tests, workers), or that a check would refuse: a session that didn't finish, or timeouts it never ran again. It also refuses a mutant the runs disagree on, unless the target's allowlist names it with a reason, or the runs differ only by timeouts and one verdict has more than half the runs. That verdict is kept, even when it is a timeout. It prints each run's timeout flips against the majority, the count a check holds to `MAX_TIMEOUT_FLIPS`.

   After a refusal that the allowlist should explain, add the mutant there and run the same command with the same `--work`: it keeps each run that finished with the same binary and configuration, and only makes the reference again.
4. **Scenario choices.** Choose `TEST_CHANGE_FILE` (the reference run prints a candidate), `SOURCE_CHANGE_FILE` and `SINCE_BASE`, as the target's file describes.
5. **Times.** The first idle suite records each other scenario's time: `verdicts.py times <work>/runs.tsv --baseline reference/<stem>-times.json --update`.

## Not covered

- **A simulator destination**, where SwiftMutator gives each `xcodebuild` worker a simulator of its own (`SimulatorWorkerSetup`): `yams-xcodebuild` tests on this Mac, one mutant at a time.
- **Linux.**
- **A schedule.** It runs on demand, on a local Mac: hosted macOS runners are several times slower, and too noisy for the times.
