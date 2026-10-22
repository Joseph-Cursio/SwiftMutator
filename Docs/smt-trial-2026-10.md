# Trial: swift-mutation-testing against SwiftMutator

On 21 October 2026 both tools were run on two of the user's packages, SwiftProjectLint and SwiftIdempotency, with the same operators and worker count. This file records what they found. It's evidence for deciding whether to switch, not the decision.

## Summary

- **Verdicts agree.** Of the 2,361 SwiftProjectLint mutants both tools made, they gave the same verdict for 2,289 (97%).
  - 64 more are SwiftMutator survivors that swift-mutation-testing (SMT) calls "no coverage", because no test ran the mutated code.
  - 8 are killed by one tool and not the other. Each was rerun on its own: 6 were false kills (4 SwiftMutator's, 2 SMT's), and 2 were real kills that only some test orders reveal.
  - On the shared mutants, both tools score 77.6% by Stryker's rule.
- **SwiftMutator was 6.6 times as fast on SwiftProjectLint:** 37.5 min against 4 h 6 min. SMT also tested 40% more mutants, but per mutant it still took 4.7 times as long.
  - SMT tested 2,540 mutants from its shared build in 28 min.
  - It then spent 3 h 36 min building and testing 918 more, one at a time, on one worker. Those were the mutants it left out of its shared build after compile errors, plus the ones that can't go into it.
  - On SwiftIdempotency, which is small, SMT was faster: 56 s against 96 s.
