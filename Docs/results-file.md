# The results file

SwiftMutator saves each mutant's result as soon as its test run finishes, as one line of JSON in the run's log folder. A run that is stopped, killed or crashes keeps every result it finished, and you can read a run's results while it is still going. The report at the end is written as before and doesn't depend on this file. `swift-mutator report` makes a run's report from the file, in any format, at any time: see [Reports from the file](#reports-from-the-file).

## Where it is

- `<project>_muter_logs/<run>/results.jsonl`, next to your project, beside the run's kept logs. For example, `SwiftProjectLint_muter_logs/Oct 4, 2026 at 1:16 PM/results.jsonl`.
- The run's folder is named to the minute. If a run that started in the same minute already has a `results.jsonl` there, the file is `results-2.jsonl`, then `results-3.jsonl`, up to `results-99.jsonl`. An existing file is never overwritten.
- SwiftMutator prints the path when it creates the file ("SwiftMutator saves each mutant's result as it finishes, in …"). After the report it prints it again ("Each mutant's result is in …"), if every line was written. When mutation testing stops early, it prints it on standard error instead ("Each tested mutant's result is in …"), on the same condition. If a mutant was tested, the command that makes a report from the file follows it, with the path quoted for the shell: "Full report: swift-mutator report '…/results.jsonl'".
- It is always written, and there's no option to turn it off. A line takes about 0.5–1 KB, so a run of 2,500 mutants writes an estimated 2–3 MB, beside well over a gigabyte of logs. The header's list of the project's files adds about 140 bytes a file: about 205 KB for a project of 1,450 files.
- `run` and `run-without-mutating` write one. `mutate-without-running` tests no mutants and writes none.

## What's in it

