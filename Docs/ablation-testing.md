# Ablation testing

**Planned, not built.** SwiftMutator can't run ablations yet. [prd-ablation-testing.md](prd-ablation-testing.md) proposes how it would, and [#340](https://github.com/Joseph-Cursio/SwiftMutator/issues/340) tracks the work.

Ablation testing takes a fix with several parts, removes one part at a time, and runs the tests against each version. If removing a part makes a test fail, that part is both needed and tested. If removing it changes nothing, either the part isn't needed or no test checks it, and the run alone can't tell you which.

- **What to do now:** in every bug-fix PR, say that the new tests fail without the fix: the revert check. For a fix with several parts, add an ablation table: part removed → tests that fail. Run full mutation testing now and then as an audit, not on every PR.
- **How it relates to mutation testing:** it's a coarse, hand-picked version of it. Mutation testing makes many small changes automatically to measure the tests. Ablation removes a few meaningful parts that a person picked, to check one change.
- **Run each version more than once.** A concurrency test can pass by luck of timing. A part only counts as tested when its tests fail on every repeat.
- **Cut the parts along what the fix adds, not along lines.** When a fix moves behaviour the old code already had, taking out a part can also take out the old behaviour, and leave the code worse than before the fix. Compare each version with the original code as well as with the fix.

## Ablation and mutation testing

*Ablation* comes from neuroscience and machine learning. You remove one meaningful part, such as a brain region or a layer of a model, and see what stops working. That tells you whether the part was needed.

*Mutation testing* (PIT, Stryker, cargo-mutants, and, for Swift, Muter, which SwiftMutator is a fork of) makes many small changes automatically, such as `==` to `!=` or removing a call, and runs the tests against each one. A change no test notices is a gap in the tests. The result describes the tests, not the code.

Ablating the parts of a fix sits between the two:

| | Mutation testing | Ablating a fix |
|---|---|---|
| What changes | Every place an operator matches, chosen by the tool | A few parts of one change, chosen by the author |
| How many versions | Hundreds to thousands | Usually 2 to 6 |
| What one version is | A small, often meaningless change | The fix with one meaningful piece taken back out |
| The question | How good are the tests? | Is each part of this fix needed, and is it tested? |
| When to run it | Now and then, over the whole project | Once per fix, in the PR |

It's close to a habit from test-driven development: undo the fix and see the new test fail. Ablation does that once for each part, not once for the whole fix.

### One run, two questions

Removing a part answers two questions at once:

1. **Is the part needed?** If nothing in the program depends on it, removing it changes no behaviour.
2. **Is the part tested?** If a behaviour depends on it but no test checks that behaviour, removing it changes no test result.

When a test fails, both answers are yes. When nothing fails, the answer is "no" to one of them, and you can't tell which from the run. That's a prompt to look harder, not a verdict: either delete the part, or write the test that would have failed.

## When it's worth it

- **Fixes with several parts.** A single-line fix needs only the revert check. A fix that touches three places can pass its tests with one of those places doing nothing.
- **Concurrency fixes.** Tests of races, cancellation and resource release can pass by accident, because of timing. A part whose removal leaves every test green may be untested, not unneeded.
- **Defensive code.** A guard, an early return or an extra wake-up that "can't hurt" is the kind of part nothing exercises. Ablation shows whether any test reaches it.

## What it costs

- **Builds and test runs.** One build and one test run per part per repeat, plus the fix itself and the fix with every part removed. SwiftMutator's mutation schemata, which compile every variant into one build, would remove most of the build cost.
- **Flaky tests.** A test that fails 1 time in 20 can look like it detects a part. Each version needs several runs, and a test that fails on some of them but not all is flaky: it's evidence, not proof.
- **Combinations.** Removing one part at a time misses two parts that cover for each other: with either one in place, the bug stays fixed. Each looks unneeded alone. Removing every part at once, the revert check, catches the case where the parts together do nothing. Finding which pair covers for each other takes removing them in pairs, which costs much more.
- **Moved behaviour.** "The fix minus part *k*" isn't always somewhere between the original code and the fix. If part *k* moved something the original code already did, removing it removes that too, and tests that pass on the original code can fail. That isn't wrong, but it overstates what part *k* adds. The worked example below has a case. Cut parts so that each one is something the fix adds, and check every test that fails against the original code: one that passes there is a sign the part moved old behaviour.

