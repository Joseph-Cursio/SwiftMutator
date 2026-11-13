# Example Test Report

```
Here's your test report:

--------------------------
Applied Mutation Operators
--------------------------

These are all of the ways that SwiftMutator introduced changes into your code.

In total, SwiftMutator introduced 54 mutants in 14 files.

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

## Counts, changed lines and run details in the JSON report

`-f json` gives the same report as JSON. These keys give what [Reports](../README.md#reports) describes. A report read back from one written before them has none of them, and each file's `path` is then its `fileName`.

### `path`, `key` and `durationSeconds`

Each file report has `path`, its path relative to the project, beside `fileName`. Each applied operator has:

| Key | Meaning |
|---|---|
| `path` | Its file's path relative to the project; absolute for a file outside it. `mutationPoint.filePath` is its path in the mutated copy. Left out of a file without coverage's row. |
| `key` | Its key, as `--mutant` takes it and the results file's line records it: `Sources/Bar.swift:12:9 SwapTernary`, with ` (#2)` for a repeat of the same place and operator. |
| `durationSeconds` | How long its run took, from launch to classification, to the millisecond, as its results line records it. |

### `run`

At the top level when the run wrote its results file in full: where the results came from. The build, toolchain and settings are those the last session that tested a mutant recorded; a resumed or reusing session with nothing left to test doesn't count, unless no session tested any. For a merged report, they are the first shard's.

| Key | Meaning |
|---|---|
| `resultsFiles` | The results file, or each shard's, in shard order, for a merged report |
| `sessions` | How many sessions made the results: the last session's number, more than 1 for a resumed run; for a merged report, every shard's added up |
| `swiftMutator` | `version`, `executablePath` and `executableSHA256`, which stands in for the commit |
| `toolchain` | `testCommandVersion`, `testExecutableSHA256` for a wrapper script, and `environment`: `SDKROOT`, `DEVELOPER_DIR` and `TOOLCHAINS` as set |
| `workers` | The workers the mutants were tested with; 0 when no session tested any, as for a `--reuse` of an unchanged project |
| `timeoutSeconds` and `timeoutIsDefault` | The time limit for a mutant's run, left out when none was set, and whether it is the default |
| `configuration` | The configuration as loaded, under its own keys |

### `mutantsByOutcome`

At the top level, always, with every count, zeros included. The counts are as the progress lines give them, so a crash counts as a kill.

| Key | Meaning |
|---|---|
| `killed` | Mutants a failed test or a crash killed |
| `survived` | Mutants the tests passed with |
| `timedOut` | Mutants whose run reached its time limit, which the score counts as survivors |
| `buildErrors` | Mutants that didn't build, which the score leaves out |
| `notCovered` | Mutants whose tests passed without running their code, which the score counts as survivors |

### `sourceChange`

On each applied operator whose line was found in its original file, while that file is as it was tested. Left out otherwise.

| Key | Meaning |
|---|---|
| `line` | The line's number, from 1 |
| `before` | The line as the original file holds it |
| `after` | The line as the mutant changes it. Left out for a removed statement that leaves nothing but spaces on its line. |

## Killing tests in the JSON report

Three keys name the tests that failed for each killed mutant, summarise them and mark suspect tests, as [Killing tests and suspect tests](../README.md#killing-tests-and-suspect-tests) describes. They appear only when some mutant's tests were recorded, and a survivor never has them. Keys can come in any order.

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
| `filesWithKills` | How many mutated files have a mutant whose first run a failed test that it names killed: what `suspectFilePercent` is a share of |
| `filesWithKillsLeft` | How many have a killed mutant that names a test now. Left out unless kills that no longer failed alone leave fewer |
| `suspectFilePercent` | The share of `filesWithKills`, in percent, that a test must have failed for mutants in to be suspect: the configuration's `suspectTestFilePercent`, 15 by default |
| `suspectMinimumFiles` | The configuration's `suspectTestMinimumFiles`, 10 by default: how many files with a kill there must be, and a test must have failed for mutants in, for it to be suspect |
| `suspectsChecked` | Whether `filesWithKills` is at least `suspectMinimumFiles`, so that a test can be suspect |
| `distinctTests` | How many different tests failed for those mutants |
| `tests` | The 10 tests that failed for the most mutants, ties broken by name and then file, then every other suspect or cleared test. A mutant tested again alone counts as its first run had it, whether or not it still fails |
| `suspectOnlyKills` | Mutants only suspect tests were recorded failing for |
| `suspectOnlyKillsWithIncompleteLists` | Of those, how many may not name every test that failed. When it isn't 0, the score without suspect tests is a lower bound. |
| `mutationScoreWithoutSuspectOnlyKills` | The mutation score with those mutants counted as survivors, worked out as `globalMutationScore` is. Left out when `suspectOnlyKills` is 0. |
| `controlRuns` | How many control runs, with no mutant on, the run's sessions ran among the mutants (see [Control runs](../README.md#control-runs)) |
| `failedControlRuns` | Of those, how many didn't pass: they failed, crashed or timed out |
| `failedControlRunsNamingNoTest` | Of those, how many named no failed test |
| `killsTestedAlone` | How many killed mutants this run tested again alone (see [Kills tested again alone](../README.md#kills-tested-again-alone)) |
| `killsThatSurvivedAlone` | Of those, how many no longer failed, so count as survivors or not covered |
| `suspectOnlyKillsNotTestedAlone` | Of `suspectOnlyKills`, how many weren't tested again, so count as kills on the first run's word |
| `flakyTests` | Every test that failed in a control run or didn't fail again often enough alone, as `{name, file, controlRuns, failedAgainAlone, notReproducedAlone}`, `controlRuns` being how many it failed in: those with the most such runs first, then by name and file. `file` is left out for XCTest. |

Each of its `tests`:

| Key | Meaning |
|---|---|
| `name` | The test's name, as `killingTests` gives it |
| `file` | The file its issues were recorded in, from `location`. With the name, it tells two tests apart. Left out for XCTest. |
| `mutants` | How many of those mutants it failed for |
| `files` | How many mutated files those mutants are in |
| `onlyRecordedFailureOf` | How many of them recorded it as the only test that failed |
| `failedControlRuns` | How many control runs it failed in: one or more makes it flaky |
| `suspect` | Whether it is suspect: it failed in a control run, didn't fail again often enough alone, or `files` is at least `suspectMinimumFiles` and at least `suspectFilePercent`% of `filesWithKills` and `clearedAlone` is false |
| `failedAgainAlone` | How many times it failed again when a mutant it had failed for was tested alone |
| `notReproducedAlone` | How many times it passed then, or failed with the mutant's code not running |
| `clearedAlone` | Whether those runs took it off the suspect tests: it failed again at least 3 times and never didn't |

Here is part of a report with two suspect tests. Most keys, file reports and tests are left out:

```json
{
  "globalMutationScore": 92,
  "numberOfKilledMutants": 1024,
  "totalAppliedMutationOperators": 1103,
  "mutantsByOutcome": { "killed": 1024, "survived": 75, "timedOut": 4, "buildErrors": 0, "notCovered": 0 },
  "fileReports": [
    {
      "fileName": "ActorReentrancyVisitor.swift",
      "path": "Sources/SwiftProjectLintCore/ActorReentrancyVisitor.swift",
      "appliedOperators": [
        {
          "testSuiteOutcome": "failed",
          "path": "Sources/SwiftProjectLintCore/ActorReentrancyVisitor.swift",
          "key": "Sources/SwiftProjectLintCore/ActorReentrancyVisitor.swift:41:24 RelationalOperatorReplacement",
          "durationSeconds": 2.412,
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
    "suspectFilePercent": 15,
    "suspectMinimumFiles": 10,
    "suspectsChecked": true,
    "distinctTests": 1049,
    "tests": [
      {
        "name": "testAnalyzeProjectPerformance()",
        "file": "ProjectLinterTests.swift",
        "mutants": 796,
        "files": 128,
        "onlyRecordedFailureOf": 202,
        "failedControlRuns": 0,
        "suspect": true,
        "failedAgainAlone": 0,
        "notReproducedAlone": 0,
        "clearedAlone": false
      },
      {
        "name": "everyFormatRendersTheSameBytesForAnyArrivalOrder()",
        "file": "ReportOrderDeterminismLawsTests.swift",
        "mutants": 101,
        "files": 60,
        "onlyRecordedFailureOf": 8,
        "failedControlRuns": 0,
        "suspect": true,
        "failedAgainAlone": 0,
        "notReproducedAlone": 0,
        "clearedAlone": false
      }
    ],
    "suspectOnlyKills": 228,
    "suspectOnlyKillsWithIncompleteLists": 0,
    "mutationScoreWithoutSuspectOnlyKills": 72,
    "controlRuns": 0,
    "failedControlRuns": 0,
    "failedControlRunsNamingNoTest": 0,
    "flakyTests": [],
    "killsTestedAlone": 0,
    "killsThatSurvivedAlone": 0,
    "suspectOnlyKillsNotTestedAlone": 228
  }
}
```

### `operatorExplanations`

At the top level, when the report has mutants: what each operator its mutants used does, in a line, by the name in their `mutationOperatorId`. The plain text report lists the same lines after its table of mutants, and the HTML report shows each one when you hold the pointer over the operator's name.

```json
"operatorExplanations": {
  "SwapTernary": "Swaps the two branches of a ternary expression."
}
```

### `triageSummary`

At the top level, when a triage file has entries: how far the survivors have been triaged (see [Triaging survivors](../README.md#triaging-survivors)). It changes no score. Each labelled survivor in `appliedOperators` also has `triage`, with its `label` and any `note`.

| Key | Meaning |
|---|---|
| `file` | The triage file's path |
| `survivors` | The mutants that survived, timed out or no test reached |
| `notCovered` | How many of them no test reached; left out when none |
| `triaged` | Those with a label |
| `byLabel` | Each label's `label` and how many `mutants` have it, zeros included |
| `moved` | Labels that followed their code: `from`, the place the file gives, `now`, and `label` |
| `notTested` | Labels on mutants that were build errors, so weren't tested, in the same form as `noLongerSurviving`. Left out without any. |
| `noLongerSurviving` | Labels on mutants that came to something else: `mutant`, `label`, `verdict`, such as `killed`, and `savedAs`, the key the file holds it by |
| `unmatched` | Labels that match no mutant in the results: `mutant` and `label` |

### `propertyKillSummary`

At the top level, when `propertyTests` or `--property-tests` gives globs: the kills split between example tests and property tests (see [Example tests and property tests](../README.md#example-tests-and-property-tests)). Its counts are of the mutants the headline score is of, every one but a build error, so its four kill counts add up to `killedMutants`.

| Key | Meaning |
|---|---|
| `globs` | The globs that picked out the property tests |
| `scoredMutants` | The mutants the headline score is of: every one but a build error |
| `killedMutants` | Those a failed test or a crash killed, as `numberOfKilledMutants` counts them |
| `killedOnlyByExamples` | Killed mutants whose recorded tests are all examples |
| `killedOnlyByProperties` | Killed mutants whose recorded tests are all properties |
| `killedByBoth` | Killed mutants that name tests of both kinds |
| `killedNamingNoTest` | Killed mutants that name no failed test, such as a crash's, which count as neither |
| `incompleteExampleOnlyKills` | Of `killedOnlyByExamples`, how many may not name every test that failed: a property may have failed too |
| `incompletePropertyOnlyKills` | Of `killedOnlyByProperties`, how many may not name every test that failed: an example may have failed too |
| `propertyReruns` | Of the kills whose recorded tests are all examples, how many the property tests were run again for on their own (`propertyTestFilter`) |
| `propertyRerunKills` | Of those, how many a property test failed for too: they count in `killedByBoth` |
| `propertyRerunPasses` | Of those, how many every property passed for: they count in `killedOnlyByExamples`, and never in `incompleteExampleOnlyKills` |
| `exampleReruns` | Of the kills whose recorded tests are all properties, in a list cut short, how many every test but the property tests was run again for (`propertyTestFilter`, SwiftPM only) |
| `exampleRerunKills` | Of those, how many a test the globs don't match failed for: they count in `killedByBoth` |
| `exampleRerunPasses` | Of those, how many every test passed for: they count in `killedOnlyByProperties`, and never in `incompletePropertyOnlyKills` |
| `distinctProperties` | How many property tests failed for a killed mutant |
| `properties` | The 10 that failed for the most killed mutants, ties broken by name and then file, each as `{name, file, mutants, onlyRecordedKillerOf}`: `file` as a test's in `killingTestSummary`, left out for XCTest; `mutants`, how many killed mutants it failed for; `onlyRecordedKillerOf`, how many of them recorded it as the only test that failed |

With made-up counts:

```json
"propertyKillSummary": {
  "globs": ["*Properties*"],
  "scoredMutants": 1103,
  "killedMutants": 1024,
  "killedOnlyByExamples": 812,
  "killedOnlyByProperties": 61,
  "killedByBoth": 151,
  "killedNamingNoTest": 0,
  "incompleteExampleOnlyKills": 36,
  "incompletePropertyOnlyKills": 2,
  "propertyReruns": 0,
  "propertyRerunKills": 0,
  "propertyRerunPasses": 0,
  "exampleReruns": 0,
  "exampleRerunKills": 0,
  "exampleRerunPasses": 0,
  "distinctProperties": 14,
  "properties": [
    { "name": "everyFormatRendersTheSameBytesForAnyArrivalOrder()", "file": "ReportOrderDeterminismLawsTests.swift", "mutants": 101, "onlyRecordedKillerOf": 8 }
  ]
}
```

### `propertySurvivorReruns`

At the top level, when `propertySurvivorReruns` tested survivors again with the property tests: what those runs came to (see [Testing survivors again with the property tests](../README.md#testing-survivors-again-with-the-property-tests)). It changes no score: every survivor stays one. The plain and HTML reports also list the survivors a property told apart; the JSON report holds the counts alone.

| Key | Meaning |
|---|---|
| `survivorsTestedAgain` | How many survivors were tested again |
| `failedOnALaterRun` | How many a property test failed or crashed for on some run: the law holds the change, and the generator rarely reaches an input that shows it |
| `passedEveryRun` | How many every run passed for: no property reaches the change, or the mutant is equivalent |
| `unsettled` | How many a run timed out or failed to build for, which settles nothing |
| `runs` | The most runs any of them was to be given, `propertySurvivorReruns` |

With made-up counts:

```json
"propertySurvivorReruns": {
  "survivorsTestedAgain": 12,
  "failedOnALaterRun": 3,
  "passedEveryRun": 9,
  "unsettled": 0,
  "runs": 10
}
```
