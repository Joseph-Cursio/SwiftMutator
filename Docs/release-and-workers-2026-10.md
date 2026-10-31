# Measured: release-mode tests and the worker count

On 31 October 2026, for [#70](https://github.com/Joseph-Cursio/SwiftMutator/issues/70), SwiftProjectLint's whole repo was run seven times: with 2, 3, 4, 6 and 8 workers, with 4 workers, the review's setting, a second time, and once with its tests built in release mode. This file records what each setting did to time and to verdicts. Each setting ran once, except 4 workers, and the two 4-worker runs differed by 13% in time, so read small differences with that in mind.

## Summary

- **Release mode made the run 29% shorter:** 18.9 min against 26.6 min, with 4 workers.
  - The tests ran 2.8 times as fast: 8.6 min of testing against 24.2 min, and 0.84 s per mutant against 2.36 s.
  - The builds took longer, so setup went from 2.3 min to 10.2 min. With 4 workers that pays off only above about 1,250 mutants, so not for a run on a few files. With more workers the break-even is higher.
  - Its verdicts differed from the two 4-worker runs' in 3 and 5 places, where those two differed from each other in 4. That shows nothing large changed here. It can't rule out a project-specific loss: SwiftProjectLint has no `assert` and almost no `#if DEBUG` code.
  - It isn't a drop-in setting. SwiftProjectLint's CLITests look for the `CLI` binary in `.build/debug`, so the first release run's baseline failed. With `.build/debug` linked to the release products it passed.
- **More workers shortened the run, by less each time:**

  | Workers | 2 | 3 | 4 | 6 | 8 |
  |---|---|---|---|---|---|
  | Whole run | 39.2 min | 30.1 min | 26.6 min | 24.4 min | 23.6 min |

  - Going from 2 workers to 3 or 4 clearly helped. 6 took 8% less time than 4, and 8 took 3% less than 6, but those steps are smaller than the 13% between the two 4-worker runs, so they aren't firmly measured.
  - Each worker past the first adds a clone and its build to the setup, about 25 s each here, and every mutant's run gets slower as the load rises.
  - The first 4-worker run took 30.1 min, under load from another session's builds (see Results), so 26.6 min, from the second, is the 4-worker figure.
- **The score held at 76.3–76.6% in every run,** by the report's rule, with timeouts as survivors. 21 of the 2,463 mutants had different verdicts in different runs.
  - With 8 workers, 10 mutants were killed that most runs called survivors, and tests that write `UserDefaults` killed 9 of them, against 0–2 such kills in each other run. Workers share the user's defaults ([#92](https://github.com/Joseph-Cursio/SwiftMutator/issues/92)). That is one 8-worker run, so it shows the risk rather than a rate.
  - 4 of the 21 depend on the order SwiftProjectLint's own tests walk a dictionary in, which changes from run to run whatever the setting, as the review's "Outside this repo" section notes.
  - Every other run was within 1–4 verdicts of the majority.
- **4 workers were faster than on 21 October.** That day's 4-worker run, of the same commit on the same machine, took 37.5 min for 2,464 mutants under Xcode 27.1 ([smt-trial-2026-10.md](smt-trial-2026-10.md)); this one took 26.6 min for 2,463 under Xcode 27.2. Most of the 10.9 min fits PR #167, which runs mutants' test bundles without `swift test` and whose own measurement predicted about 11 min. PR #169 and PR #170 measured no clear gain on their own, and about 40 other PRs merged in between. With one run on each date, the comparison is indicative only. The review's 1 h 31 min of 6 October was on an 8-core machine, so it isn't comparable.

## Setup

| | |
|---|---|
| Machine | Apple M5 Pro, 6 performance and 12 efficiency cores, 64 GB, macOS 27.2, Xcode 27.2 (Swift 6.4.2). Not the 8-core machine of the review's 6 October run. |
| SwiftMutator | A release build (`swift build -c release`) of PR #170's branch, whose Swift sources are those of `main` at `9af0b47c`. |
| Project | A clone of SwiftProjectLint at `c2082e5d`, in a scratch folder. That commit has no `Package.resolved`, so its packages were resolved once in the clone, and every run used the same versions. |
| Configuration | `executable: /usr/bin/swift`, `arguments: [test]`, and `mutationTestWorkers` as each run says. The release run's `arguments` were `[test, -c, release, -Xswiftc, -enable-testing]`. |
| Excludes | `**/BuiltInRules.swift` and `**/PatternCategory.swift`, two of the 21 October trial's four. Discovery now leaves out that trial's other two, `.claude/` and `.swiftinfer/`, by itself (#86). `ParallelListDriftDogfoodTests` parses the two files from disk through `#filePath`, and fails the baseline once they hold mutant switches. That leaves out the 15 mutants in `BuiltInRules.swift`. |
| Command | `swift-mutator run --skip-coverage --skip-update-check`, from the clone. With coverage on, the coverage run is built with the same `arguments`, so in release mode it would add another release build. That wasn't measured. |
| Runs | One after another, in this order: 4 workers, release, 2, 3, 6, 8, 4 again, then release again with the link. Each started only once the 1-minute load average was under 4, after waits of up to 38 min. Every run built from a cold `.build`, which held only the resolved packages. |
| Load | Each minute, the 1-minute load average, and the CPU used by processes whose arguments don't name the clone. From the second run on, the five busiest of those were logged too, half a minute off the load samples. |

## Results

| Run | Workers | Whole run | Setup | Testing | Per mutant | Survivor | Kill | Killed | Survived | Timed out | Score | Time limit |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2 workers | 2 | 39.2 min | 1.5 min | 37.7 min | 1.83 s | 5.22 s | 0.67 s | 1,879 | 575 | 9 | 76.3% | 29 s |
| 3 workers | 3 | 30.1 min | 2.0 min | 28.1 min | 2.05 s | 5.90 s | 0.74 s | 1,882 | 572 | 9 | 76.4% | 33 s |
| 4 workers | 4 | 26.6 min | 2.3 min | 24.2 min | 2.36 s | 6.85 s | 0.81 s | 1,879 | 575 | 9 | 76.3% | 37 s |
| 4 workers, under load | 4 | 30.1 min | 2.5 min | 27.5 min | 2.68 s | 7.93 s | 0.90 s | 1,879 | 575 | 9 | 76.3% | 38 s |
| 6 workers | 6 | 24.4 min | 3.3 min | 21.1 min | 3.08 s | 9.24 s | 1.00 s | 1,881 | 573 | 9 | 76.4% | 45 s |
| 8 workers | 8 | 23.6 min | 4.2 min | 19.4 min | 3.77 s | 11.62 s | 1.17 s | 1,887 | 567 | 9 | 76.6% | 54 s |
| Release | 4 | 18.9 min | 10.2 min | 8.6 min | 0.84 s | 1.79 s | 0.46 s | 1,880 | 574 | 9 | 76.3% | 20 s |

- **Setup** runs from the start of the run to the first mutant's test run: the copy, discovery, the baseline (38–40 s, and 267 s in release), the worker clones' builds and the timed test run.
- **Testing** runs from the first mutant's test run to the end of the last.
- **Per mutant** is the mean of the mutants' test runs, from launch to verdict. **Survivor** and **Kill** are the same means for survived and killed mutants. A survivor runs every test, and a kill stops at its first failed test.
- **Score** is the report's: kills, failed or runtime error, over every mutant tested, with timeouts as survivors. The report itself rounds it down, to 76% for every run.
- **The time limit** is the default, from one timed test run: 5 times it, once more for each worker past the first, and at least 20 s. The same 9 mutants timed out in every run.
- **Load:** the 1-minute load averaged 16 with 2 workers, 23 with 3, 28 with 4, 43 with 6 and 55 with 8, and 12 in release.
- **The 4-worker run under load** was the first run. For 5 of its 31 one-minute samples, processes that didn't name the clone used more than three cores, up to 13.6. Another session ran Swift builds on this machine during it, and just before and after it. Its survivors took 7.93 s against 6.85 s in the second 4-worker run.
  - That measure can overstate outside load. In the later runs, two of the peaks that the process log caught were the run's own test processes as they exited, when `ps` no longer shows their arguments, and Spotlight indexing the clones. The 6-worker run had 5 such minutes, up to 8.1 cores; the log caught 2 of them, and what caused the other 3 is unknown.

## Release mode

- **Where the time went.** The tests ran 2.8 times as fast. In the timed test runs, CoreTests' 3,623 tests ran in 0.77 s against 3.8–4.1 s in debug. Building took several times as long, as release builds compile each module as a whole: the baseline took 267 s against 38 s, each worker clone's build about 110 s against about 28 s, and the first mutant ran 10.2 min into the run against 2.3 min.
- **When it pays off.** It added 7.9 min of setup and took 1.52 s off each mutant's test run, which is 0.38 s of wall time per mutant with 4 workers. So it breaks even at about 1,250 mutants, half of this repo. Each extra worker adds another release build of its clone, so with 6 or 8 workers the break-even would rise to roughly 1,900 or 2,600 mutants, estimated from these setup times, not measured. It suits large runs at modest worker counts, not runs on a few changed files.
- **Verdicts.** Release mode differed from the two 4-worker runs in 3 and 5 verdicts, where they differed from each other in 4. It killed `ContextSymbolTable.swift:96` and `:98`, which neither 4-worker run did, but those two depend on dictionary order in the project's tests, so that says nothing about release mode. Against the majority of all seven runs it was off by 1, against 2–4 for the other runs, and 12 for the 8-worker run. One run can't show that release mode leaves verdicts alone in general:
  - An `assert` or `assertionFailure` isn't evaluated under `-O`, so a mutant only one of them catches survives. `precondition` is still checked; only `-Ounchecked` drops it.
  - Code and tests under `#if DEBUG` drop out.
  - SwiftProjectLint has no `assert` in its sources, and its only `#if DEBUG` code is a `print`, so neither showed here. Kills by a crash were as many in release as in the debug runs: 39 against 37–41.
- **The time limit fell to its 20 s minimum,** as the timed run took 1.4 s. The same 9 mutants timed out.
- **Tests that find build products by path.** SwiftProjectLint's CLITests start the `CLI` binary. They look for it beside the test bundle in `Bundle.allBundles`, then in `<package>/.build/debug`, which a release build doesn't make. The first release run's baseline failed with 14 such tests, which stopped the run before any mutant. The rerun linked `.build/debug` to `out/Products/Release` in the clone, and that run is the one in the table.

## Worker count

- **Each added worker** added about 25 s of setup, for its clone and build, and made each mutant's run slower: from 1.83 s with 2 workers to 3.77 s with 8.
- **Testing time** fell by 25% from 2 workers to 3, by 14% from 3 to 4, by 13% from 4 to 6 and by 8% from 6 to 8. With 8 workers the extra setup ate about half of that, so the whole run was only 3% shorter than with 6.
- **The runs went in ascending order of workers through the afternoon,** with the second 4-worker run last, so any drift over the afternoon is mixed in with the worker count.
- **False kills.** With 8 workers, 9 of the 10 mutants killed against the majority were killed by tests that write `UserDefaults`: "enabledRuleNames loads saved rules from UserDefaults on init", "saveEnabledRules persists to UserDefaults and loads back", "An @AppStorage write IS observable, so it must not be gated either" and "updateDirtyState is clean when state matches loaded config". Each of these is a synchronous test on the main actor, so it can't race with another test in its own process; another worker's process has to change the value. The other runs had 0–2 such kills each.
- **Missed kills don't follow the worker count.** Most are of the four mutants that depend on dictionary order in SwiftProjectLint's tests: `PrimitiveNamedForDomainTypeVisitor.swift:77` and `:105`, killed in about 75% and 50% of runs, and `ContextSymbolTable.swift:96` and `:98`.
- **On this machine,** 4 workers is a safe choice, and 6 or 8 may help a little. Past 6, the false kills from shared state matter more than the time saved. Nothing here relates the best count to the number of performance cores. A machine with fewer cores will likely do best with fewer workers.

## Verdicts

Each mutant's majority verdict across the seven runs, with failed and runtime error both counted as killed, is the reference here.

| Run | Off the majority | Extra kills | By `UserDefaults` tests | Missed kills |
|---|---|---|---|---|
| 2 workers | 2 | 1 | 0 | 1 |
| 3 workers | 3 | 3 | 2 | 0 |
| 4 workers | 2 | 1 | 0 | 1 |
| 4 workers, under load | 4 | 2 | 2 | 2 |
| 6 workers | 4 | 3 | 1 | 1 |
| 8 workers | 12 | 10 | 9 | 2 |
| Release | 1 | 1 | 0 | 0 |

- Two mutants were off the majority in three runs: `ContextSymbolTable.swift:96`, a relational operator that 3 runs killed and 4 didn't, and `ContextSymbolTable.swift:98`, a removed call that 3 runs didn't kill. `OnceContractViolationTests` walks a dictionary, so they are killed only when its declarations come in one order. `PrimitiveNamedForDomainTypeVisitor.swift:77` and `:105` are flaky the same way.
- `DemeterChainFilter.swift:207` and `LocalTypeCollector.swift:25` were killed only in the 4-worker run under load, by "enabledRuleNames loads saved rules from UserDefaults on init" and "saveEnabledRules persists to UserDefaults and loads back". Every other run, release included, called them survivors.