## Worked example: a leak in `share()`

[apple/swift-async-algorithms#473](https://github.com/apple/swift-async-algorithms/issues/473) is a leak in `share()`: in some orders of release and cancellation, the shared iteration loop stays parked and keeps the base iterator alive. The fix has three parts:

1. `unregisterSide` wakes the parked iteration loop when the last iterator leaves after the sequence was released.
2. `cancel()` with no iterators left wakes the loop even when the buffer is full.
3. `iterate()` doesn't park once it has been cancelled.

There are 15 leak tests, numbered here as cases 1 to 15. Each version below ran them 3 times. Every version gave the same result on all 3 runs, and no test was flaky.

| Version | Leak tests that fail | Which |
|---|---|---|
| The fix | 0 of 15 | – |
| The source on `main`, so every part removed | 10 of 15 | Cases 1–10 |
| Part 1 removed: the old `unregisterSide` | 4 | Cases 1–4, where the sequence is released before its last iterator |
| Part 2 removed: the old no-iterators branch of `cancel()` | 1 | Case 5, the full buffer with the sequence released last |
| Part 3 removed: no "don't park when cancelled" checks in `iterate()` | 6 | Cases 6–10, and case 11, which passes on `main` |

What it shows:

- **The revert check passes.** The source on `main` fails 10 of the 15 tests, the same 10 on every run, so those tests catch the bug, not timing.
- **Each part is needed, and the parts split the bug between them.** Cases 1–4 need part 1, case 5 needs part 2, and cases 6–10 need part 3. Between them, the single removals fail all 10 tests that fail on `main`, so nothing hints at two parts covering for each other.
- **Part 2 rests on one test.** Removing it fails case 5 alone. If that test were ever deleted or weakened, nothing would notice part 2 going missing.
- **Removing part 3 leaves the code worse than `main`.** Case 11 passes on `main` but fails without part 3. `main` already checked for cancellation in `iterate()`'s limit path, and the fix moved that check into its new early check. Taking the early check out took out what `main` already did as well. So part 3's row overstates what part 3 adds: it adds cases 6–10, and case 11 is behaviour it moved. That's the [moved-behaviour pitfall](#what-it-costs) above. Cutting part 3 as "the new early check, keeping the old limit-path check" would give a row that's purely what the fix adds.

A randomised stress test, 110 runs and 330,000 rounds in all, passed with the fix and caught the bug on `main`.

<details>
<summary>The ablation table as it would go in the PR</summary>

```markdown
### Ablation

Each row is the fix with one part removed, run 3 times against the 15 leak tests.

| Part removed | Leak tests that fail (3 of 3 runs) | Flaky |
|---|---|---|
| None (the fix) | 0 | 0 |
| All (source on `main`) | 10 (cases 1–10) | 0 |
| 1: `unregisterSide` wakes the loop | 4 (cases 1–4) | 0 |
| 2: `cancel()` wakes the loop with a full buffer | 1 (case 5) | 0 |
| 3: `iterate()` doesn't park once cancelled | 6 (cases 6–10, and 11, which passes on `main`) | 0 |

Case 11 fails without part 3 because the fix moved `main`'s cancelled check in the limit path into the new early check, so removing part 3 also removes a check `main` had.
```

</details>

## What to put in a PR

- **Every bug-fix PR:** one sentence saying the new tests fail without the source change, and how you checked, for example "reverted `Sources/` to `main`, ran the new tests 3 times, all failed each time."
- **A fix with several parts:** the ablation table, one row per part, with the tests that fail and how many repeats.
- **A part whose removal fails nothing:** say so, and say which it is: you removed it, or you added the test that catches it, or you kept it on purpose, and why.
- **Mutation testing:** run `swift-mutator run` over the whole project now and then, as an audit of the tests. It's too slow and too broad to gate every PR on, while `run --since` ([Mutating only what a branch changed](../README.md#mutating-only-what-a-branch-changed)) gives a quick look at one.
