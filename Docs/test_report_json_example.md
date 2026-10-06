# Example Test Report

```
Here's your test report:

--------------------------
Applied Mutation Operators
--------------------------

These are all of the ways that Muter introduced changes into your code.

In total, Muter introduced 54 mutants in 14 files.

File                                           Applied Mutation Operator       Mutation Test Result
----                                           -------------------------       --------------------
ContextualAlternates.swift:63                  RemoveSideEffects               mutant survived
ContextualAlternates.swift:75                  SwapTernary                     mutant killed (test failure)
ContextualAlternates.swift:78                  SwapTernary                     mutant survived
ContextualAlternates.swift:81                  SwapTernary                     mutant survived
FontFeatures.swift:34                          RelationalOperatorReplacement   mutant killed (test failure)
FontFeatures.swift:40                          RelationalOperatorReplacement   mutant killed (test failure)
FontFeatures.swift:47                          RemoveSideEffects               mutant killed (test failure)
NSAttributedString+BonMot.swift:72             ChangeLogicalConnector          mutant survived
StylisticAlternates.swift:204                  RemoveSideEffects               mutant survived
StylisticAlternates.swift:217                  SwapTernary                     mutant survived
StylisticAlternates.swift:220                  SwapTernary                     mutant killed (test failure)
StylisticAlternates.swift:223                  SwapTernary                     mutant survived
StylisticAlternates.swift:226                  SwapTernary                     mutant survived
StylisticAlternates.swift:229                  SwapTernary                     mutant killed (test failure)
StylisticAlternates.swift:232                  SwapTernary                     mutant killed (test failure)
StylisticAlternates.swift:235                  SwapTernary                     mutant survived
StylisticAlternates.swift:238                  SwapTernary                     mutant survived
StylisticAlternates.swift:241                  SwapTernary                     mutant survived
StylisticAlternates.swift:244                  SwapTernary                     mutant survived
StylisticAlternates.swift:247                  SwapTernary                     mutant survived
StylisticAlternates.swift:250                  SwapTernary                     mutant survived
StylisticAlternates.swift:253                  SwapTernary                     mutant survived
StylisticAlternates.swift:256                  SwapTernary                     mutant survived
StylisticAlternates.swift:259                  SwapTernary                     mutant survived
StylisticAlternates.swift:262                  SwapTernary                     mutant survived
StylisticAlternates.swift:265                  SwapTernary                     mutant survived
StylisticAlternates.swift:268                  SwapTernary                     mutant survived
StylisticAlternates.swift:271                  SwapTernary                     mutant survived
StylisticAlternates.swift:274                  SwapTernary                     mutant survived
Tracking.swift:23                              RelationalOperatorReplacement   mutant survived
AdaptableTextContainer.swift:84                RelationalOperatorReplacement   mutant survived
AdaptableTextContainer.swift:94                RemoveSideEffects               mutant survived
AdaptiveStyle.swift:131                        RelationalOperatorReplacement   mutant survived
AdaptiveStyle.swift:131                        SwapTernary                     mutant survived
AdaptiveStyle.swift:133                        RelationalOperatorReplacement   mutant survived
AdaptiveStyle.swift:133                        SwapTernary                     mutant survived
EmbeddedTransformation.swift:50                RelationalOperatorReplacement   mutant survived
NSAttributedString+Adaptive.swift:39           RemoveSideEffects               mutant survived
NSAttributedString+Adaptive.swift:54           RemoveSideEffects               mutant survived
NSAttributedString+Adaptive.swift:55           RemoveSideEffects               mutant survived
StyleableUIElement.swift:200                   RemoveSideEffects               mutant survived
StyleableUIElement.swift:81                    RelationalOperatorReplacement   mutant survived
TextAlignmentConstraint.swift:135              RemoveSideEffects               mutant killed (test failure)
TextAlignmentConstraint.swift:136              RemoveSideEffects               mutant killed (test failure)
TextAlignmentConstraint.swift:146              RemoveSideEffects               mutant survived
TextAlignmentConstraint.swift:147              RemoveSideEffects               mutant survived
TextAlignmentConstraint.swift:148              RemoveSideEffects               mutant survived
TextAlignmentConstraint.swift:178              RelationalOperatorReplacement   mutant survived
TextAlignmentConstraint.swift:183              RemoveSideEffects               mutant survived
UIKit+AdaptableTextContainerSupport.swift:29   RemoveSideEffects               mutant survived
UIKit+AdaptableTextContainerSupport.swift:59   RelationalOperatorReplacement   mutant survived
UIKit+AdaptableTextContainerSupport.swift:66   RemoveSideEffects               mutant survived
UIKit+AdaptableTextContainerSupport.swift:67   RemoveSideEffects               mutant survived
UIKit+Helpers.swift:43                         RelationalOperatorReplacement   mutant survived
Platform.swift:0                               RemoveSideEffects               skipped (no coverage)


--------------------
Mutation Test Scores
--------------------

These are the mutation scores for your test suite, as well as the files that had mutants introduced into them.

Mutation scores ignore build errors.

Of the 54 mutants introduced into your code, your test suite killed 9.
Mutation Score of Test Suite: 16%
Code Coverage of your project: 81%

File                                        # of Introduced Mutants   Mutation Score
----                                        -----------------------   --------------
ContextualAlternates.swift                  4                         25
FontFeatures.swift                          3                         100
NSAttributedString+BonMot.swift             1                         0
StylisticAlternates.swift                   21                        14
Tracking.swift                              1                         0
AdaptableTextContainer.swift                2                         0
AdaptiveStyle.swift                         4                         0
EmbeddedTransformation.swift                1                         0
NSAttributedString+Adaptive.swift           3                         0
StyleableUIElement.swift                    2                         0
TextAlignmentConstraint.swift               7                         28
UIKit+AdaptableTextContainerSupport.swift   4                         0
UIKit+Helpers.swift                         1                         0
Platform.swift                              1                         0
```