- **SwiftIdempotency stops each tool, for different reasons.**
  - SwiftMutator aborts on the `@inlinable` helpers (#108), as predicted.
  - SMT refuses to start, because one test runs `git`, which doesn't work in SMT's sandbox. With that test's suite disabled, SMT tests the `@inlinable` mutants and kills both.
- **#86 hits both tools.** Each mutates files that no build target compiles: SwiftProjectLint's `ExampleCode/` and SwiftIdempotency's `examples/`.
  - SwiftMutator calls those mutants survivors.
  - SMT calls them "no coverage", which lowers its score the same way.
- **#187 is being answered with documentation.** PR #190 says "Closes #187". It keeps the default of CPUs − 1 workers sharing one sandbox, and tells users to give test files unique paths or to run with `--concurrency 1`.

## Setup

| | |
|---|---|
| Machine | 18 cores, 64 GB, macOS 27.2, Xcode 27.1 (Swift 6.4). The review's machine had 8 cores, so its 1 h 31 min isn't comparable with these times. |
| SwiftMutator | `0abda3bd` (PR #61's head), built with `swift build -c release`. |
| SMT | `f99440e`, main after PR #189 (the fix for #188). No release includes it yet, so it reports `0.0.0-dev`. Built with `swift build -c release`. |
| Projects | Clones in a scratch folder, never the user's checkouts. SwiftProjectLint at `c2082e5d`, the review's workload; SwiftIdempotency at `5863dad`. Neither tool changed a clone. |
| Operators | The four SwiftMutator has: relational, logical, swap ternary and remove side effects. SMT's default tier runs logical, negate conditional and swap ternary, so SMT was given `--operator` four times. |
| Workers | 4 in both. |
| Other options | SwiftMutator: `--skip-coverage`, as `swift-quality` runs it. SMT: `--no-cache` and `--build-timeout 900`. |
| Excludes | Both tools: `/.claude/`, `/.swiftinfer/`, `/BuiltInRules.swift` and `/PatternCategory.swift`. |

The last two excludes are needed because `ParallelListDriftDogfoodTests` parses those two files from disk through `#filePath`. In SwiftMutator's copy they hold mutant switches, so the baseline failed there on the first attempt. Excluding them in both tools keeps the comparison like for like.

Commands, from the clone's folder:

```bash
swift-mutator run --skip-coverage --skip-update-check -c sm-spl.conf.yml --format json -o sm-spl-w4.json
```

with `mutationTestWorkers: 4`, `executable: /usr/bin/swift`, `arguments: [test]` and the excludes in `sm-spl.conf.yml`.

```bash
swift-mutation-testing . --operator RelationalOperatorReplacement --operator LogicalOperatorReplacement --operator SwapTernary --operator RemoveSideEffects --concurrency 4 --no-cache --build-timeout 900 --exclude /.claude/ --exclude /.swiftinfer/ --exclude /BuiltInRules.swift --exclude /PatternCategory.swift --output smt-spl-c4.json --keep-logs smt-spl-c4-logs
```

## SwiftProjectLint

| | SwiftMutator | SMT |
|---|---|---|
| Wall time | **37.5 min** (2,250 s) | **4 h 6 min** (14,766 s) |
| Mutants | 2,464 in 301 files | 3,458 |
| Killed | 1,883 | 2,489 (45 of them by a crash) |
| Survived | 572 | 805 |
| Timed out | 9 | 11 |
| No coverage | not measured (`--skip-coverage`) | 150 |
| Unviable | 0 | 3 |
| Score, by its own rule | 76.4% (timeouts count as survivors) | 72.4% (timeouts detected, no coverage undetected) |
| Wall time per mutant | 0.91 s | 4.27 s |

SwiftProjectLint's suite has 3,933 tests in three bundles. A warm `swift test` takes 9 s on this machine.

SwiftMutator's first mutant started 2.5 min into the run. That setup covers the copy, discovery, a 38 s baseline and the three extra worker clones. The mutants then took 35 min.

### Where SMT's time went

1. **Build: 77 s,** after six retries.
   - Each time the shared build failed, SMT took mutants out of it to test one at a time: 638 in all.
   - When it can't tie a compile error to one mutant, it takes out every mutant in that file (`SchemaNarrower.excludeProblematicMutants`). In 20 files, every mutant went (251 mutants).
   - Another 280 mutants couldn't go into the shared build at all ("incompatible").
2. **The shared build's mutants: 2,540,** whose results came in from 15:39 to 16:07, about 28 min.
   - 2,526 ran on 4 workers, until 16:03.
   - The other 14 were reruns on one worker: 8 timeouts, and 6 kills where the mutated code never ran.
3. **One at a time: 918 mutants** (638 + 280), from 16:07 to 19:43. That's 3 h 36 min, or 14.1 s a mutant.
   - This pass runs on a quarter of the workers, which is 1 here. That worker builds one sandbox (about 47 s), then writes each mutant into it in turn, rebuilds incrementally, runs the tests and restores the file.
   - 695 of the 918 (76%) are remove-side-effects mutants.
   - 390 are mutants SwiftMutator also makes, 208 of them remove side effects. So the slow pass isn't only SMT's extra mutants.

SwiftMutator's shared build had no such failures: it recorded no build errors.

A run with SMT's default of 17 workers wasn't measured. It would shorten the parallel pass. It would make the one-at-a-time pass run on 4 workers instead of 1.

### Verdicts, mutant by mutant

How the mutants were matched:
- Relational and logical mutants sit on the operator token in both tools, so they were matched on line, column and replacement.
- SwiftMutator places swap-ternary and remove-side-effects mutants at the end of the node, and SMT at its start. Those were matched on the node's last line, and on SMT's text ending SwiftMutator's once whitespace is removed. SwiftMutator's text can start with comments or `try`.

2,361 mutants matched.

| SwiftMutator \ SMT | killed | survived | timed out | no coverage |
|---|---|---|---|---|
| killed | 1,822 | 4 | 0 | 1 |
| survived | 3 | 461 | 0 | 64 |
| timed out | 0 | 0 | 6 | 0 |

- **2,289 agree (97.0%).** Over all 2,361 matched mutants, the Stryker-rule score is 77.6% for both: 77.64% for SwiftMutator against 77.55% for SMT.
- **64 SwiftMutator survivors are "no coverage" in SMT.** SMT recorded that the mutated code never ran (`activated: false`).
  - SwiftMutator ran with `--skip-coverage`, so it had no coverage step.
  - With coverage on, its file and region filter might have skipped some of these mutants. That wasn't measured.
  - What SwiftMutator has no equivalent for is SMT's check of each mutant (#109).
- **8 are killed by one tool and not the other.** Each was rerun alone with `swift-mutation-testing reproduce <fingerprint>`. That runs one mutant through the whole suite, all three bundles, with no stop at the first failure. All 8 survived, or came out "no coverage", with every test passing.
  - Passing once doesn't prove a kill was false, though.
  - For 2 of them, reading the code shows the mutant does change behaviour, and only some test orders reveal it.

| Mutant | Killed by | Test that failed | Finding |
|---|---|---|---|
| `ActorReentrancyVisitor.swift:319` `\|\|`→`&&` | SwiftMutator | `everyFormatRendersTheSameBytesForAnyArrivalOrder` | False kill: `HTMLFormatter` prints the time to the minute (review, Outside this repo) |
| `GlobalActorMismatchVisitor.swift:174` `==`→`!=` | SwiftMutator | the same | False kill, for the same reason |
| `RuleDocView+SyntaxHighlighting.swift:24` `==`→`!=` | SwiftMutator | "An @AppStorage write IS observable…" | False kill: shared `UserDefaults` (#92) |
| `SelfAccessAnalyzer.swift:443`, a removed `names.insert(…)` | SwiftMutator (SMT: no coverage) | "saveEnabledRules persists to UserDefaults and loads back" | False kill: shared `UserDefaults` (#92) |
| `ProtocolCouldBePrivateVisitor.swift:155` `==`→`!=` | SMT | "updateDirtyState is clean when state matches loaded config" | False kill: shared `UserDefaults` |
| `NetworkingVisitor.swift:107` `==`→`!=` | SMT | "saveEnabledRules persists to UserDefaults and loads back" | False kill: shared `UserDefaults` |
| `ContextSymbolTable.swift:96` `==`→`!=` | SwiftMutator | `collisionWithdrawnCallee_doesNotFire` | Real kill. The test walks a dictionary in hash order, and only one order shows the mutant (review, Outside this repo). |
| `PatternRegistryFactory.swift:66`, a removed `IdempotencyRules.registerAll()` | SMT | `baseline_strictReplayableUnannotatedCallee_fires_withoutSuppression` | Real kill. Registration is process-wide, so the mutant only shows when this test runs before any other test has registered the rules. |

Both tools' workers share the user's `UserDefaults`. It gave each tool two false kills. So #92 isn't specific to SwiftMutator, and PR #190's text doesn't mention it.

The minute-stamp and hash-order tests hit only SwiftMutator here, but SMT runs the same tests.

None of the 8 came from SMT's shared sandbox (#187). Only these 8 were rerun, though. A #187 false kill whose mutated code ran gets no warning in SMT's report, so the 1,822 agreed kills and SMT's 664 kills of mutants only it makes weren't checked.

### Mutants only one tool makes

- **Only SMT: 1,097.**
  - **219 relational boundary mutants,** such as `>` → `>=`. 131 of them survive (60%). SwiftMutator's #102 proposes the same mutants.
    - The other 4 relational ones are two `==`/`!=` flips SwiftMutator didn't make, and two unviable mutants of non-expressions: a generic constraint and an operator declaration.
  - **872 remove-side-effects mutants,** of which 577 are killed, 208 survive, 82 are "no coverage" and 5 time out.
    - What decides which calls only SMT removes is where they sit. SwiftMutator mutates only the top level of function, `for`, `guard`, `while`, `repeat` and `do` bodies. It skips `if`/`else` bodies, closures, and functions that also hold a loop, `guard` or `do` (#112). SMT also removes calls in all of those, and expressions in SwiftUI view builders such as `Text("Tab 2").tag(1)`.
    - The 577 kills are test strength SwiftMutator doesn't measure, although the view-builder mutants are mostly noise.
- **Only SwiftMutator: 103,** all remove side effects (56 killed, 44 survived, 3 timed out). Each comes from a rule of SMT's:
  - about 70 are the only statement of their body, such as `typeStack.removeLast()` (`RemoveSideEffectsVisitor.isSoleStatementOfBody`);
  - about 21 to 25 are inside `while` or `repeat` bodies, which SMT leaves alone so that a mutant can't loop forever;
  - 6 are `_ = …` discards.
- **No coverage in SMT: 150.** All have `activated: false`.
  - 68 are in `Packages/`, 52 in `ExampleCode/` and 30 in `Sources/`.
  - 65 are matched mutants: the 64 survivors and one kill above. The other 85 are SMT-only.
  - The 52 in `ExampleCode/` are #86: no target builds those files. SwiftMutator made one mutant there, and called it a survivor.

## SwiftIdempotency

- **SwiftMutator on `assertIdempotent.swift` alone** found 4 mutants: the two `==` and two removals of `precondition`.
  - The build failed with "enum '__SwiftMutator' is fileprivate and cannot be referenced from an '@inlinable' function". The run aborted after 21 s, with no results.
  - This confirms #108 on the real package.
- **SMT, as is,** stopped before testing anything: "The test suite fails before any mutation is applied".
  - The failing test is `DocCitationTests`' "every recovery pointer names a commit the path can actually be read at". It runs `git show` from a repository root it works out from `#filePath`.
  - SMT's sandbox mirrors the project, `.git` included, as folders of symlinks, and `git show` fails there. SMT's message warns about tests that derive paths from `#filePath`.
  - SMT has no documented way to skip a test on a package. Its `--target` passes a name that matches no bundle through as a positive filter (`TestTargetSelection.swift:8-9`), which isn't a skip.
  - SwiftMutator copies the whole project, `.git` included. Its first whole-package run, made before the suite was disabled, passed its baseline with that test in it.
- **With that one suite disabled in the clone** (a `.disabled(…)` trait, one line), both tools were rerun on the same clone:

| | SwiftMutator (helpers file excluded) | SMT |
|---|---|---|
| Wall time | 96 s | **56 s** |
| Mutants | 28 | 35 |
| Killed | 21, all in `Sources/` | 26, all in `Sources/` |
| Not killed | 7 survivors, all in `examples/` | 8 no coverage, all in `examples/` |
| Unviable | 0 | 1, in `Sources/` (`IdempotentEffectRecorder.swift:171`) |
| Score | 75.0% | 76.5% |

- **SMT on `assertIdempotent.swift`** made 2 mutants, the two `==`. Both were killed, by a crash, since `precondition` fails. It took 26 s.
  - SMT makes no mutant that removes a `precondition`, because it has a deny list.
  - SwiftMutator removes them (#112).
- **The matched mutants agree.** 27 matched. All 21 kills agree, and SwiftMutator's 6 matched survivors are SMT's "no coverage" mutants in `examples/`.
- **`examples/` is #86 again.** It holds sample packages that the root package doesn't build.
  - Leaving `examples/` aside, both tools killed every viable mutant they tested in `Sources/`.
  - SwiftMutator only got that far with the helpers file excluded, so its 4 mutants there weren't tested.

## Toolchain

SMT builds with `/usr/bin/swift` (`Build/ToolRequests.swift:8`). It runs tests with the default Xcode toolchain's `swiftpm-testing-helper` (`Execution/TestBundleInvocation.swift:141`). So `swift-quality`'s `SWIFT` override, such as a swiftly toolchain, wouldn't reach it. Both packages build and pass with Xcode 27.1's Swift 6.4, so this didn't matter here.

## Upstream, as of 21 October

- **#188** was fixed the day it was filed (PR #189).
- **#187** has no reply on the issue itself. PR #190, open and titled "Document that an SPM run's workers share one sandbox, and the false kills it can cause", says "Closes #187" and is documentation only.
  - The package default stays at CPUs − 1 workers.
  - Its remedies are unique paths for test files, or `--concurrency 1`.
  - It adds that the cache keeps such false kills, and that `--no-cache` doesn't clear them.
- **Write-through isn't addressed.** The comparison of 21 October found that a test that rewrites a fixture in place changes the original project through SMT's symlinked sandbox. PR #190 doesn't cover that.

## What this says about switching

- **Correctness doesn't separate them on SwiftProjectLint.** They agree on 97% of shared mutants, and score the same on them.
  - Each took two false kills from shared `UserDefaults`. Fixing those tests in SwiftProjectLint pays off under either tool.
  - SwiftMutator took two more from the minute-stamp test. SMT runs that test too.
- **SMT knows which mutants no test reaches.** It marked 64 of SwiftMutator's survivors here "no coverage", and it checks each mutant's code ran. SwiftMutator was run without coverage, and has no per-mutant check.
- **Speed favours SwiftMutator on SwiftProjectLint:** 6.6 times overall, 4.7 times per mutant.
  - SMT's cost is the 918 mutants that didn't go into its shared build. It builds those one at a time, on a quarter of its workers.
  - Most of them are in ordinary rule code, not SwiftUI: 73% are in files that don't import SwiftUI.
  - On a small package whose shared build worked, SMT was faster.
- **Each tool fails to run on SwiftIdempotency as is.**
  - SwiftMutator's failure is a known bug with a proposed fix (#108).
  - SMT's comes from its sandbox: a test that needs a working `.git`, or a file outside the project, fails its baseline, and there's no documented way to skip one test on a package.
- **SMT's broader operators find more,** for example 577 extra remove-side-effects kills and 219 boundary mutants. That also makes its runs longer and its survivor lists noisier.
- **#187 will stay a constraint.** Packages whose tests write files at fixed paths would need `--concurrency 1` under SMT. This trial found no shared-sandbox false kill among the 8 mutants it reran. It didn't look anywhere else.

Not covered by this trial:
- SwiftInferProperties, SwiftAssist and the user's other packages;
- SMT at its default of 17 workers, and with its default operator tier;
- coverage-filtered SwiftMutator runs;
- reruns of agreed kills and of SMT-only kills.
