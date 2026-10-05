# The results file

SwiftMutator saves each mutant's result as soon as its test run finishes, as one line of JSON in the run's log folder. A run that is stopped, killed or crashes keeps every result it finished, and you can read a run's results while it is still going. The report at the end is written as before and doesn't depend on this file.

## Where it is

- `<project>_muter_logs/<run>/results.jsonl`, next to your project, beside the run's kept logs. For example, `SwiftProjectLint_muter_logs/Oct 4, 2026 at 1:16 PM/results.jsonl`.
- The run's folder is named to the minute. If a run that started in the same minute already has a `results.jsonl` there, the file is `results-2.jsonl`, then `results-3.jsonl`, up to `results-99.jsonl`. An existing file is never overwritten.
- SwiftMutator prints the path when it creates the file ("SwiftMutator saves each mutant's result as it finishes, in …"). After the report it prints it again ("Each mutant's result is in …"), if every line was written.
- It is always written, and there's no option to turn it off. A line takes about 0.5–1 KB, so a run of 2,500 mutants writes an estimated 2–3 MB, beside well over a gigabyte of logs.
- `run` and `run-without-mutating` write one. `mutate-without-running` tests no mutants and writes none.

## What's in it

The file is [JSON Lines](https://jsonlines.org): UTF-8, one JSON object per line, each line ending in a line break. Every object has a `kind`:

1. **`header`**, once. It is written when the baseline test run has passed, before the first mutant is tested, so a run whose baseline fails writes no file.
2. **`mutant`**, one for each tested mutant, written as its test run finishes. With several workers, mutants finish in a different order from the one they started in.
3. **`end`**, last. It is written when mutation testing stops, whether it finished or an error stopped it. A run that is killed or crashes has no end line. That includes Ctrl-C and SIGTERM, which today end SwiftMutator at once.

Here is a header, three of a run's mutant lines, and the end line of a run that stopped after 1,103 mutants:

```
{"baselineSeconds":32.104,"configuration":{"arguments":["test","--skip","ParallelListDriftDogfoodTests"],"coverageThreshold":0,"exclude":[],"excludeCalls":[],"executable":"/Users/me/.swiftly/bin/swift","mutationTestWorkers":4},"failedTestLinesAreReliable":true,"filesToMutate":[],"formatVersion":1,"kind":"header","logDirectory":"/Users/me/code/SwiftProjectLint_muter_logs/Oct 4, 2026 at 1:16 PM","mutantsDiscovered":2497,"mutantsToTest":2497,"mutatedProjectPath":"/Users/me/code/SwiftProjectLint_mutated","newVersion":"","operators":["ChangeLogicalConnector","RelationalOperatorReplacement","RemoveSideEffects","SwapTernary"],"projectPath":"/Users/me/code/SwiftProjectLint","provenance":{"arguments":["run","--skip-coverage","-o","mutation-report.txt"],"host":"studio.local","processIdentifier":81234,"swiftMutator":{"executablePath":"/usr/local/bin/swift-mutator","executableSHA256":"9f2c41d07b5e8a3c6e1f0d2b4a7c9e8f1d3b5a7c9e0f2d4b6a8c0e2f4d6b8a0c","version":"0.1.0"},"toolchain":{"environment":{"SDKROOT":"/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"},"testCommandVersion":"Apple Swift version 6.4 (swiftlang-6.4.0.1.2 clang-1800.0.1.1)\nTarget: arm64-apple-macosx27.0"}},"session":1,"skipCoverage":true,"startedAt":"2026-10-04T13:16:04.512Z","stopsAtFirstFailure":false,"timeoutIsDefault":true,"timeoutSeconds":96.312,"usingTestPlan":false,"workers":4}
{"column":22,"durationSeconds":31.207,"endedBy":"exited","exitStatus":1,"failedTestCount":2,"finishedAt":"2026-10-04T13:18:02.118Z","firstFailedTestLine":"✘ Test detectsExecutableTargets() recorded an issue at ExecutableTargetDetectorTests.swift:41:9: Expectation failed: (targets.count → 0) == 1","killedBy":[{"location":"ExecutableTargetDetectorTests.swift:41:9","name":"detectsExecutableTargets()"},{"location":"ExecutableTargetDetectorTests.swift:58:9","name":"\"Skips test targets\""}],"kind":"mutant","line":73,"log":"RelationalOperatorReplacement @ ExecutableTargetDetector.swift-73-22.log","mutationOperatorId":"RelationalOperatorReplacement","occurrence":0,"outcome":"failed","path":"Packages/Core/Sources/Core/ExecutableTargetDetector.swift","session":1,"snapshot":{"after":"<","before":">","description":"changed > to <"},"switchID":"ExecutableTargetDetector_RelationalOperatorReplacement_73_22_3361","utf8Offset":3361,"worker":2}
{"column":9,"durationSeconds":24.981,"endedBy":"exited","exitStatus":0,"finishedAt":"2026-10-04T13:18:09.040Z","kind":"mutant","line":118,"log":"RemoveSideEffects @ RuleRegistry.swift-118-9.log","mutationOperatorId":"RemoveSideEffects","occurrence":0,"outcome":"passed","path":"Packages/Core/Sources/Core/RuleRegistry.swift","session":1,"snapshot":{"after":"","before":"cache.removeAll()","description":"removed line"},"switchID":"RuleRegistry_RemoveSideEffects_118_9_4410","utf8Offset":4410,"worker":0}
{"column":17,"durationSeconds":96.402,"endedBy":"timedOut","failedTestCount":0,"finishedAt":"2026-10-04T13:19:10.777Z","killedBy":[],"kind":"mutant","line":40,"log":"ChangeLogicalConnector @ Walker.swift-40-17.log","mutationOperatorId":"ChangeLogicalConnector","occurrence":0,"outcome":"timeout","path":"Packages/Core/Sources/Core/Walker.swift","session":1,"snapshot":{"after":"||","before":"&&","description":"changed && to ||"},"switchID":"Walker_ChangeLogicalConnector_40_17_1502","utf8Offset":1502,"worker":1}
{"detail":"tooManyBuildErrors","endedAt":"2026-10-04T14:02:11.004Z","kind":"end","reason":"aborted","recorded":1103,"session":1,"testDurationSeconds":2766.493}
```

`jq . results.jsonl` prints each line indented.

- **Keys** are sorted, and slashes aren't escaped.
- **One line per record.** A record is never spread over several lines: a line break inside a value, such as in a multi-line snapshot, is written as `\n`.
- **Dates** are ISO 8601 in UTC, to the millisecond: `2026-10-04T13:16:04.512Z`.
- **A value that isn't there** is left out, never written as `null`.

### `header`

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"header"` | |
| `formatVersion` | Int | 1. See [Compatibility](#compatibility). |
| `session` | Int | 1 |
| `startedAt` | Date | When mutation testing started. The run's test duration is measured from here. |
| `provenance` | Object | The SwiftMutator build and toolchain the run used. See [below](#provenance). |
| `configuration` | Object | The configuration as `muter.conf.yml` set it, under its own keys (`executable`, `arguments`, `exclude`, …). An `executable` given as a bare name, such as `swift`, is resolved to its full path. Optional settings that weren't set, such as `mutationTestTimeout`, are left out. |
| `operators` | [String] | The mutation operators used, by name, sorted |
| `filesToMutate` | [String] | The files given with `--files-to-mutate`, or `[]` |
| `skipCoverage` | Bool | Whether `--skip-coverage` was given |
| `usingTestPlan` | Bool | Whether the run tested a test plan (`run-without-mutating`) |
| `projectPath` | String | Your project |
| `mutatedProjectPath` | String | The mutated copy that SwiftMutator tested. Each mutant's `path` is relative to it. |
| `logDirectory` | String | The run's log folder, which holds this file and the kept logs |
| `coverage` | `{percent, filesWithoutCoverage}` | The project's coverage, as the report shows it. Left out when the run has none: coverage was skipped, isn't supported for the test command, or couldn't be gathered. |
| `newVersion` | String | The newer SwiftMutator version the update check found, or `""` |
| `baselineSeconds` | Double | How long the baseline test run took |
| `timeoutSeconds` | Double | The time limit for each mutant's test run: `mutationTestTimeout`, or else the default the baseline set (3× its time, at least 10 s) |
| `timeoutIsDefault` | Bool | Whether `mutationTestTimeout` wasn't set, so `timeoutSeconds` is the default |
| `workers` | Int | How many mutants were tested at once |
| `stopsAtFirstFailure` | Bool | Whether a mutant's test run stopped at its first failed test |
| `failedTestLinesAreReliable` | Bool | False when the passing baseline printed a line that looks like a failed test. Such lines then don't show that a mutant was killed, so no mutant line has `killedBy`. |
| `mutantsDiscovered` | Int | How many mutants the run found |
| `mutantsToTest` | Int | How many of them it set out to test, which today is all of them. It is written before any mutant is tested, so it says nothing about how many were: that is the number of `mutant` lines, or the end line's `recorded`. |

#### Provenance

| Key | Meaning |
|---|---|
| `swiftMutator.version` | SwiftMutator's version string |
| `swiftMutator.executablePath` | The running `swift-mutator`, with symbolic links resolved |
| `swiftMutator.executableSHA256` | The SHA-256 of that executable. It identifies the build, as SwiftMutator doesn't know the commit it was built from. |
| `toolchain.testCommandVersion` | What `swift --version` or `xcodebuild -version` printed. It is asked only when the configured `executable` is `swift` or `xcodebuild` itself, and in the mutated project, so swiftly reads its copied `.swift-version`. |
| `toolchain.testExecutableSHA256` | The SHA-256 of any other `executable`, such as a wrapper script. Such an executable is hashed rather than run, because running a script could do anything. |
| `toolchain.environment` | `SDKROOT`, `DEVELOPER_DIR` and `TOOLCHAINS`, the ones that are set. One that isn't set is left out, so unset and empty differ. |
| `processIdentifier` | SwiftMutator's process ID |
| `host` | The Mac's host name |
| `arguments` | SwiftMutator's command-line arguments, after its own path |

A value that couldn't be found, such as the hash of an executable that can't be read, is left out.

### `mutant`

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"mutant"` | |
| `session` | Int | 1, as in the header |
| `path` | String | The mutant's file, relative to `mutatedProjectPath`. The mutated copy has your project's layout, so this is also the file's path in your project. It is absolute if the file is outside the copy. |
| `line`, `column` | Int | Where the mutant is in the original file |
| `occurrence` | Int | 0, or n for the nth repeat in the run of the same `path`, operator, `line` and `column` |
| `mutationOperatorId` | String | `RelationalOperatorReplacement`, `RemoveSideEffects`, `ChangeLogicalConnector` or `SwapTernary` |
| `switchID` | String | The ID that switched the mutant on: under `swift test`, the contents of the worker's `.swiftmutator-active-mutant` file; otherwise an environment variable of that name. Only for diagnosis: two files with the same name can share one. |
| `utf8Offset` | Int | The mutant's offset in the file as SwiftMutator prepared it, which has lines SwiftMutator added at the top |
| `snapshot` | `{before, after, description}` | The code before and after the mutation, as the report shows it |
| `outcome` | String | `failed` (killed: a test failed), `runtimeError` (killed: the tests crashed), `passed` (survived), `timeout` (stopped at the time limit without showing a failure) or `buildError` |
| `endedBy` | String | How the test run ended: `exited` by itself; `timedOut`, stopped at the time limit; `stoppedAtFailedTest`, stopped at its first failed test (`stopAtFirstFailure`); or `couldNotRun`, when its log couldn't be opened or its command couldn't start, and `outcome` is `buildError`. A cancelled run is never written, as its outcome says nothing about the mutant. |
| `exitStatus` | Int | Only for `exited`: the exit code, or the number of the signal that ended it |
| `durationSeconds` | Double | From the start of the mutant's test run to its outcome, to the millisecond |
| `worker` | Int | Where it ran: 0 is the mutated project, and n is its clone `<project>_mutated_worker<n>` |
| `finishedAt` | Date | When the line was written |
| `killedBy` | `[{name, location}]` | See [below](#killedby). Only for `failed`, `runtimeError` and `timeout`, and left out when `failedTestLinesAreReliable` is false. |
| `failedTestCount` | Int | With `killedBy`: how many different tests the log shows failing, without the limit of 20 |
| `firstFailedTestLine` | String | With `killedBy`: the first line that shows a failed test, without colour codes, cut to 500 characters. Left out when no line does. |
| `log` | String | The name of the mutant's kept log in `logDirectory`. Two same-named files' mutants with the same operator, line and column get the same log name, so only one of their logs is kept. |

#### `killedBy`

`killedBy` lists the tests the run's log shows failing, in the order they first failed, at most 20. A test that failed several times is listed once. Tests with the same name in different files are listed separately.

- **Swift Testing** names a test as it prints it: `sum()`, `"Adds two numbers"` (quotes included), or `Suite "Parsing"` for an issue a suite recorded itself. `location` is where the issue was recorded, such as `SumTests.swift:12:5`, and is left out if the line doesn't say.
- **XCTest** names a test `-[Module.Class testName]` and gives no `location`.
- **Lines that don't count:** known issues, warnings and SwiftMutator's own notes never name a test.
- **When the list is complete:** when `endedBy` is `exited` and `failedTestCount` equals the length of `killedBy`. A run stopped at its first failed test, or at the time limit, shows only the tests that failed before it was stopped.
- **An empty list** means the log shows no failed test, for example in a run that timed out.

### `end`

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"end"` | |
| `session` | Int | 1, as in the header |
| `endedAt` | Date | |
| `reason` | String | `finished`; `aborted`, stopped by an error; or `interrupted`, when mutation testing was cancelled |
| `detail` | String | Only when `aborted`: a short code for why. `tooManyBuildErrors` means 5 build errors in a row. `workerBaselineTestFailed(worker: n)` means a worker clone's baseline run didn't pass. Any other error gives its type's name. It is never a log. |
| `testDurationSeconds` | Double | How long mutation testing took: the duration the report shows, before rounding |
| `recorded` | Int | How many `mutant` lines the run wrote |

## How it is written

- **Durable at once.** Each line is written whole and then flushed to disk with `fsync`. That happens before SwiftMutator shows the mutant's progress or keeps its log, and before its worker starts the next mutant. A line on disk survives SwiftMutator being killed, even with SIGKILL, and an operating-system crash.
- **Before an abort.** A mutant's line is written before the build-error check, so the fifth build error in a row, which stops the run, is in the file.
- **Locked while open.** The running SwiftMutator holds an exclusive `flock` on the file, so no other SwiftMutator process writes to it. The lock goes when the process exits, however it exits. Reading takes no lock, so you can read the file while the run is still writing it.
- **Failures don't stop the run.** If the file can't be created, SwiftMutator says so once and the run goes on without it. If a write fails, it says so once and writes nothing more, so a half-written line is never followed by another. Either way the report at the end is complete.

## Reading it

- **Read it line by line.** Look at `kind` first. Skip kinds you don't know, and ignore keys you don't know.
- **Skip a line that doesn't parse.** The last line of a run killed in the middle of a write can be cut off, and after a power loss the file can end in NUL bytes. The lines before it are complete.
- **Key mutants by `path`, `mutationOperatorId`, `line`, `column` and `occurrence`.** Each key is unique within a run, and a file that hasn't changed gives its mutants the same keys in the next run. An edit to the file can change a key, or keep it for a different mutant, so compare `snapshot` too before you match results across runs. Never key mutants by the order of their lines, which depends on when each one finished, or by `switchID`.
- **The last line wins.** If a key appears more than once, its last `mutant` line is the one that counts.

### Compatibility

New keys and new kinds of line are added without changing `formatVersion`, so a reader that skips what it doesn't know keeps working. `formatVersion` changes only for a change that an older reader would misread. A reader should refuse a file whose header has a `formatVersion` it doesn't know.

## `jq` recipes

The tests that killed the most mutants:

```bash
jq -r 'select(.kind == "mutant") | .killedBy[]?.name' results.jsonl | sort | uniq -c | sort -rn | head
```

How many mutants each test killed on its own. A test that is the only failure of many mutants may be failing under the load of mutation testing rather than because of the mutants:

```bash
jq -r 'select(.kind == "mutant" and .endedBy == "exited" and .failedTestCount == 1) | .killedBy[0].name' results.jsonl | sort | uniq -c | sort -rn | head
```

The survivors, as `path:line:column`:

```bash
jq -r 'select(.kind == "mutant" and .outcome == "passed") | "\(.path):\(.line):\(.column) \(.mutationOperatorId): \(.snapshot.description)"' results.jsonl
```

How many mutants had each outcome:

```bash
jq -r 'select(.kind == "mutant") | .outcome' results.jsonl | sort | uniq -c
```

The slowest mutants, with the worker that ran them:

```bash
jq -r 'select(.kind == "mutant") | [.durationSeconds, .worker, "\(.path):\(.line):\(.column)"] | @tsv' results.jsonl | sort -rn | head
```

How the run ended. No output means it is still running, or was killed:

```bash
jq -c 'select(.kind == "end")' results.jsonl
```

Plain `jq` stops at the first line that doesn't parse, such as a cut-off last line, after printing what the lines before it gave. The two recipes below read each line as text and skip any that doesn't parse (`fromjson?`), so they also work on a file from a run that was killed.

The progress of a run:

```bash
jq -nR '[inputs | fromjson?] | "\(map(select(.kind == "mutant")) | length) of \(map(select(.kind == "header"))[0].mutantsToTest) tested"' results.jsonl
```

The score so far, worked out as the report works it out: killed (`failed` and `runtimeError`) divided by everything but `buildError`, then times 100 and rounded down, or -1 when no mutant has been tested. Keep that order: multiplying first can give a score 1 higher than the report's, such as 29 rather than 28 for 29 killed out of 100.

```bash
jq -nR '[inputs | fromjson? | select(.kind == "mutant") | .outcome] | (map(select(. == "failed" or . == "runtimeError")) | length) as $killed | (map(select(. != "buildError")) | length) as $scored | {tested: length, killed: $killed, score: (if length == 0 then -1 elif $scored > 0 then ($killed / $scored * 100 | floor) else 0 end)}' results.jsonl
```