## Killing tests in the JSON report

`-f json` gives the same report as JSON. Three keys name the tests that failed for each killed mutant, summarise them and mark suspect tests, as [Killing tests and suspect tests](../README.md#killing-tests-and-suspect-tests) describes. They appear only when some mutant's tests were recorded, and a survivor never has them, so its JSON is as it was before. Keys can come in any order.

### `killingTests`

Each applied operator whose results line records `killedBy` has it: a mutant a failed test or a crash killed, or one that timed out. A session whose failed-test lines weren't reliable records none.

| Key | Meaning |
|---|---|
| `tests` | The tests its log showed failing, each once, in the order they first failed, at most 20. Each has a `name` and, for Swift Testing, the `location` where its issue was recorded. XCTest's lines give no location. |
| `count` | How many different tests failed, without the limit of 20 |
| `isComplete` | Whether `tests` names every test that failed: the run exited by itself, and `count` is the length of `tests`. A run stopped at its first failed test, or at its time limit, may have had more to fail. |

### `killedOnlyBySuspectTests`

`true` on a mutant a failed test killed when every test it names is suspect. Left out otherwise.

### `killingTestSummary`

At the top level, when a mutant a failed test killed has its tests recorded. A mutant a crash killed isn't counted.

| Key | Meaning |
|---|---|
| `killedMutants` | Mutants a failed test killed (`failed`) whose tests were recorded, even as none |
| `killedMutantsNamingNoTest` | Of those, how many name no test |
| `killedMutantsNotRecorded` | Mutants a failed test killed with no tests recorded |
| `incompleteLists` | Of the mutants naming tests, how many may not name every test that failed |
| `filesWithKills` | How many mutated files have a killed mutant that names a test: what the 15% is a share of |
| `suspectsChecked` | Whether `filesWithKills` is at least 10, so that a test can be suspect |
| `distinctTests` | How many different tests failed for those mutants |
| `tests` | The 10 tests that failed for the most mutants, ties broken by name and then file, then every other suspect test |
| `suspectOnlyKills` | Mutants only suspect tests were recorded failing for |
| `suspectOnlyKillsWithIncompleteLists` | Of those, how many may not name every test that failed. When it isn't 0, the score without suspect tests is a lower bound. |
| `mutationScoreWithoutSuspectOnlyKills` | The mutation score with those mutants counted as survivors, worked out as `globalMutationScore` is. Left out when `suspectOnlyKills` is 0. |

Each of its `tests`:

| Key | Meaning |
|---|---|
| `name` | The test's name, as `killingTests` gives it |
| `file` | The file its issues were recorded in, from `location`. With the name, it tells two tests apart. Left out for XCTest. |
| `mutants` | How many of those mutants it failed for |
| `files` | How many mutated files those mutants are in |
| `onlyRecordedFailureOf` | How many of them recorded it as the only test that failed |
| `suspect` | Whether it is suspect: `files` is at least 10, and at least 15% of `filesWithKills` |

Here is part of a report with two suspect tests. Most keys, file reports and tests are left out:

```json
{
  "globalMutationScore": 92,
  "numberOfKilledMutants": 1024,
  "totalAppliedMutationOperators": 1103,
  "fileReports": [
    {
      "fileName": "ActorReentrancyVisitor.swift",
      "appliedOperators": [
        {
          "testSuiteOutcome": "failed",
          "killingTests": {
            "tests": [
              { "name": "testAnalyzeProjectPerformance()", "location": "ProjectLinterTests.swift:98:9" }
            ],
            "count": 1,
            "isComplete": true
          },
          "killedOnlyBySuspectTests": true
        }
      ]
    }
  ],
  "killingTestSummary": {
    "killedMutants": 1005,
    "killedMutantsNamingNoTest": 0,
    "killedMutantsNotRecorded": 0,
    "incompleteLists": 36,
    "filesWithKills": 132,
    "suspectsChecked": true,
    "distinctTests": 1049,
    "tests": [
      {
        "name": "testAnalyzeProjectPerformance()",
        "file": "ProjectLinterTests.swift",
        "mutants": 796,
        "files": 128,
        "onlyRecordedFailureOf": 202,
        "suspect": true
      },
      {
        "name": "everyFormatRendersTheSameBytesForAnyArrivalOrder()",
        "file": "ReportOrderDeterminismLawsTests.swift",
        "mutants": 101,
        "files": 60,
        "onlyRecordedFailureOf": 8,
        "suspect": true
      }
    ],
    "suspectOnlyKills": 228,
    "suspectOnlyKillsWithIncompleteLists": 0,
    "mutationScoreWithoutSuspectOnlyKills": 72
  }
}
```