The file is [JSON Lines](https://jsonlines.org): UTF-8, one JSON object per line, each line ending in a line break. Every object has a `kind`:

1. **`header`**, once per session. A run's first session writes it when the baseline test run has passed, before the first mutant is tested, so a run whose baseline fails writes no file. A run that `--resume` continues adds a session to the same file, which starts with a header of its own on the same condition, so one whose baseline fails adds nothing.
2. **`retired`**, only in a resumed session, right after its header: the earlier results it no longer stands by. See [below](#retired).
3. **`mutant`**, one for each tested mutant, written as its test run finishes. With several workers, mutants finish in a different order from the one they started in.
4. **`end`**, last in each session. It is written when mutation testing stops: when it finishes, when an error stops it, and when Ctrl-C (SIGINT), SIGTERM or SIGHUP stops it (see [Stopping a run](../README.md#stopping-a-run)). A run that is killed with SIGKILL or crashes has no end line. Nor does one stopped at once, by a second signal or after 30 seconds of stopping, unless it had already written the end line.

Here is a header, three of a run's mutant lines, and the end line of a run that stopped after 1,103 mutants:

```
{"baselineSeconds":32.104,"configuration":{"arguments":["test","--skip","ParallelListDriftDogfoodTests"],"coverageThreshold":0,"exclude":[],"excludeCalls":[],"executable":"/Users/me/.swiftly/bin/swift","mutationTestWorkers":4},"failedTestLinesAreReliable":true,"filesToMutate":[],"formatVersion":1,"kind":"header","logDirectory":"/Users/me/code/SwiftProjectLint_muter_logs/Oct 4, 2026 at 1:16 PM","mutantsDiscovered":2497,"mutantsToTest":2497,"mutatedProjectPath":"/Users/me/code/SwiftProjectLint_mutated","newVersion":"","operators":["ChangeLogicalConnector","RelationalOperatorReplacement","RemoveSideEffects","SwapTernary"],"project":{"excluded":["mutation-report.partial.txt","mutation-report.txt"],"files":{"Package.swift":"d8e6cfa092102bced71ebe7272d359840b485d3327142a9e70b6bd44820cdbea","Packages/Core/Sources/Core/ExecutableTargetDetector.swift":"4452598a90734d67d923000920d537103f35f50f081e3725b0530f9dcb7ad52f","Packages/Core/Sources/Core/RuleRegistry.swift":"9cffc889f169316bfc58efb2aa7d036813cceb51b6328d3b4549e686034b7298","Packages/Core/Sources/Core/Walker.swift":"c09bd4febfd3fa9d9f30e1bdafe8d16fcffd723ddf1985a02aa8b9b567283db9","README.md":"b77adc82295d39069fd44b76ebf7c6f1c6c37ef0f9d0b0fe4927b6bec34c4e20"},"listedBy":"git","treeSHA256":"2ad7d4dc5bcf04035334eaf0af91884f5d1c063f5fa5b915d7e82223e39f17bb"},"projectPath":"/Users/me/code/SwiftProjectLint","provenance":{"arguments":["run","--skip-coverage","-o","mutation-report.txt"],"host":"studio.local","processIdentifier":81234,"swiftMutator":{"executablePath":"/usr/local/bin/swift-mutator","executableSHA256":"9f2c41d07b5e8a3c6e1f0d2b4a7c9e8f1d3b5a7c9e0f2d4b6a8c0e2f4d6b8a0c","version":"0.1.0"},"toolchain":{"environment":{"SDKROOT":"/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"},"testCommandVersion":"Apple Swift version 6.4 (swiftlang-6.4.0.1.2 clang-1800.0.1.1)\nTarget: arm64-apple-macosx27.0"}},"session":1,"skipCoverage":true,"startedAt":"2026-10-04T13:16:04.512Z","stopsAtFirstFailure":false,"timeoutIsDefault":true,"timeoutSeconds":96.312,"usingTestPlan":false,"workers":4}
{"column":22,"durationSeconds":31.207,"endedBy":"exited","exitStatus":1,"failedTestCount":2,"fileSHA256":"4452598a90734d67d923000920d537103f35f50f081e3725b0530f9dcb7ad52f","finishedAt":"2026-10-04T13:18:02.118Z","firstFailedTestLine":"✘ Test detectsExecutableTargets() recorded an issue at ExecutableTargetDetectorTests.swift:41:9: Expectation failed: (targets.count → 0) == 1","killedBy":[{"location":"ExecutableTargetDetectorTests.swift:41:9","name":"detectsExecutableTargets()"},{"location":"ExecutableTargetDetectorTests.swift:58:9","name":"\"Skips test targets\""}],"kind":"mutant","line":73,"log":"RelationalOperatorReplacement @ ExecutableTargetDetector.swift-73-22.log","mutationOperatorId":"RelationalOperatorReplacement","occurrence":0,"outcome":"failed","path":"Packages/Core/Sources/Core/ExecutableTargetDetector.swift","session":1,"snapshot":{"after":"<","before":">","description":"changed > to <"},"switchID":"ExecutableTargetDetector_RelationalOperatorReplacement_73_22_3361","utf8Offset":3361,"worker":2}
{"column":9,"durationSeconds":24.981,"endedBy":"exited","exitStatus":0,"fileSHA256":"9cffc889f169316bfc58efb2aa7d036813cceb51b6328d3b4549e686034b7298","finishedAt":"2026-10-04T13:18:09.040Z","kind":"mutant","line":118,"log":"RemoveSideEffects @ RuleRegistry.swift-118-9.log","mutationOperatorId":"RemoveSideEffects","occurrence":0,"outcome":"passed","path":"Packages/Core/Sources/Core/RuleRegistry.swift","session":1,"snapshot":{"after":"","before":"cache.removeAll()","description":"removed line"},"switchID":"RuleRegistry_RemoveSideEffects_118_9_4410","utf8Offset":4410,"worker":0}
{"column":17,"durationSeconds":96.402,"endedBy":"timedOut","failedTestCount":0,"fileSHA256":"c09bd4febfd3fa9d9f30e1bdafe8d16fcffd723ddf1985a02aa8b9b567283db9","finishedAt":"2026-10-04T13:19:10.777Z","killedBy":[],"kind":"mutant","line":40,"log":"ChangeLogicalConnector @ Walker.swift-40-17.log","mutationOperatorId":"ChangeLogicalConnector","occurrence":0,"outcome":"timeout","path":"Packages/Core/Sources/Core/Walker.swift","session":1,"snapshot":{"after":"||","before":"&&","description":"changed && to ||"},"switchID":"Walker_ChangeLogicalConnector_40_17_1502","utf8Offset":1502,"worker":1}
{"detail":"tooManyBuildErrors","endedAt":"2026-10-04T14:02:11.004Z","kind":"end","reason":"aborted","recorded":1103,"session":1,"testDurationSeconds":2766.493}
```

The header's `project` lists five files here. A real one lists every file in the project.

`jq . results.jsonl` prints each line indented.

- **Keys** are sorted, and slashes aren't escaped.
- **One line per record.** A record is never spread over several lines: a line break inside a value, such as in a multi-line snapshot, is written as `\n`.
- **Dates** are ISO 8601 in UTC, to the millisecond: `2026-10-04T13:16:04.512Z`.
- **A value that isn't there** is left out, never written as `null`.

### `header`

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"header"` | |
| `formatVersion` | Int | 1 for a run's first session, and 2 for a resumed one, whose file can hold `retired` lines. See [Compatibility](#compatibility). |
| `session` | Int | 1 for a run's first session, then one more for each session `--resume` adds to the file |
| `startedAt` | Date | When mutation testing started. The run's test duration is measured from here. |
| `provenance` | Object | The SwiftMutator build and toolchain the run used. See [below](#provenance). |
| `configuration` | Object | The configuration as `muter.conf.yml` set it, under its own keys (`executable`, `arguments`, `exclude`, …). An `executable` given as a bare name, such as `swift`, is resolved to its full path. Optional settings that weren't set, such as `mutationTestTimeout`, are left out. |
| `operators` | [String] | The mutation operators used, by name, sorted |
| `filesToMutate` | [String] | The files given with `--files-to-mutate`, or `[]` |
| `skipCoverage` | Bool | Whether `--skip-coverage` was given |
| `usingTestPlan` | Bool | Whether the run tested a test plan (`run-without-mutating`) |
| `projectPath` | String | Your project |
| `mutatedProjectPath` | String | The mutated copy that SwiftMutator tested. Each mutant's `path` is relative to it. |
| `logDirectory` | String | The session's log folder, which holds its kept logs. A resumed session has a folder of its own, and adds to the file in the first session's folder. |
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
| `project` | Object | Your project's files, each one's SHA-256, as SwiftMutator copied them, before it prepared any for mutation. See [below](#project). Left out by `run-without-mutating`, which copies nothing. |
| `mutantsReused` | Int | Only in a resumed session: how many earlier sessions' results it kept rather than tested again |
| `waived` | [String] | Only in a resumed session: the project files that changed since the last session and that `--resume-ignoring` let through, by their paths relative to the project, or `[]` |
| `forced` | [String] | Only in a resumed session: the `provenance` values that changed since the last session and that `--force-resume` let through, by name (`swiftMutator.executableSHA256`, `toolchain.testCommandVersion`, `toolchain.testExecutableSHA256` or `toolchain.environment`), or `[]` |

#### Provenance

| Key | Meaning |
|---|---|
| `swiftMutator.version` | SwiftMutator's version string |
| `swiftMutator.executablePath` | The running `swift-mutator`, with symbolic links resolved |
| `swiftMutator.executableSHA256` | The SHA-256 of that executable. It identifies the build, as SwiftMutator doesn't know the commit it was built from. |
| `toolchain.testCommandVersion` | What `swift --version` or `xcodebuild -version` printed. It is asked only when the configured `executable` is `swift` or `xcodebuild` itself, and in the mutated project, so swiftly reads its copied `.swift-version`. A resumed session asks it in your project before it is copied, where swiftly reads the same file. |
| `toolchain.testExecutableSHA256` | The SHA-256 of any other `executable`, such as a wrapper script. Such an executable is hashed rather than run, because running a script could do anything. |
| `toolchain.environment` | `SDKROOT`, `DEVELOPER_DIR` and `TOOLCHAINS`, the ones that are set. One that isn't set is left out, so unset and empty differ. |
| `processIdentifier` | SwiftMutator's process ID |
| `host` | The Mac's host name |
| `arguments` | SwiftMutator's command-line arguments, after its own path |

A value that couldn't be found, such as the hash of an executable that can't be read, is left out.

#### Project

SwiftMutator lists your project's files right after it copies the project, and hashes each one in the copy before it prepares any file for mutation. It takes about 0.1 s.

| Key | Meaning |
|---|---|
| `listedBy` | `git` or `walk`. `git`: `git ls-files --cached --others --exclude-standard`, run in your project, not in the copy. That lists tracked files, and untracked ones that neither your project's ignore files nor your global ones ignore. A nested repository or submodule is listed by its own git. `walk`: every file, when the project isn't in a git repository, is in a folder its repository ignores (where git lists none of its untracked files), or git fails. |
| `files` | Each file's SHA-256, by its path relative to the project. A symbolic link's is `link:` followed by the SHA-256 of the path it points to; it is never followed. A local package outside the project has its files under its path from the project, such as `../Core/Sources/Core/Core.swift`. |
| `excluded` | The `-o` report and its `.partial` sibling, which the run writes itself, and the configuration file it loads, such as `muter.conf.yml`, whose settings `configuration` records, when they are inside the project. They are left out of `files`: a resume compares the configuration key by key instead, so a change of `mutationTestWorkers` or `stopAtFirstFailure` doesn't refuse it. |
| `treeSHA256` | The SHA-256 of every file's path, a NUL, its hash and a line break, sorted by path. Two trees with the same files and hashes have the same `treeSHA256`. |

- **Always listed**, even when git ignores them: Swift files (which include `Package.swift` and `Package@swift-*.swift`) and `.swift-version`, at any depth. `Package.resolved` too, but only at the root and in an Xcode project's or workspace's `xcshareddata/swiftpm/`.
- **Never listed:** anything in a `.build`, `.git`, `.swiftpm`, `DerivedData` or `xcuserdata` folder at any depth, and `.DS_Store` files. Nor are the files SwiftMutator itself writes at the project's root: `muter-mappings.json`, `.swiftmutator-active-mutant` and `muter.xctestrun`.
- **Not followed:** with `listedBy` `git`, the walk that adds Swift files skips any folder that holds a `.git` entry, such as a worktree or a clone git ignores.
- **Outside the project:** the local packages your `Package.swift` files name with `.package(path:)`, and your Xcode projects with a local package reference, each by a literal path, and the ones those name in turn. SwiftMutator copies only your project, beside it, so every session builds whatever they hold then. Their files are listed and hashed the same way, where they are. A path a manifest computes isn't followed, and other files outside the project that a build or a test reads, such as sources an Xcode project references there, aren't listed.

### `mutant`

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"mutant"` | |
| `session` | Int | The session that tested it, as in its header |
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
| `log` | String | The name of the mutant's kept log in its session's `logDirectory`. Two same-named files' mutants with the same operator, line and column get the same log name, so only one of their logs is kept. |
| `fileSHA256` | String | The SHA-256 of the mutant's file as SwiftMutator copied it, before it prepared it for mutation: the file's entry in the header's `project.files`. Left out when the header has no `project`, or the file isn't in it. |

#### `killedBy`

`killedBy` lists the tests the run's log shows failing, in the order they first failed, at most 20. A test that failed several times is listed once. Tests with the same name in different files are listed separately.

- **Swift Testing** names a test as it prints it: `sum()`, `"Adds two numbers"` (quotes included), or `Suite "Parsing"` for an issue a suite recorded itself. `location` is where the issue was recorded, such as `SumTests.swift:12:5`, and is left out if the line doesn't say.
- **XCTest** names a test `-[Module.Class testName]` and gives no `location`.
- **Lines that don't count:** known issues, warnings and SwiftMutator's own notes never name a test.
- **When the list is complete:** when `endedBy` is `exited` and `failedTestCount` equals the length of `killedBy`. A run stopped at its first failed test, or at the time limit, shows only the tests that failed before it was stopped.
- **An empty list** means the log shows no failed test, for example in a run that timed out.

### `retired`

A session that `--resume` adds no longer stands by some of the earlier sessions' results: those of the mutants it tests again, and those of mutants its discovery no longer finds. It lists their keys in one line, right after its header, when there are any.

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"retired"` | |
| `session` | Int | The resumed session, as in its header |
| `keys` | `[{path, mutationOperatorId, line, column, occurrence}]` | The keys of the results it retires, sorted. Each is a key as a `mutant` line has it. |

### `end`

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"end"` | |
| `session` | Int | The session it ends, as in its header |
| `endedAt` | Date | |
| `reason` | String | `finished`; `aborted`, stopped by an error; or `interrupted`, stopped by a signal |
| `detail` | String | Only when mutation testing stopped early. When `interrupted`: the signal that stopped it, `SIGINT` (Ctrl-C), `SIGTERM` or `SIGHUP`, so a Ctrl-C can be told apart from a `kill` or a closed terminal. When `aborted`: a short code for why. `tooManyBuildErrors` means 5 build errors in a row. `workerBaselineTestFailed(worker: n)` means a worker clone's baseline run didn't pass. Any other error gives its type's name. It is never a log. |
| `testDurationSeconds` | Double | How long the session's mutation testing took. For a run's first session, the duration the report shows, before rounding. A resumed run's report shows every session's added up. |
| `recorded` | Int | How many `mutant` lines the session wrote |

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
- **A `retired` line drops a key.** No `mutant` line before it counts for a key it lists. A `mutant` line after it records the key again.

### Compatibility

New keys and new kinds of line are added without changing `formatVersion`, so a reader that skips what it doesn't know keeps working. `formatVersion` changes only for a change that an older reader would misread. A reader should refuse a file whose header has a `formatVersion` it doesn't know.

- **Format 1** is a run's first session.
- **Format 2** is a resumed session. Its file can hold `retired` lines, and a reader that skipped them would report results the run no longer stands by, so a SwiftMutator from before `--resume` refuses the file. A file that was never resumed stays in format 1, which those read.

## Reports from the file

`swift-mutator report` makes a run's report from its results file, in any of the formats `run` writes:

```
swift-mutator report <results> [-f plain|json|html|xcode] [-o <path>]
```

It only reads the results file: it mutates nothing, prints no banner and makes no log folder. Reading takes no lock, so it can report on a run that is still writing the file.

### What it takes

- **`<results>`** is a results file, or a run's log folder, `<project>_muter_logs/<run>/`, that holds one.
  - In a folder, only the names a run gives its results file count: `results.jsonl`, and `results-2.jsonl` up to `results-99.jsonl`.
  - A folder with none is refused.
  - So is a folder with several, one for each run that started in that minute. The error names them in the order the runs started in, so you can pass the one you want.
  - A path that isn't a folder is read as a results file.
- **`-f`** chooses the format, as in `run`: `plain` (the default), `json`, `html` or `xcode`.
- **`-o`** saves the report at that path, replacing any file there.
  - The path is used exactly as given. A report of a stopped run isn't named `.partial`, as `run`'s partial report is, because you chose the name.
  - A path that would destroy what is there is refused before anything is printed: the results file itself, by any name (through a symbolic link, a hard link, or a different case on a case-insensitive volume), and a folder.

### What the report holds

The report is made from each mutant's last line (see [Reading it](#reading-it)) and the last header. The mutants come in the order the run tested and reported them, not the order they finished in. `report` works that order out from each line's `path`, `switchID` and `occurrence`, the way discovery sorted them.

- **A finished run** gets back the report it made itself, in every format. The header holds the project paths, the coverage and the update notice the report shows, and the end line holds its exact test duration. Only what depends on when and where a report is made can differ:
  1. **The HTML footer** gives the time the report was made.
  2. **The Xcode format's warnings**, one for each survivor, come in the order the run tested the mutants. A run with several workers prints them as its mutants finish. The warnings are the same, and so is the summary.
  3. **The plain report's colours** are added when standard output is a terminal, unless `NO_COLOR` is set. The same rule applies to `run` and `report`, so the reports match when both write to a terminal, or neither does.
  4. **JSON keys** can come in a different order. The JSON is the same once it is parsed.
- **A run that was stopped by a signal or an error** gets a report of the mutants it tested, made the same way. It matches the partial report the run wrote beside its `-o`, if it wrote one, with the same four exceptions. The end line's `testDurationSeconds` gives the test duration.
- **A run with no end line**, which is still going, was killed or crashed, gets a report of the mutants it tested. The test duration runs from the header's `startedAt` to the last mutant's `finishedAt`.
- **A run stopped before any mutant finished** has no `mutant` lines, and gets an empty report: `Report of 0 of 2497 mutants`.
- **Lines that don't read** are skipped, as a reader should skip them, and the status says which.

The report doesn't say whether the run finished. The status on standard error does.

### Where the output goes

- **Standard output** holds the report alone, followed by a line break, when there's no `-o`. So `swift-mutator report <log folder> -f json > report.json` gives valid JSON. The Xcode format also prints its warnings there, before the report, with or without `-o`, as `run` does.
- **Standard error** says how many mutants the report covers, out of how many the run found, where the file is, and how the run ended. With `-o`, it then says where the report was saved:

  ```
  Report of 1103 of 2497 mutants, from /Users/me/code/SwiftProjectLint_muter_logs/Oct 4, 2026 at 1:16 PM/results.jsonl: the run stopped on an error (tooManyBuildErrors).
  Report saved to /Users/me/code/report.html
  ```

  How the run ended comes from the last session's end line:

  | End line | Status says |
  |---|---|
  | `finished` | `the run finished` |
  | `interrupted` | `the run was interrupted by SIGINT`, naming the signal in `detail` |
  | `aborted` | `the run stopped on an error (tooManyBuildErrors)`, giving the code in `detail` |
  | None | `the run has no end line, so it is still running, or it was killed or crashed` |

  When lines were skipped, another line numbers them, and says when the last was cut off as it was written: `Skipped 1 line that didn't read: 812; the last was cut off as it was written.`

  The status has no emoji, so it can be searched for in CI logs. Numbers have no thousands separators.

### Exit status

- **0** when the report was made, an empty one included.
- **1** with `Error: …` on standard error, when:
  - the path is missing or can't be read;
  - the file isn't a results file, because it has no header line;
  - a newer SwiftMutator wrote it, so its `formatVersion` is one this SwiftMutator doesn't know;
  - a folder holds no results file, or several;
  - `-o` is the results file or a folder;
  - the report can't be saved. Unlike `run`, `report` doesn't print a report it couldn't save, because the results file still holds everything. Fix the path and make the report again.
- **64** for a usage error, such as no path.

### Sessions

Every file SwiftMutator writes today holds one session. A file with several is reported as one run:

- each mutant's last line, from whichever session wrote it;
- the last header's project paths, coverage and update notice;
- every session's test duration, added up;
- how the run ended, from the last session's end line;
- how many mutants the run found, from the last header's `mutantsDiscovered`.

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
