# SwiftMutator

[![CI](https://github.com/Joseph-Cursio/SwiftMutator/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Joseph-Cursio/SwiftMutator/actions/workflows/ci.yml)

Automated [mutation testing](https://en.wikipedia.org/wiki/Mutation_testing) for Swift.

SwiftMutator is based on [Muter](https://github.com/muter-mutation-testing/muter) by the Muter
contributors, and keeps its history. Muter introduces small changes (*mutants*) into your
code, such as `==` becoming `!=` or a call being removed, and runs your tests against each one.
A mutant your tests don't catch shows a behavior your tests don't check. The mutation score is
the share of mutants caught: those a failed test or a crash killed, as a percent of every mutant
that built, truncated to a whole percent, so 50 of 75 is 66%. A mutant that times out with no
failure or crash in its log isn't caught, as [timeouts](#timeouts-are-run-again) explains.

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

- on SwiftPM packages, recovery from mutants that don't compile, without giving up its shared
  build;
- a quality gate for CI: a minimum score, and no new survivors against a committed baseline;
- SARIF, SonarQube, Markdown and Stryker-compatible JSON reports.

Its default run uses three of its seven operators: logical operators, negated conditions and
swapped ternaries. So by default it doesn't replace relational operators, as in `==` becoming `!=`,
or remove calls, arithmetic or boolean literals. `--operator-tier experimental` runs all seven.
SwiftMutator runs its eight by default.

SwiftMutator differs in how it keeps tests apart. Each of its workers tests in its own full
copy of the project, `.git` included, unless a run of the tests with no mutant on writes nothing
in the copy, when they share one (see [Workers and release mode](#workers-and-release-mode)).
swift-mutation-testing tests in a sandbox whose unchanged
files are links to your project's files, so a test that rewrites one in place, such as a fixture,
changes your project, and a test that runs `git` can fail. On a package, its workers share that
sandbox, so tests that write files there at fixed paths can give false kills, and its workers share
the temporary directory, where each of SwiftMutator's has its own. On macOS, SwiftMutator gives each
worker's directly run tests their own `UserDefaults` (see Test bundles run directly);
swift-mutation-testing's workers share them ([#92](https://github.com/Joseph-Cursio/SwiftMutator/issues/92)).

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
  its mutants are left out, and [said to be](#mutants-outside-function-bodies).
- **Mutants outside function bodies:** a stored property's initial value, a global, a default argument
  and a `main.swift`'s statements are mutated too, each switched by itself
  (see [Mutants outside function bodies](#mutants-outside-function-bodies)).
- **Parallel workers:** a SwiftPM project tests several mutants at once by default, each in its own
  APFS clone of the mutated project (see [Workers and release mode](#workers-and-release-mode)).
  `mutationTestWorkers: N` or `--workers N` chooses how many. Each clone is built once before
  testing, which costs one extra build, and about one build folder of disk, per worker, but keeps
  tests that write files next to their sources from sharing them across workers. A run whose tests
  wrote nothing in the copy, with no mutant on, makes no clones, and its workers test from one build,
  on macOS when mutants' test bundles run directly. Each worker has its own temporary directory too.
  An xcodebuild project that tests on a simulator can have one simulator
  per worker instead, from one build, when `mutationTestWorkers` or `--workers` asks for them (see
  [xcodebuild workers](#xcodebuild-workers)). What tests share outside the copy can still give false
  kills (see [Tests that share state across workers](#tests-that-share-state-across-workers)).
- **One environment for every `swift test` run:** a mutant is switched on by its ID in a file
  beside the worker's folder, such as `MyPackage_mutated.active-mutant`, not by a variable of its
  own, so your tests don't find it among the package's files or in its `git status`. For a package
  inside a larger git repository, ignore `*_mutated*` there, which covers the copy, the worker
  clones, the derived data folders and the files beside them, under their `.noindex` names too. If
  you use `run --mutant`, ignore `*_mutant*` as well: its folders, such as its copy,
  `Foo_mutant.noindex`, don't match `*_mutated*`. A pattern that ends at `_mutated`, such as `*_mutated` or
  `Foo_mutated/`, no longer covers the copy, `Foo_mutated.noindex`: change it to `*_mutated*`.
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
    `UserDefaults(suiteName:)`, the keychain, fixed temporary paths and ports (see
    [Tests that share state across workers](#tests-that-share-state-across-workers)).
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
  run switched it on: [whether a mutant's code ran](#whether-a-mutants-code-ran) does that.
- **xcodebuild mutant runs leave no derived data behind:** each mutant's `xcodebuild
  test-without-building` keeps its derived data in `<project>_mutated.DerivedData.noindex`, beside
  the copy, emptied before each run and removed when the run ends, and each other worker's in
  `<project>_mutated_worker<n>.DerivedData.noindex`. Muter's runs each add a folder of 3–67 MB
  to `~/Library/Developer/Xcode/DerivedData`, which nothing removes. The runs
  also pass `-collect-test-diagnostics never`, so a failing run doesn't spend seconds collecting
  diagnostics no one reads, but only when `executable` lists that option in its `-help`, which
  SwiftMutator asks once per run. Without it, as for an older Xcode or a wrapper that doesn't pass
  it on, the runs collect diagnostics as before.
- **Spotlight skips the copies:** every folder SwiftMutator makes beside the project has a name
  that ends in `.noindex`: the copy, `<project>_mutated.noindex` (`<project>_mutant.noindex` for
  `--mutant`), the worker clones, `<project>_mutated_worker<n>.noindex`, and the xcodebuild derived
  data folders, `<project>_mutated.DerivedData.noindex` and
  `<project>_mutated_worker<n>.DerivedData.noindex`. Spotlight skips such a folder, `.build` and
  all, while it would otherwise index each copy as the run builds and writes into it. It goes only
  by the folder's own name, so `.noindex` comes last: it would index
  `<project>_mutated.noindex_worker1`. Copying BonMot with its 406 MB `.build` beside it and building
  it, then waiting 90 s, Spotlight (`mdworker_shared`, `mds_stores`, `mds`) used 4.7 s and 7.4 s of
  CPU with the copy named `X_mutated`, and 0.9 s and 0.7 s with it named `X_mutated.noindex` (two
  alternating trials each; the copy took 2 s, the incremental build 6 s). The rest is Spotlight's
  idle level. The lock, the active-mutant files and the helper links keep the names they had, as
  `<project>_mutated.lock` and `<project>_mutated_worker1.active-mutant`. The log folder,
  `<project>_muter_logs`, keeps its name too, so scripts and CI paths that name it still work, and
  Spotlight still indexes it.
- **Boundary mutants:** `RelationalBoundary` turns `<` into `<=`, `<=` into `<`, `>` into `>=` and
  `>=` into `>` ([#102](https://github.com/Joseph-Cursio/SwiftMutator/issues/102)).
  `RelationalOperatorReplacement` turns `<` into `>`, which almost any test kills; a boundary
  mutant survives unless some test checks the edge value. It runs by default, beside
  `RelationalOperatorReplacement`, so each ordering operator gets two mutants, and a run has one
  more mutant for each one it mutates. A `--mutant` that gives such a place without an operator
  names both, so it is refused with each one listed, ready to paste ([Testing one
  mutant](#testing-one-mutant)). As the run's operators are no longer the four an older
  SwiftMutator recorded, `--resume` and `--reuse` refuse a run it made without `--operators`. To
  continue one, name its four operators, `--operators RelationalOperatorReplacement
  RemoveSideEffects ChangeLogicalConnector SwapTernary`, with the `--force-resume` or
  `--force-reuse` that a run by another SwiftMutator needs anyway. See
  [mutation_operators.md](Docs/mutation_operators.md).
- **Negated conditions:** `NegateConditional` wraps each expression condition of `if`, `guard` and
  `while` in `!( )`, which sends the code down the other branch
  ([#106](https://github.com/Joseph-Cursio/SwiftMutator/issues/106)). It runs by default, and adds
  42% to SwiftProjectLint's mutants, of which 1 of 313 sampled timed out. While
  `RelationalOperatorReplacement` is on, a condition that is one `==` or `!=` comparison is left to
  that operator, whose swap is the same mutant, and `--mutant` still finds such a mutant that a run
  without that operator reported. A run recorded before it is continued as above, by naming that
  run's operators with `--operators`. See [mutation_operators.md](Docs/mutation_operators.md).
- **Arithmetic and boolean literals:** `ChangeArithmeticOperator` swaps `+` and `-`, swaps `*` and
  `/`, and turns `%` into `*`, as well as their assignment forms. `FlipBooleanLiteral` turns `true`
  into `false` and back ([#111](https://github.com/Joseph-Cursio/SwiftMutator/issues/111)). Both
  run by default, and add 28% to SwiftProjectLint's mutants and 20% to SwiftCloneDetector's. As `+`
  and `+=` also join strings and arrays, they get a mutant only with a sign that their operands are
  numbers. Of 270 arithmetic mutants on those two projects, 1 didn't compile, and 9 timed out. There
  are no tiers of operators, as the numbers per operator don't call for them. A run recorded before
  these operators is continued as above, by naming that run's operators with `--operators`. See
  [mutation_operators.md](Docs/mutation_operators.md#what-each-operator-catches-and-costs).
- **Choosing the files** ([#115](https://github.com/Joseph-Cursio/SwiftMutator/issues/115)): the
  default excludes also leave out test doubles and helpers, `/Mocks/`, `/Stubs/`, `/Fakes/`,
  `/TestHelpers/`, `/TestSupport/`, `Mock.swift` and `Spec.swift`, and `/Snippets/` and
  `/DerivedData/`, so a project whose own code lives in such a folder finds fewer mutants. An
  `exclude` entry that starts with `!` keeps what it matches. `--exclude` adds entries for one run.
  `--files-to-mutate` takes folders, absolute paths in the project and globs as `exclude` reads them,
  keeps the excludes and the coverage filter, which it used to skip, and says which of its entries
  leave no file, which it used to drop without a word; a file named twice is mutated once. An empty
  `exclude` entry, which used to leave out every file, is refused. See
  [Choosing the files](#choosing-the-files).
- **Time limits before the first mutant** ([#117](https://github.com/Joseph-Cursio/SwiftMutator/issues/117)):
  `buildTimeout`, which limited only the coverage run, now also limits each xcodebuild build for
  testing, each baseline run and each worker clone's, and gives the timed test run a limit from the
  baseline's time; `--build-timeout` sets it for one run. A build or baseline stopped there exits
  with 3. So does an xcodebuild project that doesn't build for testing, which exited with 255. A
  failed baseline's message lists its failed tests, up to 20, before its log. See
  [Time limits before the first mutant](#time-limits-before-the-first-mutant).
- **Disable tags act once, by where they are:** the nodes that share a `// muter:disable` or
  `// muter:enable` used to take turns acting on it, so a tag beside code could silently fail,
  depending on how many nodes shared it. Now a tag beside code leaves that code off: a `disable`
  covers what it ends and what follows, and an `enable` starts after it. A `disable` or `enable` on a
  block's last statement no longer reaches its earlier statements, and a tag inside a statement now
  counts for `RemoveSideEffects` on the statements after it. So a file with such tags can find
  different mutants. See
  [Disable muter in code](Docs/Muter-README.md#disable-muter-in-code).
- **Directives match the word, and cover a line or a declaration:** a `muter:` directive counts only
  as the first word of a comment, of any kind: `//`, `///`, `/* */` and `/** */`. A comment that only
  mentions one, as `// TODO: muter:disable`, used to turn off the rest of the file, and one in `///`
  or `/* */` did nothing. A `disable` beside the last element of a list, or its last argument or
  case, no longer reaches the earlier ones. `// muter:disable-next-line` and
  `// muter:disable-declaration` leave out one line or one declaration, with no `muter:enable` to forget
  ([#115](https://github.com/Joseph-Cursio/SwiftMutator/issues/115)). See
  [Leaving code out](#leaving-code-out).
- **Logging through the injected printer**, so log output can be captured and tested.

Fixes that apply to Muter are offered upstream too.

## Build and run

```bash
swift build -c release --product swift-mutator
.build/release/swift-mutator init      # writes muter.conf.yml in the current project
.build/release/swift-mutator run       # runs mutation testing
```

`make install` installs `swift-mutator` into `/usr/local/bin`.

A run tests in a copy of the project beside it, `<project>_mutated.noindex`, so a project has one
run at a time. `run`, `mutate-without-running` and `run-without-mutating` lock
`<project>_mutated.lock` before they read, remove, copy or test anything there. One started while
another holds the lock is refused, naming the process that holds it and the folder it runs in
when the lock file shows them, and leaves everything as it was. The lock has the name it had
before the copy's name ended in `.noindex`, so an older SwiftMutator, running in
`<project>_mutated`, and this one exclude each other too. This one names the older run's folder,
`<project>_mutated`, but an older one it refuses names its own, not `<project>_mutated.noindex`.
It exits with status 6: run the same command again once that run has ended. The lock goes when SwiftMutator exits, however it exits, so it never needs clearing; the
file stays, made with the permissions your umask gives new files, so anyone who can remove the copy
can lock it.

`swift-mutator mutate-without-running` writes a test plan without testing anything, and
`swift-mutator run-without-mutating` tests it (see [Test plans](#test-plans)). `--mutant` tests one
mutant on its own (see [Testing one mutant](#testing-one-mutant)).

### Exit status

`run`, `mutate-without-running` and `run-without-mutating` exit with:

- **0** when the run finished, and met `--fail-under` or `failUnder` (see
  [Failing on a low score](#failing-on-a-low-score)), and when there is nothing to mutate, as for a
  `--since` change with no Swift file, or a `--shard` that holds no mutant.
- **2** when the run finished with its headline score below `--fail-under` or `failUnder`, or with
  every mutant a build error, whatever the threshold. Every report, the results file and
  `summary.json` were written first.
- **3** when the baseline run, with no mutant on, failed in the project's copy, or in a parallel
  worker's clone of it when `mutationTestWorkers` or `--workers` asked for those workers, for any
  reason but [mutants that don't compile](#mutants-that-dont-compile) outside a test plan, or an
  xcodebuild project didn't build for testing, or one of these ran past `buildTimeout` (see
  [Time limits before the first mutant](#time-limits-before-the-first-mutant)). Nothing was
  tested. The message lists the tests the baseline failed, up to 20, before its log. A clone that
  fails, or runs past its limit, with the default count of workers makes the run test one mutant at
  a time instead.
- **4** when an error stopped mutation testing partway, such as 5 build errors in a row, or a
  simulator that went away. The results so far are kept, and the run can be resumed.
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
- **255** for any other error, such as a missing configuration or one that doesn't parse, a
  `--mutant` that names no mutant, or a `--since` that git can't answer. Earlier SwiftMutators
  exited with 255, not 3, for an xcodebuild project that didn't build for testing.
- **128 plus the signal** when a signal stopped the run: 130 for SIGINT, 143 for SIGTERM and 129 for
  SIGHUP (see [Stopping a run](#stopping-a-run)).

Earlier SwiftMutators exited with 255 for a refused resume or reuse, for a run refused by
another's lock, for a failed baseline and for an abort, so a script that checked for 255 there
needs to check for 5, 6, 3 and 4 instead
([#96](https://github.com/Joseph-Cursio/SwiftMutator/issues/96)). `report` has statuses of its own
(see [Results file](#results-file) and [Exit status](Docs/results-file.md#exit-status)).

### Failing on a low score

`--fail-under <percent>`, on `run`, `run-without-mutating` and `report`, or `failUnder` in
`muter.conf.yml`, which `--fail-under` replaces for one run, fails a CI job whose score is too low
without parsing a report. It is a percent from 0 to 100, written in plain digits with up to 6
decimals, such as `80` or `72.5`; anything else, such as `1e2` or `0x50`, is a usage error, 64, or
for the key a configuration error, 255.

- **Which score.** The headline score, the one every report prints, which counts kills by suspect
  tests too, but not one that [no longer failed when tested again alone](#kills-tested-again-alone).
  The exact score is compared, killed over scored, never the whole percent the reports
  show, so a change in how the score is shown can't change the verdict, and a score equal to the
  threshold passes: 29 killed of 50 scored is 58%, and passes `--fail-under 58`.
- **When it is checked.** Once the run finishes, after every report, the results file and
  `summary.json` are written. Below the threshold, the run exits with 2. Its verdict is its last
  line, after where each result is:

  ```
  ❌ Mutation score 71.4% is below the required 80%.
  ✅ Mutation score 83.0% meets the required 80%.
  ```

  The score shows as many decimals as the threshold has, at least one, truncated, so it never
  shows on the other side of the threshold.
- **When nothing was scored.** A run whose every mutant was a build error, as when none compiles,
  fails, with status 2: there was something to measure, and nothing shows the threshold is met. A
  run with nothing to mutate, as for a `--since` change with no Swift file, or a `--shard` that
  holds no mutant, exits with 0 as before, and says nothing of it.
- **Mutants left out of the score.** The score leaves out build errors, so taking mutants that don't
  compile out of a run can raise it, and the verdict's line says how many there were. A mutant taken out
  with others may compile, so taking it out can't help a run pass: the threshold is checked against
  the headline score with such mutants counted as not killed, and the line gives that score.
- **What isn't checked.** A run of one mutant (`--mutant`), whose score isn't the project's, and a
  shard of a `--shard` split, whose score isn't the whole run's, say so in their last line and exit
  with 0; check the merged report with `report --fail-under` instead (see
  [Splitting a run across machines](#splitting-a-run-across-machines)). A run that a signal or an
  error stopped exits for that, and says nothing of the threshold. A `--sample` and a `--since`
  run are checked, on the score they report.
- **`report --fail-under`** checks the results file's score, or the merged score of shards' files,
  and says its verdict last, on standard error. It reads no configuration, so the run's own
  `failUnder` isn't checked again. A run that stopped on an error exits as it did, and shards whose
  merged report lacks results exit with 4, without checking. A run that was interrupted, or has no
  end line, is checked on what it tested, and the verdict says how many of its mutants have
  results. With none yet for the mutants it discovered, as when it was stopped just after its
  baseline, it exits with 2: nothing shows the threshold is met.
- **summary.json** records the verdict in `gate` (see [summary.json](#summaryjson)).

A resume lets the threshold change, as no result depends on it: the change is only said.

## Mutants outside function bodies

Every mutant is a branch of a switch around a copy of its code, usually its statement list. A file's top level can't
hold one when it has a declaration: an `if` around an `import` or a type doesn't compile. So the switch goes around
less:

| Code | What the switch goes around |
|---|---|
| A stored property's or a global's initial value: `static let isLarge = size > 1` | The value, as an `if` expression, or as an `if` expression in a closure called on the spot when the value or a type around it has an attribute, which may be a macro that copies the value into a call, as `@State` does |
| A default argument: `func load(retry: Bool = count > 1)` | The value, as an `if` expression in a closure called on the spot, since a default argument can't be an `if` expression |
| A statement in a `main.swift` with an `import`: `if count > 1 { … }`, `total = count > 1 ? 1 : 2`, or a `guard` with neither `let` nor `case` | The statement |

Your tests see the same code either way: the original branch holds the code as it was, and each mutant's holds it with
the one change. An initial value that is a macro alone, such as `#Predicate { $0 > 1 }`, is returned from each branch of
a closure called on the spot, as a macro can't be a branch's value by itself.

Coverage says less about this code. Swift's coverage has a region for an instance property's initial value, and for the
right-hand side of `&&`, `||` or `??` anywhere, but none for the rest of a global's or a `static` property's value, or
of a default argument. So it can't show that a test never reached those, and their mutants are tested either way. One
no test reaches is [not covered](#whether-a-mutants-code-ran), and counts against the score, so `// muter:disable` or `exclude` can leave out a default that
is there for callers your tests aren't. Two more things follow:

- A file with nothing but such values is named by no coverage data. SwiftMutator keeps it when a file the data does name
  shares its folder, or a folder inside or around it, as that looks like a target the tests ran. Other such files are
  left out with the rest of what the tests don't reach, as a file at 0% is, however many values it has.
- A SwiftPM test doesn't run an executable's `main.swift`, so with coverage that file reads 0% and is left out. Its
  statements are mutated with `--skip-coverage`, or when tests do run it.

Some code still has nowhere to put a switch, and its mutants are dropped:

- a macro that is a statement or a declaration by itself at a file's or a type's top level, such as `#Preview { … }`,
  which can declare anything;
- an attribute's arguments, as in `@Wrapper(limit > 1) var value`;
- a `guard let` or `guard case` at a file's top level, which may bind a name the code after it uses;
- a value that starts with `#line`, which a branch would read as a directive;
- the default of a parameter of a non-escaping function type, which a closure's result can't convert to;
- a block nested in a `some` body that has mutants of its own, and a closure passed to what looks like a type's
  initializer, `VStack { … }`, in a value that has mutants of its own and no type of its own named. In each, a nested
  switch could give one branch of the `if` expression around it another type.

Discovery ends with how many it dropped, `--verbose` lists each one, and the results file's header records the count as
[`mutantsDropped`](Docs/results-file.md#header). With `--changed-lines`, only those on changed lines count. A `--mutant`
run says nothing about them, and `--sample` and `--shard` count them for all the code discovery looked at, since a sample
or a shard can't hold a mutant that was dropped.

```text
ℹ️ SwiftMutator left out 3 mutants with nowhere to put a switch, so no report covers them. --verbose lists them.
```

## Code an `#if` leaves out

A mutant in code the build doesn't compile can never be killed, and would count as a survivor. So discovery evaluates
each `#if` against the build the run tests, and drops the mutants in the branches it leaves out. Coverage does some of
this too, but it has no record of a whole declaration in an `#if`, and none at all with `--skip-coverage`.

SwiftMutator works out what the build compiles with from the build itself, so an iOS Simulator run mutates `#if os(iOS)`
and drops `#if os(macOS)`:

| Asked | `swift test` | `xcodebuild` |
|---|---|---|
| `os`, `arch`, `targetEnvironment` | This machine, unless `--triple`, `--arch`, `--swift-sdk`, `--destination` or `--sdk` builds for another | `-showBuildSettings`, which follows `-destination` |
| Custom conditions, such as `DEBUG` | `DEBUG` in a debug build, `SWIFT_PACKAGE`, each target's `.define`s and `-D` flags in `unsafeFlags`, and `-Xswiftc -D` in `arguments` | `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and the `-D` flags in `OTHER_SWIFT_FLAGS` |
| `canImport` | The SDK's modules | The SDK's modules |

Whatever it can't tell, it leaves alone: the branch keeps its mutants, and coverage can still filter them out as before.
So what it can't work out doesn't cost you code your build compiles. These stay undecided:

- `swift(…)`, `compiler(…)`, `hasFeature(…)` and `hasAttribute(…)`, and `canImport` of a submodule or with a version;
- `canImport` of a module in no SDK, which may be a package's, and any `canImport` in a Mac Catalyst build;
- `arch(…)` in a build for several architectures, as a generic destination is, unless it is none of them;
- a condition only some targets set. SwiftPM says which targets compile each file, so there it's only those targets'.
  xcodebuild doesn't, so there it's all the targets it reports, for the test bundles and for the scheme;
- with xcodebuild, a condition no reported target sets but that a `project.pbxproj`, `.xcconfig` or package manifest in
  the project names, as it may be set for a target that wasn't reported; and any other `SWIFT_` condition, as Xcode sets
  `SWIFT_PACKAGE` for a local package's code;
- with SwiftPM, a package's traits, and a `.define` that a trait enables.

A later clause can still be decided after an undecided one: after `#if canImport(SomePackage)`, an `#elseif os(iOS)` is
left out of a macOS build, and an `#elseif os(macOS)` rules out the `#else` after it.

`canImport` reads a module that only another platform's SDK has as absent, so a package of yours named after one, say
`CarPlay` on macOS, would have its `canImport` branch read as left out.

If the conditions can't be read at all, as for a test command that isn't `swift`, a Swift package's scheme under
xcodebuild, which has no build settings, or `-xctestrun`, SwiftMutator says so and every branch keeps its mutants:

```text
ℹ️ SwiftMutator couldn't tell which `#if` branches the build compiles: xcodebuild reported no build settings.
Every branch keeps its mutants, unless coverage shows that the build left it out.
```

Otherwise discovery ends with how many it dropped, `--verbose` lists each one, and they count towards
[`mutantsDropped`](Docs/results-file.md#header), as those [with nowhere to put a switch](#mutants-outside-function-bodies)
do. Code under `// muter:disable` isn't counted. A mutant in such a branch no longer exists for `--mutant` to name.

```text
ℹ️ SwiftMutator left out 15 mutants in `#if` branches this build doesn't compile, so no report covers them. --verbose lists them.
```

## Time limits before the first mutant

Every mutant's run has a time limit, and with `buildTimeout` or `--build-timeout` set, so does each
step before the first mutant, so that a hung build or test in an unattended CI job ends the run
rather than holding the job until the CI system's own limit
([#117](https://github.com/Joseph-Cursio/SwiftMutator/issues/117)). Each of these steps builds the
project, runs its tests, or both, and may take `buildTimeout` seconds:

- the coverage run. Stopped there, mutation testing goes on without coverage, as after any coverage
  failure.
- each xcodebuild build for testing, the first and any build again without
  [mutants that don't compile](#mutants-that-dont-compile).
- each baseline run, the first and any run again without mutants that don't compile.
- a worker clone's baseline, and an xcodebuild worker's run with no mutant on, on its simulator,
  which doesn't build but runs the tests one at a time. They run at once, so each may take the whole
  limit.

A build or a baseline stopped there stops the run with exit status 3, as a failed one does, and
nothing is tested. Its message names the step, the limit and its log, then the tests that failed so
far and the last lines it printed, which show where it hung. A clone or a worker's simulator stopped
there makes the run test one mutant at a time instead, as one that fails does: a clone only with
the default count of workers, and a worker's simulator with any count.

The runs after the baseline that skip the build, the direct and the timed test run, should take less
than the baseline, so each may take 5 times as long as the baseline did, or as the slowest xcodebuild
worker's run with no mutant on did if that took longer, but at least a minute, and never more than
`buildTimeout`. A timed run
stopped there times nothing: each mutant's limit comes from the baseline instead, and the run goes on
and says so. Without `buildTimeout`, none of these steps has a limit, as before.

## When the baseline crashes

Every mutant is compiled into one build, so a function's code is there once for each mutant in it. A
debug build gives each copy's local variables their own stack space. On SwiftProjectLint, one file's 44
mutants took a function's frame from 3,408 to 12,928 bytes, and another's from 4,064 to 46,112, so a
recursion that fit its thread's stack no longer did. The test process then crashes in the baseline, with
no mutant on, and the run stops with exit status 3.

SwiftMutator says when a baseline's log shows a crash that could be this: a test process ended by SIGBUS
or SIGSEGV under `swift test`, and more doubtfully, xcodebuild's `Restarting after unexpected exit,
crash, or test timeout`. A log can't show that it was: on a Mac, the crash report in
`~/Library/Logs/DiagnosticReports` says `Thread stack size exceeded`, under the function that repeats at
the top of the crashed thread. Swift Testing's tests under xcodebuild leave no such line, only the test's
name under `Failing tests:`.

To go on, leave that function out: its file with `exclude`, or the function alone with
`// muter:disable-declaration` above it (see [Leaving code out](#leaving-code-out)).

## Mutants that don't compile

All of a run's mutants are compiled into one build, so one that doesn't compile would fail the build
of all the others. A mutant can fail to compile where the rewrite is right: `<` to `<=` on a type that
defines only `<`.

So when a run's baseline fails to compile, SwiftMutator matches each error in a rewritten file to the
mutants at fault, writes the file again without them, and builds again, until the build passes, no
mutant can be blamed, or 20 builds have failed:

```
🔁 The build failed where 1 mutant is, so SwiftMutator is building again without it.
💾 SwiftMutator saves each mutant's result as it finishes, in /Users/me/Foo_muter_logs/…/results.jsonl
⚠️ 1 mutant doesn't compile, so SwiftMutator took it out of the build, and won't test it. The score leaves it out, the reports list it as a build error, and --resume tries it again:
  Sources/Foo/Version.swift:9:19 RelationalBoundary (changed < to <=): binary operator '<=' cannot be applied to two 'Version' operands
```

- **What it records.** Each one is a build error, in the results file and in every report, with a log
  of its own that gives the compiler's error. Its tests never ran, so it counts for neither the score
  nor the 5 build errors in a row that stop a run. The run ends by saying how many there were.
- **Which mutants it blames.** An error in a mutant's own code takes out that mutant. An error on a
  list of mutants as a whole takes out the list. An error elsewhere, such as a missing `return`, takes
  out the mutants around it that remove a statement, and if it stays, the other mutants of the
  function, accessor or closure around it, or if it has none, of its file. The warning says how many
  went with others, and may compile, and `--fail-under` counts those as not killed. The compiler can report one error of many per build, and each
  build takes time, so after 5 failed builds errors are blamed on the code around them, and after 10
  on their files.
- **What still stops a run.** An error in a file with no mutants left, in a file SwiftMutator didn't
  rewrite, or in an `import`, is your project's own: the run stops as it would have, exiting with 3,
  with the log of the last build. Earlier SwiftMutators exited with 255 for xcodebuild. An error in the code SwiftMutator adds
  to a file, a switch's condition or the environment it reads, stops the run too. No mutant is to
  blame for it, and it is a bug in SwiftMutator: please report it. So does a 21st failed build, which
  can take a project with mutants that don't compile in very many files: leave those files out with
  `--files-to-mutate` or `exclude`, or their operators with `--skip-operators`.
- **The failed builds' logs** are in the run's log folder, as `failed build 1.log` and so on. The
  last build's is too, as `baseline run.log` when it was a baseline.
- **Resuming.** `--resume` tests build errors again, so each session finds these mutants again, which
  costs the failed builds again, even with nothing else left to test.
- **Test plans.** A test plan's run tests its copy as it is, and stops at a compile error: fix it in
  the copy, or make the plan again without its operator (`--skip-operators`). See
  [The test plan](Docs/test-plan.md).
- **Limit.** Under `-diagnostic-style=llvm` the compiler doesn't count a lone carriage return as a
  line break, so in a file that has any, an error can be blamed on the wrong mutants. They are still
  reported as build errors.

If every mutant fails to compile, nothing is tested, and a run with a threshold fails. A run with none
exits with 0, as a finished run does, having said it tested nothing. `summary.json` then has no
`mutationScore`, and the Xcode format lists the warning as an issue.

## Test plans

`swift-mutator mutate-without-running` makes the copy, puts every mutant's switch into it, and
writes a test plan, `muter-mappings.json`, without testing anything, so you can fix the copy by hand
first, such as code the rewriting left unable to compile. `swift-mutator run-without-mutating
muter-mappings.json` then tests it. See [The test plan](Docs/test-plan.md).

- **Choosing the mutants.** Like `run`, `mutate-without-running` takes `--files-to-mutate`,
  `--exclude`, `--operators` and `--skip-operators`, and follows the `operators` and `skipOperators`
  keys. The plan records the result, and so does the results file of a run that tests it, which then
  looks at neither key. `--exclude` is the exception: the plan's mutants leave its files out, but
  neither the plan nor the run that tests it records its entries.
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
  project removes `<project>_mutated.noindex`, with any fix in it. `run --mutant` doesn't: it has a
  copy of its own.

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
Mutated project kept, with the mutant switched off: /Users/me/Foo_mutant.noindex
To run its tests with it on:
  printf '%s\n' 'Rules_9c41…' > '/Users/me/Foo_mutant.active-mutant' && cd '/Users/me/Foo_mutant.noindex' && IS_MUTER_RUNNING=YES SWIFTMUTATOR_ACTIVE_MUTANT_FILE='/Users/me/Foo_mutant.active-mutant' /usr/bin/swift test
```

- **The change** is the mutant's line in your project's file, before and after. When that line
  can't be found, as for code that spans lines, or a plan's file that changed since the plan was
  made or that the plan doesn't record, as a plan in format 0 doesn't, it is the code the mutant
  changes, as the mutant records it.
- **The log** is printed whole up to 400 lines, and otherwise from its last 200; the log folder
  keeps it whole.
- **Exit status** is 0 whatever the verdict, which the results file records too, and
  `--fail-under` isn't checked: one mutant's score isn't the project's. A reference that
  doesn't read as a mutant is a usage error, 64. One that names no mutant exits with 255 and lists
  the mutants near it, ready to paste, whatever operator it names, and one that names several lists
  them. One of several mutants an operator makes at the same place is refused too: they share one
  switch, so none can be tested on its own, and the lists name such a place without a `--mutant`
  to paste. An absolute path may be spelled through a link, as `/tmp` is `/private/tmp`.
- **`run --mutant`** skips coverage, finds every mutant, and puts only that mutant's switch into a
  copy of its own, `<project>_mutant.noindex`, which it keeps for a look afterwards. A test plan's
  `<project>_mutated.noindex`, and any fix in it, is left alone. `<project>_mutant.noindex` stays
  until the next `run --mutant`.
- **`run-without-mutating --mutant`** tests the plan's copy as it is, without rewriting it. The
  project is checked against the plan as for a whole run, but only a change to that mutant's file
  refuses it: one to a file with the plan's other mutants is only said.
- For an xcodebuild project, only the switch's environment variable is named, not a command.
- `--mutant` can't be given with `--operators`, `--skip-operators`, `--files-to-mutate`, `--exclude`, `--since`, `--shard`,
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

So `tail -f run.log` follows the run, and `grep 'survived at' run.log` lists the survivors so far,
and `grep 'not covered at' run.log` the mutants [no test reached](#whether-a-mutants-code-ran).
A resumed run's lines count only the mutants it tests, so they leave out the results it kept;
`swift-mutator report` gives them all. Standard output counts as a terminal where colour can show:
it's a tty, and `TERM` is set and isn't `dumb`. `NO_COLOR` turns off the colour, not the bar.

The Swift files a run finds, then how many mutants are in each file that has any, are listed only
with `--verbose`.

### Whether a mutant's code ran

Each mutant's run records whether its code ran, as `activated` on its line in the
[results file](Docs/results-file.md#mutant). The generated code creates a marker file the first time
the mutant's block runs in a test process, and a second file the first time the process reads any
mutant's switch, which shows it could have made the first. They sit in
`<project>_mutated.Activation.noindex`, beside the project.

- **A survivor whose code never ran is _not covered_.** No test reached it, so nothing could have
  killed it. The reports list these apart from survivors, and the progress lines and counts say
  "not covered". The score counts them as it counts survivors, so they weigh against it, and a
  survivor turning into one changes neither the score nor `--fail-under`. Its line in the results
  file still says `passed`, with `activated: false`. A label in the triage file stays on it.
- **A kill whose code never ran is tested again, by itself.** A flaky test or a crash at launch may
  have failed it, and what this run shows stands in its place: a kill if its code runs and its tests
  fail, a survivor if its code runs and they pass, not covered if neither. So a kill can turn out not
  to be one, which lowers the score, and `--fail-under` with it, by correcting it. One that fails
  again without running its code stays a kill, and the run ends with a warning, its log kept. Its
  tests fail whatever the mutant, so there's no other verdict to give it.
- **A timeout whose code never ran** is tested again the same way, on one worker. With more, every
  timeout is [tested again](#timeouts-are-run-again) already.
- **Not every run can show this.** In a session none of whose runs shows either file, every verdict
  stands as it would have, with no `activated`, nothing is tested again, and the session says so. A
  sandboxed test host can't write beside the project, as a run under the App Sandbox showed, and a test
  on a device can't reach it, though a test host on a simulator can. A run of a test plan made by an older SwiftMutator has no markers
  either. A scheme that mixes the two has one limit: if its unhosted tests can write and a mutant
  runs only in a sandboxed host, that mutant reads as not having run.
- **A run that switches on no mutant stops.** After five mutants' `swift test` runs show nothing,
  though coverage says the tests reach them, SwiftMutator stops rather than report every mutant as
  a survivor: a wrapper script is probably dropping `SWIFTMUTATOR_ACTIVE_MUTANT_FILE`. Without
  coverage, under xcodebuild, or for a test plan, it only warns, as any of those can be healthy.
  `--resume` tests that session's mutants again.

A marker says the block around the mutant was entered, not that the mutated expression ran: an early
`return` above it can leave a mutant unrun with its marker made. So "not covered" is the strong
signal, and with coverage on it should be rare, as the coverage run has already left out the code
no test reaches. On SwiftCloneDetector it found none with coverage on, and 8 of the 15 mutants
coverage leaves out with `--skip-coverage`. The other 7 are in blocks the tests enter.

`run --mutant` reports what its one run shows and tests nothing again.

## Reports

The plain and HTML reports start with the mutants to act on: those that survived, and those that
timed out, which the score counts as survivors too, then any [no test reached](#whether-a-mutants-code-ran),
in a section of their own. They are listed by path, line and column, each with the line it changes,
before and after:

```
Sources/Lint/Rules.swift:42:17 survived: RelationalOperatorReplacement (changed == to !=)
    -42:         if count == limit {
    +42:         if count != limit {
```

- **Paths in the project.** The tables of mutants and of files name each file by its path relative
  to the project, and a mutant by `path:line:column`, so two files called `Rules.swift` are told
  apart. A file outside the project keeps its absolute path. The Killing Tests table names a test's
  file as its log recorded it. The Xcode format keeps the absolute paths Xcode needs. The JSON
  report gives each file its `path` in the project, and each mutant its `path`, its `key`, which
  `--mutant` takes, and its `durationSeconds`; `mutationPoint.filePath` is still its path in the
  mutated copy.
- **Durations.** The plain and HTML reports' table of mutants has a Duration column: how long each
  mutant's run took, as its results line records it.
- **The changed line** comes from the original file, never the mutated copy, whose code holds
  every switch. It is shown only while the file is as it was tested: its SHA-256 must match the
  one the run recorded, so an edit made since, which could move the line, shows the change as the
  mutant's snapshot gives it instead. So does a change that spans lines, as a multi-line ternary
  does. Where no hash can be checked, the line is shown only if the change starts exactly at the
  mutant's line and column. That is the case for `swift-mutator report` of a test plan's run,
  whose session records the plan's rewritten copy, and for a file that is a symbolic link, which
  the run records by where it points. A merged report shows no line from a file that
  `--merge-ignoring` let differ between the shards. The HTML report shows the line in its Changes
  column for every mutant. The JSON report holds it as `sourceChange`: `line`, `before` and
  `after`, which a removed statement that leaves nothing on its line doesn't have.
- **Counts by outcome.** Every report counts the mutants by outcome as the progress lines do, with
  a crash counted as a kill: `By outcome: 98 killed, 15 survived, 4 timed out, 3 build errors, 2 not covered` in
  the plain and HTML reports, `Mutants by outcome:` in the Xcode format, and `mutantsByOutcome` in
  the JSON report, with every count, zeros included.
- **The score when a run ends.** A run that saves its report with `-o` doesn't print it, so it
  prints the score and the counts before saying where the report went:

  ```
  📊 Mutation score: 83% (98 killed, 15 survived, 4 timed out, 3 build errors)
  📝 Report generated: report.html
  ```

  `swift-mutator report -o` says the same on standard error, without the emoji, before
  `Report saved to`.
- **Where the results came from.** The plain and HTML reports end with a Run section, and the JSON
  report has `run`: the results file, or each shard's for a merged report, how many sessions made
  the results, then the SwiftMutator version and its executable's SHA-256, as no commit is built
  in, the toolchain, the workers and the time limit, as the last session that tested a mutant
  recorded them. A resumed or reusing session with nothing left to test doesn't count; when no
  session tested any, as for a `--reuse` of an unchanged project, it says `Workers: none`. For a
  merged report, the sessions are every shard's added up, and the rest is the first shard's. The
  JSON's `run` also has the configuration as loaded. A run whose results file couldn't be made, or
  written in full, has no Run section.

  ```
  Results file: /Users/me/code/SwiftProjectLint_muter_logs/Oct 4, 2026 at 1:16 PM/results.jsonl (2 sessions)
  SwiftMutator: 1.4.0, executable SHA-256 3f9a…
  Toolchain: Apple Swift version 6.2 (swiftlang-6.2.0.19.9 clang-1700.3.19.1)
  Workers: 4; time limit per mutant: 24 s, the default
  ```

### Triaging survivors

A survivor is a missing test, or a mutant no test could kill, or code you don't mean to test, and
only a person can say which. `swift-mutator triage` records what you decided, in
`muter.triage.yml` beside `muter.conf.yml`, and the reports show it from then on
([#105](https://github.com/Joseph-Cursio/SwiftMutator/issues/105)). Commit the file, so the labels
carry across runs and to the people you work with.

```
swift-mutator triage 'Sources/Lint/Rules.swift:42:17 RelationalBoundary' --results '/…/results.jsonl' --label equivalent --note 'count never exceeds limit here'
swift-mutator triage 'Sources/Lint/Rules.swift:42:17 RelationalBoundary' --remove
```

- **The labels.** `missing-test`, `equivalent`, `out-of-scope` and `tool-limitation`.
- **Which mutants take one.** Those that survived, timed out or no test reached in the run `--results` names, its
  results file or a log folder. The mutant is named as `--mutant` names one, and a name that fits
  several lists them. Labelling a mutant again replaces its label, and keeps every other, saving
  those that followed their code at their new places.
- **It changes no score.** Not the headline score, not `--fail-under`, not `summary.json`. A label
  is someone's word, which a CI job's threshold shouldn't rest on, and `equivalent` is often wrong.
- **What the reports show.** The plain text, HTML and JSON reports mark each labelled survivor, and
  add a Triage section. The Xcode format and `summary.json` don't.

  ```
  Sources/Lint/Rules.swift:42:17 survived: RelationalBoundary (changed >= to >)
      -42:     if count >= limit {
      +42:     if count > limit {
      Triaged: equivalent: count never exceeds limit here
  ```

  ```
  Of the 15 mutants that survived or timed out, 9 are triaged in muter.triage.yml, and 6 aren't.
  By label: 4 missing test, 3 equivalent, 1 out of scope, 1 tool limitation.
  ```
- **When code moves.** A mutant's key holds its line and column, which any edit above it changes, so
  an entry also holds what its mutant changes and the line it's on. A label applies at its key while
  those still match. Otherwise it follows its code to the one mutant in its file with the same
  operator, change and line, whatever the line's indent, and keeps following it with no need to save
  it again. It labels nothing rather than guess: with no such mutant, or two, or another label on that
  one or after it, or a change to the line itself, the report lists it as matching no mutant, and you
  decide again.
- **What that can't tell apart.** Two identical lines in a file. A label can follow to the other
  one, if its own was removed and only that one is left. And a label at its key can't be told from
  an identical line that an edit shifted onto that key, so identical lines an equal distance apart
  can each take the next one's label. The note is there to catch this.
- **What the report asks you to look at.** Labels that followed their code, labels on mutants that
  no longer survive, as a test now kills them, labels on mutants that weren't tested, as they were build errors, and labels that match no mutant, up to 10 of each. The
  JSON report lists them all.
- **Results of part of a project.** Results that leave out some of a file's mutants say nothing about
  those, so no label follows its code in them, and a label whose mutant isn't in them matches nothing.
  That goes for `--mutant`, `--shard`, `--sample`, `--since --changed-lines` and a run that stopped.
  A plain `--since` tests whole files, so its labels in those files follow as usual.
- **Removing a label.** `--remove` with `--results` removes the label on the mutant at the place those
  results show, or a label matching no mutant in them. Without `--results` it takes the key the file
  holds, which is older than what a report shows if the code moved: the report gives that key for a
  label that followed its code. Either way it says what it removed.
- **Where the file is looked for.** A run reads `muter.triage.yml` in the folder it runs in.
  `swift-mutator report` reads the one in the run's project, then the current folder's, or the file
  `--triage <path>` names. `swift-mutator triage` writes to the run's project, or the current folder
  if that's gone, or `--file <path>`, and `--remove` without `--results` to the current folder or
  `--file`. A file that is a symbolic link stays one.
- **A broken file** refuses a run as it starts, so a typo doesn't wait for the end of a long one, and
  refuses `report` and `triage`, which leaves the file as it was. That's YAML that won't parse, a key
  it doesn't know, as a misspelling would be, a label it doesn't know, two labels for one key, text
  that isn't UTF-8, and a file it can't open. If it breaks during a run, the report is made without
  labels and says so.
- **It's only read for reports.** The default file isn't one of the project's files as a resume or a
  `--reuse` sees them, so labelling a mutant refuses no `--resume` and tests nothing again. Keep a
  file you name with `--triage` outside the project, or it counts as a changed file.
- **The file** is YAML you can edit, though `triage` writes it in order and doesn't keep comments;
  keep your reasons in `note`. An entry needs only `mutant`, a whole key as the reports give it, and
  `label`. Without `before`, `after` and `line`, it applies at its key alone, whatever is there now,
  and can't follow its code; a change that spans lines has no `line`, and neither has a mutant whose
  file changed since the run you labelled it from, so those stay at their place too.

  ```yaml
  mutants:
  - mutant: Sources/Lint/Rules.swift:42:17 RelationalBoundary
    label: equivalent
    note: count never exceeds limit here
    before: '>='
    after: '>'
    line: if count >= limit {
  ```

### summary.json

Once its baseline has passed, a run writes `summary.json` beside its results file when it finishes
or stops, replacing an earlier session's, so a script can read the outcome without parsing a
report. It is written without `-o` too. A resumed run's file stays in the first session's log
folder, and so does its summary. A run whose results file couldn't be made, or written in full,
writes it in its own log folder, without `run`. One killed, or stopped at once by a second Ctrl-C,
may not get to write it. A run whose baseline fails, or that is stopped before its baseline has
passed, writes none, so a resumed run leaves the earlier session's summary as it was: its exit
status and its log say why it stopped.

```json
{
  "durationSeconds" : 1712.4,
  "ended" : "finished",
  "formatVersion" : 2,
  "mutants" : 1103,
  "mutantsByOutcome" : { "buildErrors" : 0, "killed" : 1024, "notCovered" : 0, "survived" : 75, "timedOut" : 4 },
  "mutationScore" : 92,
  "report" : "report.html",
  "run" : { "resultsFiles" : [ "…/results.jsonl" ], "sessions" : 1, "workers" : 4, … }
}
```

| Key | Meaning |
|---|---|
| `ended` | `finished`, `interrupted` or `aborted`, as the results file's end line says. Left out when the last session has no end line, for `report` of a run still going or killed. For merged shards, see [`report --summary`](Docs/results-file.md). |
| `endDetail` | Why it stopped early: the signal's name or the abort's code. Left out otherwise. |
| `mutationScore` | The headline score. Left out when no mutant was tested. |
| `mutationScoreWithoutSuspectTests` and `scoreWithoutSuspectsIsALowerBound` | When there are suspect tests: the score without them, and whether it is a lower bound. |
| `mutants` | How many mutants have a result |
| `mutantsByOutcome` | As the JSON report's |
| `durationSeconds` | How long mutation testing took, over every session |
| `codeCoverage` | The project's coverage, percent. Left out when it wasn't gathered. |
| `mutant` | For a run of one mutant (`--mutant`), its key. |
| `shards` | When it covers only some shards of a `--shard` split, so its score isn't the whole run's: `indices`, `count` and `mutantsInAllShards`, as the JSON report's. |
| `report` | The report `-o` saved, or a stopped run's partial report. Left out when none was saved. |
| `run` | As the JSON report's. Left out when the results file couldn't be made, or written in full. |
| `gate` | With a `--fail-under` or `failUnder`, the verdict on the score: `failUnder`, the threshold checked; `score`, the exact score compared, which is `mutationScore`'s but with any mutant taken out of the build with others counted as not killed; `passed`; or, when it wasn't checked, `notChecked`, one of `oneMutant`, `shard`, `endedEarly`, `stoppedOnAnError` and `lacksResults`, without `score` and `passed`. A run whose every mutant was a build error has `passed` false and no `score`. Left out without a threshold. See [Failing on a low score](#failing-on-a-low-score). |
| `formatVersion` | 2, since `mutantsByOutcome.survived` no longer holds [mutants no test reached](#whether-a-mutants-code-ran), which are in `notCovered`. It goes up only when a key is taken out or changes its meaning. |

`swift-mutator report --summary <path>` writes one from a results file, or from shards' files
merged. It never replaces the results file or the report.

## Leaving code out

A comment that starts with a `muter:` directive leaves code out of a run:

```swift
// muter:disable-declaration
func render() {          // render and all it holds are left out
    draw()
}

func update() {
    // muter:disable-next-line
    cache.removeAll()    // this line is left out
    recompute()          // this one is mutated
}

// muter:disable
func a() { … }           // left out, as is everything up to the muter:enable
// muter:enable
```

- `muter:disable-declaration` leaves out the declaration it is above, past any doc comment, attribute
  (a `#if` of attributes too) or modifier between them: a function, initializer, type, extension,
  property, subscript, accessor, enum case or `#if`. Above anything else, it leaves out the statement,
  `switch` case, element or argument that starts there. Beside code, it leaves out the declaration
  that starts the line, a multi-line string's first line included.
- `muter:disable-next-line` leaves out the mutants on the line after the comment's own, beside code
  or not: those whose code starts there, and those reported there, as a ternary's swap is at its end.
  A blank line after it leaves out nothing.
- `muter:disable` leaves out what follows, until a `muter:enable` or the end of the file. Beside code,
  a `disable` also covers the statement, case, element or argument it ends, and an `enable` starts
  after the code it's beside. Of several together, the last one decides.

A directive is the comment's first word, so `// muter:disable because it's generated` counts, and
`// see muter:disable` or `// muter:disabled` doesn't. Any kind of comment works: `//`, `///`,
`/* */` and `/** */`. Code a directive leaves out has no mutants, and isn't counted among those
dropped. A file is left out by [`exclude`](Docs/Muter-README.md#configuration-options).

## Configuration

SwiftMutator reads Muter's `muter.conf.yml`, so existing Muter configurations work unchanged,
except an xcodebuild project's `coverageThreshold`. Muter read that one as a fraction from 0 to 1,
so any value of 1 or more left out every file. It's a percentage from 0 to 100 now, as it always
was for SwiftPM: `0.5` means 0.5%, so write `50` for half. `excludeCalls` is the other: Muter
looked for each name anywhere in a statement's text, comments included, so `log` also kept
`catalog.update()`. A name now matches the name a call is called by: `log` matches `log(…)`,
`self.log(…)`, `super.log(…)` and `Logger.log(…)`, but not `logger.log(…)`, which takes
`logger.log`. A statement is kept if any call in it matches, one in a closure it passes too, or if
it passes a function that matches, as `events.forEach(log)` does. An older `muter.conf.json` beside it is
converted to `muter.conf.yml` and removed, unless a `muter.conf.yml` is there, which wins and leaves
the JSON file alone. The options are documented in
[Muter's README](Docs/Muter-README.md#configuration-options); SwiftMutator adds:

| Key | Meaning |
|---|---|
| `mutationTestWorkers` | How many mutants to test at once (SwiftPM projects, and xcodebuild projects that test on a simulator, which get one simulator per worker; default for SwiftPM: half the processors, at most 4, and, when each needs a clone, fewer for fewer than 150 mutants, see [Workers and release mode](#workers-and-release-mode); for others: 1) |
| `workersShareBuild` | Whether a SwiftPM run's workers may test from one build when a direct run of the tests, with no mutant on, wrote nothing in the copy (default: `true`; `false` gives each worker a clone, see [Workers and release mode](#workers-and-release-mode)) |
| `mutationTestTimeout` | Seconds before a mutant's test run is stopped (default: based on a timed test run; see above) |
| `oneWorkerSimulator` | Whether one xcodebuild worker tests on a simulator SwiftMutator makes (absent: when the project and its baseline show it is faster; true: whenever the destination is a simulator; false: never; see [One worker on a simulator of its own](#one-worker-on-a-simulator-of-its-own)) |
| `stopAtFirstFailure` | Stop a mutant's test run at its first failed test, or at a test process's crash, either of which already decides that it is killed (SwiftPM projects only; never the baseline; default true) |
| `suspectTestFilePercent` | The share of the files with a killed mutant naming a test, from 1 to 100, that a test must have failed for mutants in to be suspect (default 15; see [Killing tests and suspect tests](#killing-tests-and-suspect-tests)) |
| `suspectTestMinimumFiles` | How many files with such a kill there must be, at least 1, before a test can be suspect, and how many of them it must have failed for mutants in (default 10) |
| `controlRunEvery` | How many mutants to test for each control run, a run with no mutant on among theirs, whose failed tests are flaky (a whole number; 0 for none; default 100; see [Control runs](#control-runs)) |
| `suspectKillReruns` | How many kills a run tests again alone because only suspect tests failed for them (a whole number; 0 for none; default 100; see [Kills tested again alone](#kills-tested-again-alone)) |
| `keepAllLogs` | Keep the log of every mutant's test run, a kill's too (default false: a mutant killed by a failed test its results line names keeps none; see [Results file](#results-file)) |
| `keepLogFolders` | How many runs' log folders to keep in `<project>_muter_logs`, this run's included: a whole number, at least 2, so the run before this one is always kept. Earlier runs' folders beyond it are removed once nothing can refuse the run, before its build (default: unset, which removes none; see [Results file](#results-file)) |
| `failUnder` | A percent from 0 to 100, up to 6 decimals: a finished run whose headline score is below it exits with 2, once its reports are written (default: unset, which checks none; see [Failing on a low score](#failing-on-a-low-score)) |
| `propertyTests` | A list of globs that pick out property tests, by name or by the file their issue was recorded in, so the reports split the kills between example tests and property tests (default: unset, which splits none; see [Example tests and property tests](#example-tests-and-property-tests)) |
| `propertyTestFilter` | A list of test filters that select the property tests alone, as `swift test --filter` or xcodebuild's `-only-testing:` takes them: once every mutant is tested, each kill whose recorded tests include no property test is tested again with only those tests (default: unset, which tests none again; needs `propertyTests`) |
| `operators` | A list of the operators to use, at least one (default: all of them). See [Choosing the operators](#choosing-the-operators) |
| `skipOperators` | A list of the operators to leave out (default: none). See [Choosing the operators](#choosing-the-operators) |
| `buildTimeout` | Seconds, above 0 and at most a day, before each step ahead of the first mutant that builds your project and runs its tests is stopped: the coverage run, each xcodebuild build for testing, each baseline run, and a worker clone's. The direct and timed test runs, which follow the baseline and don't build, get a shorter limit (default: no limit; see [Time limits before the first mutant](#time-limits-before-the-first-mutant)) |

`--workers N` and `--timeout S`, on `run` and `run-without-mutating`, set `mutationTestWorkers`
and `mutationTestTimeout` for one run, in place of the file's
([#73](https://github.com/Joseph-Cursio/SwiftMutator/issues/73)), as `--fail-under P` sets
`failUnder`, and `--build-timeout S`, on those and `mutate-without-running`, sets `buildTimeout`.
`--workers` must be at least 1, and `--timeout` and `--build-timeout` above 0 and at most a day,
86,400 seconds. The run records and compares them as it does the keys: a resume with a `--timeout` at
least as long as every session's limit tests only the timeouts again (see
[Timeouts are run again](#timeouts-are-run-again)), one that is shorter is refused, and another
`--workers` or `--fail-under` is only said. A run that tests several mutants at
once says so, and one that uses fewer workers than asked says why:

```
👷 Testing 4 mutants at a time, each in a copy of the project of its own, by default: `--workers` or `mutationTestWorkers` sets another count.
👷 Testing 4 mutants at a time, from one build, as your tests wrote nothing in the project.
👷 Testing 3 mutants at a time, though 4 workers were asked for: only 3 are left to test.
👷 Testing one mutant at a time, though 4 workers were asked for: a Mac app's test runs share its UserDefaults, saved state and container, so workers would see each other's.
```

### Choosing the files

Discovery mutates the Swift files the project builds, less those the excludes leave out, and, with
coverage, those the tests never ran. The default excludes leave out build folders, dependencies,
package manifests, tests, test doubles and helpers (`/Mocks/`, `/Stubs/`, `/Fakes/`,
`/TestHelpers/`, `/TestSupport/`, `Mock.swift`, `Spec.swift`) and SwiftPM's `/Snippets/`; the
[full list](Docs/Muter-README.md#configuration-options) is in Muter's README. An `exclude` entry
that starts with `!` keeps what the rest of it matches, a default's files included, but not the
project's own `Package.swift` or a file in `.build`, `.swiftpm` or `muter_tmp`. In YAML such an
entry must be quoted, as an unquoted `!` starts a tag, and SwiftMutator refuses the empty entry
that would leave:

```yaml
exclude:
  - /Generated/          # leave out generated code
  - "!/Stubs/"           # but mutate the Stubs module, which the defaults leave out
```

With coverage, a file in a `Tests` folder or whose name ends in `Tests.swift` is taken for a test
file, whose code the coverage doesn't count, so only `--skip-coverage` mutates it, `!` or not.

For one run:

- `--exclude <pattern>`, repeatable, adds an entry to `exclude`, as `--exclude /Generated/` or
  `--exclude '!/Stubs/'` (quoted, as a shell may read `!`). A resume compares the entries, as it does
  the key's.
- `--files-to-mutate <path>` mutates only the files it names, by their path in the project, or an
  absolute one in it: a file, a folder, which names every Swift file in it but hidden ones, or a
  glob, as `exclude` takes one, such as `Sources/**/*.swift`, whose matches may be folders too.
  Entries are comma-separated or given again, and a file named twice is mutated once. The excludes
  and the coverage filter still apply, so a file at or below `coverageThreshold`, which by default
  is one whose code no test ran, isn't mutated: `--skip-coverage` turns that off. Each entry that
  leaves no file says why:

```text
⚠️ --files-to-mutate Sources/Missing.swift names no Swift file.
⚠️ --files-to-mutate Tests names only files the excludes leave out; an exclude entry that starts with ! keeps them.
```

### Choosing the operators

Every operator runs by default. `swift-mutator operator all` explains them. To use fewer, name them
in `muter.conf.yml`, or on the command line for one run:

```yaml
# Only these operators.
operators: [RelationalOperatorReplacement, ChangeLogicalConnector]
# Or every operator but these. With both keys, these are left out of `operators`.
skipOperators: [RemoveSideEffects]
```

- **`--operators`** wins over both keys, so it can use an operator that `skipOperators` leaves out.
- **`--skip-operators`** is taken in place of `skipOperators`, and leaves operators out of
  `--operators`, or else of `operators`, or else of them all.
- **A name that isn't an operator is refused,** in either key or option, before the run starts, as
  is a choice that leaves no operator, and an empty `operators`.
- **A resume or a reuse compares the operators chosen,** not how they were chosen: a change of these
  keys that chooses the same operators is no difference.
- **A test plan's run and `--mutant`** don't narrow to the keys. A plan holds its own operators, and
  `--mutant` looks for its mutant among them all, even one the keys leave out. If that misses it, it
  tries the keys' operators, as a mutant nested in a `some` body can be kept only with fewer operators.
  A mutant that only a run with `--operators` kept this way can't be named.

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

A timeout that a failed test or a crash in its log doesn't explain still counts as a survivor,
unlike Stryker, which counts it as killed. No test was shown to catch the mutant, and as above, a
timeout is often a mutant that was only slow. One whose log shows a failed test is killed, and one
that shows a crash counts as a crash
([#89](https://github.com/Joseph-Cursio/SwiftMutator/issues/89)).

The rerun's result is the one the report gives. The results file keeps both: the rerun's line, with
`rerun`, follows the first run's. Each keeps a log of its own by the rule for mutants' logs (see
[Results file](#results-file)), the rerun's with ` (rerun)` before `.log`, and its line names it only
then: a rerun killed by a failed test its line names keeps none, unless `keepAllLogs: true` is set
(see [Docs/results-file.md](Docs/results-file.md)). A run on one worker, as an xcodebuild
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

- **`mutationTestWorkers`.** 2 workers took 39 min, 3 took 30, 4 took 27, 6 took 24 and 8 took 24.
  Each worker past the first adds a clone and its build, and every test run slows as the load rises,
  so the gain falls off fast; two runs with 4 workers differed by 13%. On that machine 4 was a safe
  choice, and 6 or 8 helped a little; a machine with fewer cores will do best with fewer. More workers
  also make false kills from tests that share state outside the project more likely (see
  [Tests that share state across workers](#tests-that-share-state-across-workers)): with 8 workers,
  before direct runs kept each worker's `UserDefaults` apart, tests that write them killed 9 mutants
  that most runs didn't.

  **The default.** A SwiftPM project with no `mutationTestWorkers` or `--workers` tests on half the
  machine's processors, at most 4, and, as a clone costs about one build, on one more worker for each
  50 mutants: 1 below 50, 2 from 50, 3 from 100 and 4 from 150. Each clone adds about one build folder
  of disk while the run lasts. Workers that [share one build](#workers-and-release-mode) need no clone,
  so that rule doesn't hold them back: only the machine and the number of mutants do. Other build systems default to 1, as an xcodebuild
  worker needs a simulator of its own, about 3 GB at its peak. The default was set from the one project
  measured here, on one 18-core machine; `mutationTestWorkers: 1` gives what it was before.

  A clone whose baseline fails, or that can't be copied, as with a suite that can't run beside a copy
  of itself or a disk that fills up, makes a default run test one mutant at a time, and say so, rather
  than stop:

  ```
  👷 Testing one mutant at a time instead: worker 1's copy of the project didn't pass the baseline the first one passed (its log is baseline run worker 1.log), so your tests may not run beside a copy of themselves, or the builds ran out of disk space or memory. `mutationTestWorkers: 1` skips trying.
  ```

  With a count you asked for, the same failure stops the run, with status 3.

  **One build.** Clones are for tests that write in the project, so a run whose tests don't needs none.
  On macOS, the run that checks [direct runs](#why-a-fork-of-muter) also compares the copy's files
  before and after it, every file and folder's size and time, `.build` included, so a fixture a test
  writes and removes shows too. If nothing changed, the workers test from the copy's build, with no
  clone made or built, and each keeps its own temporary directory, `UserDefaults` and active-mutant
  file. If anything changed, each gets a clone, and the run says what changed:

  ```
  ℹ️ Workers can't share one build: a run of your tests, with no mutant on, changed Tests/MyTests in the copy.
  ```

  On 150 mutants sampled from SwiftProjectLint, with 4 workers and two runs of each
  ([Docs/release-and-workers-2026-10.md](Docs/release-and-workers-2026-10.md#workers-sharing-one-build)):

  | | Whole run | To the first result | CPU time |
  | --- | --- | --- | --- |
  | A clone for each worker | 534 s, 540 s | 203 s, 195 s | 83 min, 89 min |
  | One build | 392 s, 402 s | 75 s, 73 s | 57 min, 59 min |

  That is about 2 min less for the three clones' copies and builds, and about 1.9 GB of disk less for
  each, going by the copy's build folder. Mutants tested no faster, and all four runs gave all 150
  the same verdict. The saving is the same whatever the run's length, so it is 26% of this run, and,
  as a whole run of those 1,771 mutants takes an hour or two, which wasn't timed, about 2–3% of that.
  The check adds about 0.6 s, for those 27,741 files and folders.

  With no clones to pay back, a small run uses every worker. On 40 mutants of the same project, two runs
  of each, all 40 got the same verdict in all six runs:

  | | Whole run | Testing the mutants, after the first result | CPU time |
  | --- | --- | --- | --- |
  | One worker | 214 s, 217 s | 144 s, 146 s | 15 min, 15 min |
  | 4 workers, a clone for each | 275 s, 266 s | 80 s, 72 s | 42 min, 42 min |
  | 4 workers, one build | 150 s, 144 s | 77 s, 72 s | 16 min, 16 min |

  A small run whose tests do write in the copy stays on one worker, as a clone wouldn't pay back there,
  and prints the line above.

  The check runs with no mutant on, so it can't see a test that writes in the project only when a
  mutant sends it there. Another worker can then read what it wrote. `workersShareBuild: false` gives
  each worker a clone whatever the check finds.
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

#### Tests that share state across workers

Workers test at the same time, as the same user. Each has its own copy of the project, or shares
one that [its tests didn't write in](#workers-and-release-mode), and its own temporary directory, but
nothing else outside the project. So a test that writes a fixed key, file or
port can fail another worker's test, which kills a mutant that test doesn't check. That's a false
kill, and it raises the score.

Each SwiftPM worker's temporary directory is `sm-<hash>` in the usual one, named the same for each of
its runs, as SwiftPM's manifest cache needs. `TMPDIR` names it for every run. On macOS Foundation's
`NSTemporaryDirectory()` and `FileManager.temporaryDirectory` don't follow `TMPDIR`, so each worker's
runs also set `DIRHELPER_USER_DIR_SUFFIX`, which moves them there, and moves the system's cache
directory the same way. macOS doesn't document that variable, so a later macOS could drop it, and
Foundation's temporary directory would then be shared again; a test here checks it. What the runs
leave there goes at the end of the run. macOS keeps an empty `sm-<hash>` folder, one for each worker's
folder, which the next run of that project uses again.

What workers share:

- A suite you open with a fixed `UserDefaults(suiteName:)`, the keychain, fixed temporary paths and
  ports.
- `UserDefaults.standard`, and `@AppStorage` without a `store:`, when mutants' tests run through
  `swift test`, as they always do on Linux. On macOS, [direct runs](#why-a-fork-of-muter) keep these
  apart, but one XCTest test in a package means no direct runs. A run with more than one worker
  prints a line when this applies, whether or not your tests use `UserDefaults`.

This is about SwiftPM workers. Each [xcodebuild worker](#xcodebuild-workers) tests on a simulator of
its own, with its own `UserDefaults` and keychain.

Here is what that does, on a small package with 12 mutants, whose tests check none of its code, so
every kill is false. Each test writes a value of its own to a fixed key, and checks it's still there:

| The test's store | Workers | False kills |
| --- | --- | --- |
| `UserDefaults.standard`, in direct runs | 2 | 0 |
| `UserDefaults.standard`, in `swift test` runs | 2 | 12 |
| `UserDefaults(suiteName:)`, a fixed name | 2 | 12 |
| `UserDefaults(suiteName:)`, a fixed name | 1 | 0 |
| `UserDefaults(suiteName:)`, a new UUID in each test | 2 | 0 |

**The fix belongs in your tests.** Inject the store, so a test can pass one of its own, and give
`@AppStorage` a `store:`. A stand-in that keeps its values in memory leaves nothing behind. A test
that needs a real `UserDefaults` can open a suite named with a UUID:

```swift
let name = "MyTests.\(UUID().uuidString)"
let store = try #require(UserDefaults(suiteName: name))
defer { store.removePersistentDomain(forName: name) }
```

A fixed suite name won't do, as every worker opens the same suite. `removePersistentDomain` empties
the suite, but leaves an empty file in `~/Library/Preferences` for each run of the test: 16 from
that run of 12 mutants. Removing the file in the test doesn't always work, as 5 of about 16 came
back, so remove them once the run is over:

```bash
rm ~/Library/Preferences/MyTests.*.plist
```

Until the tests are fixed, `mutationTestWorkers: 1` avoids false kills like these, at the cost of
speed.

**Control runs can find these tests.** A control run runs beside the other workers, with no mutant
on, so a test that fails in one is marked flaky, and the reports count a kill only such tests were
recorded failing for as one without them. There's one for each 100 mutants by default, so none in
a run below 100 (see [Control runs](#control-runs)). With `controlRunEvery: 4` on the fixed suite's
run above, all 3 control runs failed and named the test, and each kill read `(suspect only)`.

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
  mutant's time limit, only `buildTimeout`'s if it is set, so no mutant's limit pays for a
  simulator's first install and launch, which took 30 to 93 s. Its log is kept as `no-mutant run worker <n>.log`. It shows that the tests pass one at a
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
  `<project>_mutated.noindex`, so a second one started while the first runs is refused.
- **It combines** with `--since`, `--changed-lines`, `--files-to-mutate`, `--operators` and
  `--skip-operators`, which
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
  - **When it fails.** Whenever the report is known to lack results: a shard stopped on an error,
    has fewer results than mutants, as when its job was cancelled or killed, or holds mutants but
    its file isn't given, as for a shard whose baseline failed, which writes no file. It then exits
    with the status of the first shard, by its index, that stopped on an error, as that shard's run
    did, 4 or 255, and otherwise with 4, and doesn't check `--fail-under`. So a CI job that checks
    the merged report fails as one that checked every shard would. Earlier SwiftMutators exited
    with 255 here.
  - **`--fail-under`** checks the merged score, the whole run's (see
    [Failing on a low score](#failing-on-a-low-score)). A shard's own run doesn't check it.
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
    `report`, with `--fail-under 80` to fail on a low score: the shard jobs don't check it. If none
    was written, as when every shard was empty, skip it: `report` given no file is a usage error,
    with status 64.
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
- **It combines** with `--since`, `--changed-lines`, `--files-to-mutate`, `--operators` and
  `--skip-operators`, which
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
project or a worker clone, where your tests would see it. Once SwiftMutator has read it back and
recorded the run, it moves that file to the name the log folder keeps the log under, such as
`baseline run.log`, so each log is written once. A run that finished but wasn't recorded, because a
stop or an abort came first, leaves its output in `running/`. A process your tests started that
outlives the test command and still writes to its output adds those lines to the kept log.

The log folder keeps the logs you would open: those of the mutants that survived, crashed, timed
out or didn't build, and of a kill whose results line names no failed test. A mutant killed by a
failed test its line names keeps no log, as the line's `killedBy` and `firstFailedTestLine` say what
the log would, and its line has no `log`. Every other log is kept: the baselines', the timed and
control runs', the coverage run's, and those of runs the simulator failed to launch or found gone.
`keepAllLogs: true` in `muter.conf.yml` keeps every mutant's log, as before, and so does
`--mutant`, whose log the end of the run names. Which logs are kept changes no result, so a resume
lets `keepAllLogs` change. A results file whose lines may have no `log` is in results format 4,
which an older SwiftMutator refuses as a newer format rather than lose those mutants' results (see
[Compatibility](Docs/results-file.md#compatibility)).
A run that keeps nothing there, such as a refused `--resume` or a `--since` run with no Swift file
changed, leaves no folder of its own in `<project>_muter_logs`. A resumed session's folder holds no
results file, but `resumed session.txt`, a note naming the file it adds to.

Log folders pile up: SwiftMutator removes none unless you set `keepLogFolders` in
`muter.conf.yml`. With `keepLogFolders: 5`, a run keeps the folders of the newest 5 runs, itself
included, and removes older ones once nothing can refuse it or find nothing to test: after its
configuration, `--since`, `--resume` or `--reuse` checks, the project's lock, a test plan's checks
of its code and copy, and the discovery of the files and mutants to test, and before the build. A
run that ends before then removes nothing. It says what it removed and what it left:

```
🧹 Removed the log folders of 3 earlier runs, 1.9 GB, from /Users/me/code/SwiftProjectLint_muter_logs, keeping the newest 5 runs (keepLogFolders: 5):
  Oct 9, 2026 at 9:00 AM
  Oct 9, 2026 at 9:00 AM (2)
  Oct 10, 2026 at 8:00 AM
⚠️ Left Oct 1, 2026 at 8:12 AM: another SwiftMutator run is using it.
⚠️ Left Sep 30, 2026 at 4:02 PM: it holds files SwiftMutator didn't write: notes.txt
```

When it removes none but leaves some, a first line says where they are instead:
`🧹 Left the log folders of 2 earlier runs in /Users/me/code/SwiftProjectLint_muter_logs, beyond the newest 5 runs (keepLogFolders: 5):`.

- **What counts as a run.** A run's folders are those of each of its sessions: a resumed session's
  folder goes with the first session's, whose results file its note names. Only a run with a
  results file counts toward the 5. Folders without one, such as a run whose baseline failed or a
  `mutate-without-running` run, and `--mutant` runs, are kept while they are newer than the oldest
  earlier run kept, and removed once older, however few runs there are; with no earlier run, none
  is removed. Runs are dated by when their folders were made and their results files last written,
  never by their names, so opening an old run's folder in Finder, or deleting a log from it, doesn't
  make it newer.
- **What is never removed.** This run's folders, a resumed run's earlier sessions included, and
  those of the run `--reuse` reads, which are kept besides the 5. A `--mutant` run removes nothing.
- **What is left alone.** A folder a run still uses: every run holds a lock on a hidden file,
  `.swiftmutator-run`, in its folder until it exits, and on its results file while it writes it. A
  folder an older SwiftMutator made, which has no such file, counts as in use for a day after its
  `running/` was last written to. A run that `--reuse` reads is left while the reusing run goes,
  which holds a shared lock on the same files until it ends. A folder holding a file SwiftMutator
  didn't write, one whose locks can't be checked, as on a volume without `flock`, and any folder
  SwiftMutator didn't make, are left too, and so is a resumed session's folder whose first session's
  folder SwiftMutator didn't make.
- **Shards.** Each `--shard` is a run of its own. To merge shards run one after another on one
  machine, set `keepLogFolders` above the number of shards: the message names a removed shard,
  `(shard 2 of 4)`.
- **A removed run is gone.** Its results file and logs go with it, so it can no longer be reported,
  resumed or reused.

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
  `-f json > report.json` gives valid JSON. `--summary <path>` also saves the run's
  [summary.json](#summaryjson) there.
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
- **It exits as the run did** once the report is made of a run that stopped on an error: with 4 for
  an abort, such as 5 build errors in a row, and 255 for any other error, so a script that checks
  the report fails as one that checked the run would. A run whose baseline failed has no results
  file to report, or, resumed, keeps the earlier session's end, so `report` never exits with 3.
- **It exits with status 2** when `--fail-under` is given and the score is below it, every mutant
  was a build error, or a run that didn't finish has no results, once the report
  is made (see [Failing on a low score](#failing-on-a-low-score)). A run's error status wins, and
  then the score isn't checked.

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
A test that is timing-sensitive or flaky does that, and so can a broad test of the mutated code. With fewer than 10 such files the report gives no
verdict, and says so. `suspectTestFilePercent` and `suspectTestMinimumFiles` change the 15% and
the 10. They change no result already recorded, only what the reports say and which kills a later
session [tests again alone](#kills-tested-again-alone), so a resume lets them change. The results
file records them, and `swift-mutator report` uses those of the run's last session.

A kill that no longer fails when tested again alone counts as a survivor, in the headline score and
for `--fail-under`. Any other kill by suspect tests still counts: `--fail-under` checks the headline
score. Every report also gives the score without the suspect tests, which counts each kill that
only suspect tests were recorded failing for as a survivor:

```
Of the 1103 mutants introduced into your code, your test suite killed 1024.
By outcome: 1024 killed, 75 survived, 4 timed out
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
- **What to do.** A test marked `yes` is a suspicion, not a verdict: a broad end-to-end or
  golden-output test can fail for mutants in that many files, and be right to. One marked `flaky`
  fails whatever the mutant: it failed in a control run, or didn't fail again often enough alone. If a
  suspect test also fails without a mutant, leave it out of mutation runs. SwiftMutator sets the
  environment variable `IS_MUTER_RUNNING` to `YES` for the baseline and every mutant's test run, so
  a test can skip itself there:

  ```swift
  @Test(.disabled(if: ProcessInfo.processInfo.environment["IS_MUTER_RUNNING"] == "YES", "Flaky under load"))
  func analyzesTheProjectInTime() async throws { … }
  ```

  In XCTest, start the test with
  `try XCTSkipIf(ProcessInfo.processInfo.environment["IS_MUTER_RUNNING"] == "YES")`.
- **Limits.**
  - The rule alone can't tell a broad test from a flaky one. In SwiftProjectLint's runs, no test of
    the mutated code reached more than 8.8% of the files, and tests that failed under load reached
    23–97%. But on 6 November 2026, good tests reached 37% of SwiftCloneDetector's 30 files and 42%
    of SwiftEffectInference's 19, which only the 10-file floor kept most of from being suspect. So
    the rule chooses which kills to [test again alone](#kills-tested-again-alone), and that settles
    it. A test with too few kills to judge stays as the rule has it.
  - The rule misses a test that fails in fewer than about 3% of runs, or about 5% when runs stop
    at their first failed test. Such a test is worth about 1 point of score at most: on
    SwiftProjectLint, 0.16. A control run catches one only if it fails there: 25 control runs
    give a test that fails in 3% of runs about an even chance.

#### Kills tested again alone

Once every mutant is tested, each kill only suspect tests failed for is tested again, one at a time
with no other mutant running and with no stop at its first failed test. A kill a test really makes
fails again. One a flaky test made mostly doesn't. On SwiftCloneDetector on 6 November 2026, all 7
kills the rule blamed on a good test failed again, in all 21 runs. With a test added that fails 5% of
the time, 7 of its 11 kills survived, and the test failed again in only 1.

- **The verdict.** The rerun replaces the first run in the results file and every report. A kill
  that no longer fails is a survivor, or not covered if its code didn't run, so the headline score and
  `--fail-under` can go down. One that fails again or crashes stays killed, and now names every test
  that failed. A rerun that times out or fails to build says nothing of the mutant, so the kill stands.
- **The test.** A test the log shows failing failed. One it doesn't show passed, if the run exited by
  itself with no crash and named what failed. A run a crash cut short says nothing of a test it doesn't
  name, and neither does a failure by another test of the same name.
  - It is *flaky*, however few files it reached, when it passed alone, or failed with the mutant's
    code not running, more than once for every 4 times it failed again.
  - It is *cleared*, and no longer suspect, when it failed again at least 3 times and never didn't.
    A test that fails 30% of the time whatever the mutant does that only 2.7% of the time.
  - Otherwise the rule decides. Nothing clears a test that failed in a control run.
- **How many.** At most `suspectKillReruns`, 100 by default, in a whole run, however many sessions it
  takes. Each suspect test gets 3 first, from other kills that name it if it has too few of its own,
  so that it can be judged and no test uses up the limit. The rest of the limit goes to the kills only
  suspect tests failed for, spread evenly in job order. Past it, a kill counts on the first run's word,
  and the report says how many did. `suspectKillReruns: 0` tests none.
- **The cost.** Each rerun takes as long as a survivor's run, one at a time, plus one run at the start
  with no mutant on: if the tests don't pass alone, no kill is tested again, and the run says so. So
  the most it adds is `suspectKillReruns` runs of your whole test suite. On SwiftProjectLint's 6.9 s for
  a survivor, that is about 12 minutes on a run of about 8 hours. It can be much more of a small run:
  SwiftEffectInference's 100 reruns at 11 s took 19 minutes on an 18-minute run, with
  `suspectTestMinimumFiles` lowered to 5 so that the rule flagged dozens of its good tests, all of which
  they cleared. With the default 10, no test there is suspect, and it adds nothing. On SwiftCloneDetector
  it added about a second. `--mutant` runs none.
- **Measuring reach.** A test's reach counts each mutant's first run, so a rerun's longer list or a flip
  can't change which tests are suspect.
- **Resuming.** A resumed run tests the kills an earlier session didn't, up to what is left of the
  limit, but only if it has a mutant left to test: with none, it has no baseline to start from, as
  property reruns don't either. So a run stopped during these reruns, with no other mutant left, keeps
  the kills it hasn't tested.
- **Reuse and shards.** `--reuse` tests no reused kill again, and doesn't count what a test did alone
  on code that may have changed, as it doesn't count a reused run's control runs. A flip stays. Each
  shard chooses by what it alone reaches, so a merged report's flips can differ from a whole run's.
- **Limits.**
  - A rerun alone can't tell a mutant that makes a test fail only under load from a flaky test: both
    pass alone, so such a kill becomes a survivor.
  - Only a kill the rule picks is tested. A test that fails 5% of the time reached 9 to 13 of
    SwiftCloneDetector's 30 files, so the 10-file floor let one of 3 runs through, and its kills
    stood. Lowering `suspectTestMinimumFiles` catches more, at the cost above.

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

### Example tests and property tests

With `propertyTests` set, or `--property-tests` given, the plain text, HTML and JSON reports split
the kills between example tests and property tests, in an Examples and Properties section
([#105](https://github.com/Joseph-Cursio/SwiftMutator/issues/105)). A property's value is the
mutants only it kills: two scores, one for each kind, would overlap and hide them.

```yaml
propertyTests:
  - "*Properties*"
  - SortSpec.swift
```

- **Which tests are properties.** A glob matches a test when it matches the whole of its name, as
  the Killed By column gives it, or the whole of the file its issue was recorded in. `*` stands for
  any characters, and `?` for one; anything else matches itself, case included. So `*Properties*`
  matches Swift Testing's `ordered()` recorded in `SortProperties.swift`, and XCTest's
  `-[AppTests.ParseProperties testRoundTrip]`, whose lines name no file. Every other test is an
  example.
- **What it says.** The kills only examples made, only properties made, and both made, each as a
  share of the mutants the headline score is of, every one but a build error, so the parts add up
  to the killed count. A kill that names no test, as a crash's may not, counts as neither. Then the
  10 properties that failed for the most killed mutants, and how many of them each was the only
  test recorded failing for. With made-up counts:

  ```
  Of the 1103 mutants scored, examples alone were recorded killing 812 (73%), properties alone 61 (5%), and both 151 (13%).
  ```
- **Fail-fast hides kills.** A run stopped at its first failed test, the default, records that
  test alone. An example that fails first hides a property that would also have failed, so "only
  by examples" may be "by both". The section says how many kills that may be: the count by both is
  then a lower bound, and the counts by one kind alone may be high. `stopAtFirstFailure: false`
  records every failed test, up to 20, at the cost of a longer run, and so does
  `propertyTestFilter`, at the cost of one more run for each kill of examples alone.
- **Testing a kill again with the properties alone.** With `propertyTestFilter`, once every
  mutant is tested, each kill whose recorded tests include no property test is tested again with
  only the tests the filter selects, on as many workers. Its entries are what your test command
  takes: `swift test` gets `--filter <entry>` for each, which matches test identifiers such as
  `SortingTests.SortProperties/ordered()`, and xcodebuild gets `-only-testing:<entry>`, such as
  `SortingTests/SortProperties`. So the property tests must be selectable by name, for example in
  suites of their own. A property that fails makes the kill one by both; every property passing
  makes it one by examples alone, whatever the first run stopped at. A crash that names no test
  isn't tested again.

  ```yaml
  propertyTests: ["*Properties*"]
  propertyTestFilter: [SortProperties]
  ```

  ```
  🧪 Running the property tests again for 4 kills only examples were recorded making, one at a time.
  🧪 Ran the property tests again for 4 kills: a property test failed too for 3, and every one passed for 1.
  ```

  First the filtered tests run once with no mutant on. If they ran no test, as a filter that
  matches none doesn't, or didn't pass, no kill is tested again, and the run says why. A
  `propertyRerun` line in the results file records each run (see
  [the results file](Docs/results-file.md#propertyrerun)). `propertyTestFilter` needs
  `propertyTests`, and a SwiftPM or xcodebuild project; `--mutant` runs none. On a small sorting
  package whose three properties wait 0.4 s before their checks, fail-fast stopped three kills at
  an example, and the reruns found a property failing for each, which matched a run that stopped
  at none.
- **It changes no result.** It only reads what the runs recorded, so a resume lets it change, and
  `swift-mutator report --property-tests '<glob>'` splits an earlier run's kills, in place of the
  globs its header records. The JSON report's `propertyKillSummary` holds the section (see
  [the example](Docs/test_report_json_example.md#propertykillsummary)).

## Keeping the Mac awake

A whole-project run can take hours. On macOS, `run`, `run-without-mutating` and
`mutate-without-running`, resumed runs included, keep the Mac from going to sleep while it is idle,
on battery too, so `caffeinate` isn't needed. `pmset -g assertions` lists this as a
`PreventUserIdleSystemSleep` assertion named "SwiftMutator is running mutation tests". It ends with
the run, however the run ends, and for as long as Ctrl-Z has
[suspended](#stopping-a-run) the run, as nothing is running then.

The display can still sleep. Closing the lid still sleeps the Mac, and the run then makes no
progress until the Mac wakes. Linux is left as it is.

## Stopping a run

Press Ctrl-C once to stop a run and keep what it tested. SIGTERM, which `kill` sends, and SIGHUP,
which a closed terminal sends, stop it the same way. SwiftMutator then:

1. Stops the test runs under way and kills every process it started, so no test runner is left
   running. A test run that the stop ended is never recorded, so it can't count as a killed mutant.
   What it had written stays in `running/` in the log folder, as does the output of a run that had
   finished but wasn't recorded yet.
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
5. Removes its worker clones, `<project>_mutated_worker<n>.noindex`, the active-mutant files and
   activation markers beside the mutated project and the clones, what SwiftPM workers' runs left in
   their temporary directories, and an xcodebuild run's derived data,
   `<project>_mutated.DerivedData.noindex` and `<project>_mutated_worker<n>.DerivedData.noindex`,
   with its workers' `muter-worker<n>.xctestrun` files. The mutated project,
   `<project>_mutated.noindex`, is kept, as after a finished run. Last, it deletes the simulators an xcodebuild run made for its workers, named
   `swiftmutator-<project hash>-<pid>-<start>-w<n>`, which takes a few seconds when they are
   booted. A finished run deletes them the same way.
6. Exits by the same signal, so the shell sees status 130 for SIGINT, 143 for SIGTERM or 129 for
   SIGHUP, and a script or loop that runs SwiftMutator stops too.

A stop before the baseline has passed, or while the worker clones build or the timed test run runs
after it, has nothing to keep: the results file starts only after them all.

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
  simulators can be left behind, as can a test process whose parent had already ended, which runs
  until its tests end. A SIGHUP after a first SIGHUP is ignored, because zsh sends two
  when its terminal closes: closing a terminal stops a run the same way as one Ctrl-C.
- **Suspending.** Ctrl-Z suspends SwiftMutator with every process it started, which the terminal's
  Ctrl-Z doesn't reach: each leads a process group of its own. `fg` or `bg` continues them all. No
  time limit counts the time suspended, and no test run's duration includes it, though a test that
  measures time itself can still see it pass. Under xcodebuild, a simulator runs the tests in a
  process of its own, which SwiftMutator didn't start, and doesn't suspend. A run that is
  stopping isn't suspended: it is about to end.
- **Leftovers.** The next `run` removes `<project>_mutated.noindex` and any worker clones,
  active-mutant files and `.DerivedData.noindex` and `.Activation.noindex` folders an earlier run left behind, such as one
  stopped at once, killed with SIGKILL, or crashed. It also removes what a SwiftMutator from before
  the `.noindex` names left under the names it gave them, `<project>_mutated` with any fix in it,
  `<project>_mutated_worker<n>`, the `.DerivedData` folders and the files beside them, so the first
  run after an upgrade leaves none of them. It holds the lock that SwiftMutator took, so it never
  touches a run of it still under way, and `run --mutant` removes only what runs of one mutant left.
  An older SwiftMutator doesn't know the `.noindex` names, so going back to one leaves them to
  remove by hand. The next xcodebuild run, before its baseline, deletes the worker
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
  writes the same summary and partial report, then shows the error and exits with status 4. A
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
  - build errors, including test runs that couldn't start, and
    [mutants that don't compile](#mutants-that-dont-compile);
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
| A configuration key changed (`exclude` by `--exclude` too, compared as a set), other than `mutationTestWorkers`, `workersShareBuild`, `stopAtFirstFailure`, `buildTimeout`, `oneWorkerSimulator`, `suspectTestFilePercent`, `suspectTestMinimumFiles`, `controlRunEvery`, `suspectKillReruns`, `keepAllLogs`, `keepLogFolders`, `failUnder`, `propertyTests` and `propertyTestFilter`; `operators` and `skipOperators` are compared by the operators they choose, in the next rows | Refused: start a new run |
| `mutationTestTimeout` (or `--timeout`) is at least as long as every session's `timeoutSeconds` | Goes ahead, says so, and tests the timeouts under a shorter limit again |
| The operators chosen, by `--operators`, `--skip-operators`, `operators` or `skipOperators`, `--files-to-mutate` or `--skip-coverage` changed | Refused: start a new run |
| `--since`'s merge base or `--changed-lines` changed, or `--since` given in one session only | Refused: start a new run. `--reuse` doesn't compare them |
| `--shard` changed, or given in one session only | Refused: start a new run. `--reuse` doesn't compare it |
| `mutationTestWorkers`, `workersShareBuild`, `stopAtFirstFailure`, `buildTimeout`, `oneWorkerSimulator`, `suspectTestFilePercent`, `suspectTestMinimumFiles`, `controlRunEvery`, `suspectKillReruns`, `keepAllLogs`, `keepLogFolders`, `failUnder`, `propertyTests` or `propertyTestFilter` changed | Goes ahead, and says so: `ℹ️ mutationTestWorkers was 4 and is 2 now, which no result depends on.` |
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
  Only the logs this run would keep are copied: by default a kill by a test its line names keeps
  none, and its new line has no `log`, even if the earlier run kept one. So the new file stands alone: `swift-mutator report` of it gives the run's own report, and says
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
[CONTRIBUTING.md](CONTRIBUTING.md) covers the toolchain you need, the acceptance and regression
tests, which CI doesn't run, and pull requests. [Docs/Architecture.md](Docs/Architecture.md) says
how the code is laid out: the steps of a run, how a mutant is switched on, and the results file.

## License

MIT, as Muter is. See [LICENSE](LICENSE).
