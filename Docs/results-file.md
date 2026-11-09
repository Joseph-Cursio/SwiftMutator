# The results file

SwiftMutator saves each mutant's result as soon as its test run finishes, as one line of JSON in the run's log folder. A run that is stopped, killed or crashes keeps every result it finished, and you can read a run's results while it is still going. The report at the end is written as before and doesn't depend on this file. `swift-mutator report` makes a run's report from the file, in any format, at any time: see [Reports from the file](#reports-from-the-file). `swift-mutator run --resume` continues a stopped run from it, testing only the mutants without a result that still holds: see [Resuming a run](../README.md#resuming-a-run). `swift-mutator run --reuse` starts a new run from it, with a file of its own: see [Reusing an earlier run](../README.md#reusing-an-earlier-run).

## Where it is

- `<project>_muter_logs/<run>/results.jsonl`, next to your project, beside the run's kept logs. For example, `SwiftProjectLint_muter_logs/Oct 4, 2026 at 1:16 PM/results.jsonl`.
- The run's folder is named for the minute it started in. A run that starts in a minute that already has a folder gets one of its own, the same name followed by ` (2)`, then ` (3)` and so on, so a folder holds one run's logs. Should a folder already have a `results.jsonl`, the file is `results-2.jsonl`, then `results-3.jsonl`, up to `results-99.jsonl`. An existing file is never overwritten. While a run holds a results file, a hidden file beside it, `.results.jsonl.holder`, records which process holds it: see [How it is written](#how-it-is-written). Another hidden file, `.swiftmutator-run`, marks the folder as a run's: the run makes it as it claims the folder and holds an exclusive `flock` on it until it exits, so a run that prunes log folders (`keepLogFolders`) leaves alone the folder of any run still going. A run that `--reuse` reads the folder's results from holds a shared `flock` on it, or on the results file in a folder without one, until it ends, so no run prunes the folder before its logs are copied. It stays once the run has ended. A folder that holds only it counts as empty, so a run that keeps nothing still leaves no folder. `report`, `--resume` and `--reuse` ignore both.
- SwiftMutator prints the path when it creates the file ("SwiftMutator saves each mutant's result as it finishes, in …"). After the report it prints it again ("Each mutant's result is in …"), if every line was written. When mutation testing stops early, it prints it on standard error instead ("Each tested mutant's result is in …"), on the same condition. If a mutant has a result, the command that makes a report from the file follows it, with the path quoted for the shell: "Full report: swift-mutator report '…/results.jsonl'". Then comes the command that continues the run, which repeats SwiftMutator's own arguments but for an earlier `--resume`, `--reuse`, `--force-resume` and `--force-reuse`, with each `--reuse-ignoring` as a `--resume-ignoring`, and `--since`'s ref as the merge base it chose: "Continue: swift-mutator run … --resume '…/results.jsonl'". A run of a test plan's line repeats `run-without-mutating` and the plan's path as they were given, with any `--plan-ignoring`: "Continue: swift-mutator run-without-mutating muter-mappings.json --resume '…/results.jsonl'". A run of one mutant (`--mutant`) prints none: the same command tests it again.
- `run --reuse` only reads the earlier run's file, and writes one of its own in its own log folder, as a first session does.
- `run --resume` adds a session to the file it continues, which stays where it is, in the first session's log folder. The new session prints the file's path as it starts testing, as a first session does. Its kept logs go to a log folder of its own, named for the minute it started in as any run's is, followed by ` (2)`, ` (3)` and so on if that minute already has one. So a later session's folder holds no results file, but a note, `resumed session.txt`, whose first line is the file's path, by itself. `report`, `--resume` and `--reuse` follow the note, so they take that folder as well as the file or the first session's folder. The note is written once the session's header and `retired` line are, so a resume whose baseline fails leaves none. A session that keeps no log, such as one that runs no coverage and has nothing left to test, still keeps its folder, with the note in it. A run that keeps nothing in its folder, such as a refused resume, leaves no folder.
- It is always written, and there's no option to turn it off. A line takes about 0.5–1 KB, so a run of 2,500 mutants writes an estimated 2–3 MB, beside well over a gigabyte of logs. The header's list of the project's files adds about 140 bytes a file: about 205 KB for a project of 1,450 files.
- `run` and `run-without-mutating` write one. `mutate-without-running` tests no mutants and writes none.

## What's in it

The file is [JSON Lines](https://jsonlines.org): UTF-8, one JSON object per line, each line ending in a line break. Every object has a `kind`:

1. **`header`**, once per session. A run's first session writes it when the baseline test run has passed, before the first mutant is tested. A run that `--resume` continues adds a session to the same file, which starts with a header of its own on the same condition, so one whose baseline fails adds nothing to it. A run that stops before then writes a file of its own with a `stopped` line instead (below). One with nothing left to test runs no baseline, and writes its header at once, as does a run that `--reuse` starts with nothing left to test and nothing changed since the earlier run.
2. **`retired`**, only in a resumed session, right after its header: the earlier results it no longer stands by. See [below](#retired).
3. **`mutant`**, one for each tested mutant, written as its test run finishes. With several workers, mutants finish in a different order from the one they started in. A session that tests on several workers then runs its timeouts again at lower load, and writes a second line for each, with `rerun`, which replaces the first. A run that `--reuse` starts first writes one for each result it keeps from the earlier run, right after its header, each with `reusedFrom`, and with `rerun` too for a result that a rerun gave.
4. **`control`**, one for each control run: the test command with no mutant on, run among the session's mutants, about one for each 100 (`controlRunEvery`). See [below](#control).
5. **`propertyRerun`**, with `propertyTestFilter`: one for each kill whose recorded tests include no property test, which the session tested again with only the property tests, once every mutant was tested. See [below](#propertyrerun).
6. **`stopped`**, alone in its file, with no header: the run stopped before its first mutant, as its baseline or a build failed or ran past `buildTimeout`, or a signal stopped it. See [below](#stopped).
7. **`end`**, last in each session. It is written when mutation testing stops: when it finishes, when an error stops it, and when Ctrl-C (SIGINT), SIGTERM or SIGHUP stops it (see [Stopping a run](../README.md#stopping-a-run)). A run that is killed with SIGKILL or crashes has no end line. Nor does one stopped at once, by a second signal or after 30 seconds of stopping, unless it had already written the end line.

Here is a header, three of a run's mutant lines, and the end line of a run that stopped after 1,103 mutants. The first mutant was killed by tests its line names, so it kept no log, and its line has no `log`:

```
{"baselineSeconds":32.104,"configuration":{"arguments":["test","--skip","ParallelListDriftDogfoodTests"],"coverageThreshold":0,"exclude":[],"excludeCalls":[],"executable":"/Users/me/.swiftly/bin/swift","mutationTestWorkers":4},"failedTestLinesAreReliable":true,"filesToMutate":[],"formatVersion":4,"kind":"header","logDirectory":"/Users/me/code/SwiftProjectLint_muter_logs/Oct 4, 2026 at 1:16 PM","mutantsDiscovered":2497,"mutantsToTest":2497,"mutatedProjectPath":"/Users/me/code/SwiftProjectLint_mutated.noindex","newVersion":"","operators":["ChangeLogicalConnector","RelationalOperatorReplacement","RemoveSideEffects","SwapTernary"],"project":{"excluded":["mutation-report.partial.txt","mutation-report.txt"],"files":{"Package.swift":"d8e6cfa092102bced71ebe7272d359840b485d3327142a9e70b6bd44820cdbea","Packages/Core/Sources/Core/ExecutableTargetDetector.swift":"4452598a90734d67d923000920d537103f35f50f081e3725b0530f9dcb7ad52f","Packages/Core/Sources/Core/RuleRegistry.swift":"9cffc889f169316bfc58efb2aa7d036813cceb51b6328d3b4549e686034b7298","Packages/Core/Sources/Core/Walker.swift":"c09bd4febfd3fa9d9f30e1bdafe8d16fcffd723ddf1985a02aa8b9b567283db9","README.md":"b77adc82295d39069fd44b76ebf7c6f1c6c37ef0f9d0b0fe4927b6bec34c4e20"},"listedBy":"git","treeSHA256":"2ad7d4dc5bcf04035334eaf0af91884f5d1c063f5fa5b915d7e82223e39f17bb"},"projectPath":"/Users/me/code/SwiftProjectLint","provenance":{"arguments":["run","--skip-coverage","-o","mutation-report.txt"],"host":"studio.local","processIdentifier":81234,"swiftMutator":{"executablePath":"/usr/local/bin/swift-mutator","executableSHA256":"9f2c41d07b5e8a3c6e1f0d2b4a7c9e8f1d3b5a7c9e0f2d4b6a8c0e2f4d6b8a0c","version":"0.1.0"},"toolchain":{"environment":{"SDKROOT":"/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"},"testCommandVersion":"Apple Swift version 6.4 (swiftlang-6.4.0.1.2 clang-1800.0.1.1)\nTarget: arm64-apple-macosx27.0"}},"session":1,"skipCoverage":true,"startedAt":"2026-10-04T13:16:04.512Z","stopsAtFirstFailure":false,"testRunSeconds":10.75,"timeoutIsDefault":true,"timeoutSeconds":86,"usingTestPlan":false,"workers":4}
{"column":22,"durationSeconds":31.207,"endedBy":"exited","exitStatus":1,"failedTestCount":2,"fileSHA256":"4452598a90734d67d923000920d537103f35f50f081e3725b0530f9dcb7ad52f","finishedAt":"2026-10-04T13:18:02.118Z","firstFailedTestLine":"✘ Test detectsExecutableTargets() recorded an issue at ExecutableTargetDetectorTests.swift:41:9: Expectation failed: (targets.count → 0) == 1","killedBy":[{"location":"ExecutableTargetDetectorTests.swift:41:9","name":"detectsExecutableTargets()"},{"location":"ExecutableTargetDetectorTests.swift:58:9","name":"\"Skips test targets\""}],"kind":"mutant","line":73,"mutationOperatorId":"RelationalOperatorReplacement","occurrence":0,"outcome":"failed","path":"Packages/Core/Sources/Core/ExecutableTargetDetector.swift","session":1,"snapshot":{"after":"!=","before":">","description":"changed > to !="},"switchID":"ExecutableTargetDetector_1202e16ea88d5e02_RelationalOperatorReplacement_73_22_3361","utf8Offset":3361,"worker":2}
{"column":9,"durationSeconds":24.981,"endedBy":"exited","exitStatus":0,"fileSHA256":"9cffc889f169316bfc58efb2aa7d036813cceb51b6328d3b4549e686034b7298","finishedAt":"2026-10-04T13:18:09.040Z","kind":"mutant","line":118,"log":"RemoveSideEffects @ RuleRegistry.swift-118-9 222edb6566ca746c.log","mutationOperatorId":"RemoveSideEffects","occurrence":0,"outcome":"passed","path":"Packages/Core/Sources/Core/RuleRegistry.swift","session":1,"snapshot":{"after":"","before":"cache.removeAll()","description":"removed line"},"switchID":"RuleRegistry_222edb6566ca746c_RemoveSideEffects_118_9_4410","utf8Offset":4410,"worker":0}
{"column":17,"durationSeconds":86.083,"endedBy":"timedOut","failedTestCount":0,"fileSHA256":"c09bd4febfd3fa9d9f30e1bdafe8d16fcffd723ddf1985a02aa8b9b567283db9","finishedAt":"2026-10-04T13:19:10.777Z","killedBy":[],"kind":"mutant","line":40,"log":"ChangeLogicalConnector @ Walker.swift-40-17 123ded629f2c52a7.log","mutationOperatorId":"ChangeLogicalConnector","occurrence":0,"outcome":"timeout","path":"Packages/Core/Sources/Core/Walker.swift","session":1,"snapshot":{"after":"||","before":"&&","description":"changed && to ||"},"switchID":"Walker_123ded629f2c52a7_ChangeLogicalConnector_40_17_1502","utf8Offset":1502,"worker":1}
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
| `formatVersion` | Int | 4 for any session whose `mutant` lines may have no `log`: one that tests mutants without `keepAllLogs: true`, but for `--mutant`'s, and one that copies results with no `log` from the run it reuses. Otherwise 1 for a run's first session, and 3 for a resumed one, whose file can hold `retired` lines and which records `projectDelta` in place of `project`. 2 for a resumed session written before `projectDelta`, or whose last session recorded no `project`. See [Compatibility](#compatibility). |
| `session` | Int | 1 for a run's first session, then one more for each session `--resume` adds to the file |
| `startedAt` | Date | When mutation testing started. The run's test duration is measured from here. |
| `provenance` | Object | The SwiftMutator build and toolchain the run used. See [below](#provenance). |
| `configuration` | Object | The configuration as `muter.conf.yml` set it, under its own keys (`executable`, `arguments`, `exclude`, …), with `--workers`, `--timeout`, `--build-timeout` and `--report`, when given, as `mutationTestWorkers`, `mutationTestTimeout`, `buildTimeout` and `reports`, and `--exclude`'s entries after the file's `exclude`. An `executable` given as a bare name, such as `swift`, is resolved to its full path. Optional settings that weren't set, such as `mutationTestTimeout`, are left out. |
| `operators` | [String] | The mutation operators used, by name, sorted |
| `filesToMutate` | [String] | The files given with `--files-to-mutate`, or `[]` |
| `skipCoverage` | Bool | Whether `--skip-coverage` was given |
| `usingTestPlan` | Bool | Whether the run tested a test plan (`run-without-mutating`). Only `run-without-mutating` resumes a run that did, and only `run` one that didn't. |
| `testPlan` | `{path, sha256, formatVersion, swiftMutatorVersion}` | Only in a session that tested a test plan: the plan's path as it was read, the SHA-256 of its bytes, which change when it is edited, or made again from changed sources or with other options (a plan made again of the same sources has the same bytes), its format, and the SwiftMutator version that made it, left out for a plan from before plans recorded it. A resume of the run needs a plan with the same SHA-256. Results files from earlier SwiftMutators' `run-without-mutating` don't have it, so their runs can't be resumed. |
| `projectPath` | String | Your project |
| `mutatedProjectPath` | String | The mutated copy that SwiftMutator tested. Each mutant's `path` is relative to it. |
| `logDirectory` | String | The session's log folder, which holds its kept logs: its baselines', timed and control runs', coverage run's, and launch-failed and simulator-gone runs' logs, and the log of each mutant whose line names one (see [`log`](#mutant)). A resumed session has a folder of its own, and adds to the file in the first session's folder. Its folder holds a note, `resumed session.txt`, naming the file, so it stays even when the session kept no log. A later run with `keepLogFolders` set may remove it, with the results file, once the run is older than the newest it keeps (see [Results file](../README.md#results-file)). |
| `coverage` | `{percent, filesWithoutCoverage}` | The project's coverage, as the report shows it. Left out when the run has none: coverage was skipped, isn't supported for the test command, or couldn't be gathered. |
| `newVersion` | String | The newer SwiftMutator version the update check found, or `""` |
| `baselineSeconds` | Double | How long the baseline test run took, build included. After a build that failed on mutants that don't compile, only the last run's time: the one that passed. An xcodebuild baseline the simulator failed to launch runs once more, and this is both runs' time, from the first's start. Left out by a resumed session with nothing left to test, which runs no baseline, and by a session that `--reuse` starts with nothing left to test and nothing changed. |
| `testRunSeconds` | Double | How long one run of a mutant's test command took with no mutant on, just after the baseline. The default time limit is based on it. Left out when no run was timed: `mutationTestTimeout` is set, the project is built with neither SwiftPM nor xcodebuild, the run didn't pass, a resumed session, or one that `--reuse` started, had nothing left to test, or no mutant compiled. |
| `timeoutSeconds` | Double | The time limit for each mutant's test run: `mutationTestTimeout`, or else the default. With `testRunSeconds` that is 5× it, once more for each worker beyond the first, and at least 20 s; without it, 3× `baselineSeconds`, and at least 10 s. Left out when neither is there: in a resumed session with nothing left to test, or one that `--reuse` started with nothing left to test and nothing changed, without `mutationTestTimeout`. A resume, or a reuse, whose `mutationTestTimeout` changed goes ahead only if it is at least the longest `timeoutSeconds` of the file's sessions, and then tests the timeouts of a session with a shorter one again. |
| `timeoutIsDefault` | Bool | Whether `mutationTestTimeout` wasn't set, so `timeoutSeconds` is the default |
| `workers` | Int | How many mutants were tested at once: `mutationTestWorkers`, or else the default count for the mutants to test, but never more than the mutants to test, leaving out those that didn't compile, so 0 in a resumed session, or one that `--reuse` started, with nothing left to test, or in a session none of whose mutants compiled. 1 when the test command can't test more than one at once, such as an xcodebuild one that doesn't test on a simulator, when an xcodebuild run's workers' simulators couldn't be made, booted or checked, or when a run with the default count couldn't make its clones or they failed their baselines. One xcodebuild worker may still test on a simulator of its own, rather than on the test command's destination (`oneWorkerSimulator`). |
| `stopsAtFirstFailure` | Bool | Whether a mutant's test run stopped at its first failed test |
| `failedTestLinesAreReliable` | Bool | False when the passing baseline, or an xcodebuild worker's run with no mutant on, printed a line that looks like a failed test or a crash. Such lines then neither stop a mutant's run nor count a timed-out run killed. |
| `failedTestLookalikes` | `[{name, file}]` | The tests those lines show failing, sorted by name and then file, which no mutant's `killedBy` names, as the lines are the tests' own text. `file` is left out for XCTest. Absent when there are none. |
| `mutantsDiscovered` | Int | How many mutants the run found. With `--sample`, how many of them the sample holds; `sample` gives the count it was taken from. With `--shard`, how many the shard holds, of the sample if there is one; `shard` gives the count in every shard. |
| `mutantsToTest` | Int | How many of them it set out to test: all of them in a run's first session, and fewer in a resumed one, or one that `--reuse` starts, which test only those without an earlier result that still holds. It is written before any mutant is tested, so it says nothing about how many were: that is the number of the session's `mutant` lines with neither `reusedFrom` nor `rerun`, but for those that didn't compile, which are among them with `endedBy` `couldNotRun` and no run behind them. |
| `mutantsDropped` | Int | How many mutants discovery found and can't test: their switches have nowhere to go, as [Mutants outside function bodies](../README.md#mutants-outside-function-bodies) says, or [an `#if` leaves their code out of the build](../README.md#code-an-if-leaves-out). Of all the code discovery looked at, with `--sample` and `--shard` too, and with `--changed-lines`, of the changed lines. Left out when there are none, for a `--mutant` run, and for a run of a test plan, which discovers nothing. |
| `project` | Object | Your project's files, each one's SHA-256, as SwiftMutator copied them, before it prepared any for mutation. See [below](#project). A run of a test plan (`run-without-mutating`) copies nothing, so its `project` is the plan's copy as it was tested: prepared for mutation, and with any fix you made in it by hand. A resume of the run compares the copy with it, never your project. Results files from earlier SwiftMutators' `run-without-mutating` don't have it. A resumed session records `projectDelta` in its place. |
| `projectDelta` | Object | Only in a resumed session whose last session recorded `project` or `projectDelta`: its project's files as what changed since that session's, in place of `project`. See [below](#project). |
| `mutantsReused` | Int | Only in a resumed session: how many earlier sessions' results it kept rather than tested again. In a session that `--reuse` starts, how many of the earlier run's results it kept. |
| `waived` | [String] | Only in a resumed session: the project files that changed since the last session and that `--resume-ignoring` let through, by their paths relative to the project, or `[]`. In a run of a test plan, they are files of the plan's copy, by their paths relative to it. In a session that `--reuse` starts, those that `--reuse-ignoring` let through since any of the earlier run's sessions. |
| `testBundlesRunDirectly` | Bool | Only when the session's mutants ran their test bundles directly, with `swiftpm-testing-helper`, rather than through `swift test`: `true` |
| `reusedFrom` | String | Only in a session that `--reuse` starts: the earlier run's results file |
| `since` | Object | Only in a session run with `--since`: what it chose, below |
| `shard` | Object | Only in a session run with `--shard`: which shard it tested, and what discovery found in every shard, below |
| `sample` | Object | Only in a session run with `--sample`: the sample asked for, and how many mutants it held of how many, below |
| `mutant` | String | Only in a session run with `--mutant`: the key of the one mutant it tested, as `path:line:column Operator`. No other run resumes or reuses its results, and `swift-mutator report` says its score isn't the project's, on standard error and in the report it makes. |
| `mutantsNotCovered` | `[{path, line, column, occurrence, mutationOperatorId, snapshot}]` | The mutants of code no test ran, which the session made none of, as no test could kill them: in a region the coverage run never ran, or in a file the coverage data names that coverage leaves out as a whole, at or below `coverageThreshold`, as a file of a target the tests build that no test reaches is. A file the coverage data doesn't name, of a target no test builds, is left out, as from every run with coverage. Only those with a place for a switch, which a run with `--skip-coverage` would make, keyed as it would key them, and sorted by key. Of the code the session chose, as its mutants are chosen: `--since`, `--changed-lines`, `--files-to-mutate` and the excludes apply, and a shard records those it holds by the same rule as its mutants, so merged shards hold each once, and the first shard that holds mutants records too those of a shard that holds none, which writes no file; a sample records them all. No score counts them; a [baseline file](../README.md#failing-on-new-survivors) records them as survivors, `notCovered`, and `--baseline` compares them. Empty when the session found none. Left out with `skipCoverage`, which has none, and when the session doesn't know them: a `--mutant` run, a run of a test plan that doesn't record them (`mutate-without-running` records them in the plan), and any session of a SwiftMutator from before this key. Without `skipCoverage`, left out isn't none: `report --write-baseline` of such results writes no baseline file, and `report --baseline` says new code no test ran isn't seen. A resumed session discovers them again, and only the last header's count. |
| `forced` | [String] | Only in a resumed session, or one that `--reuse` starts: the `provenance` values that changed since the last session and that `--force-resume` or `--force-reuse` let through, by name (`swiftMutator.executableSHA256`, `toolchain.testCommandVersion`, `toolchain.testExecutableSHA256` or `toolchain.environment`), or `[]` |

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

A run of a test plan copies nothing. It hashes the files in the plan's copy once it has locked it and checked its switches, just before it builds: the code the mutants are tested in. Its files are the ones the plan's `sources` recorded, and in a resumed session those the last session's `project` recorded too, with `listedBy` as they give it, not the ones your project lists now: a file you `git rm` in your project, or that another branch doesn't have, is still the copy's. Only a plan that records none, as in the first session of a plan in format 0, lists them in your project. A local package outside the project is listed and hashed where it is. For xcodebuild, the folders SwiftMutator's build writes in the copy, its `-derivedDataPath` when that is in the copy and `TestContents`, are left out. The plan file is left out, wherever in the project it is. If a file with mutants differs from what `mutate-without-running` left there, as after a fix by hand, the run says so ("✏️ 1 file of the plan's copy differs from what `swift-mutator mutate-without-running` wrote, and is tested as it is now: …"), and tests it as it is.

| Key | Meaning |
|---|---|
| `listedBy` | `git` or `walk`. `git`: `git ls-files --cached --others --exclude-standard`, run in your project, not in the copy. That lists tracked files, and untracked ones that neither your project's ignore files nor your global ones ignore. A nested repository or submodule is listed by its own git. `walk`: every file, when the project isn't in a git repository, is in a folder its repository ignores (where git lists none of its untracked files), or git fails. |
| `files` | Each file's SHA-256, by its path relative to the project. A symbolic link's is `link:` followed by the SHA-256 of the path it points to; it is never followed. A local package outside the project has its files under its path from the project, such as `../Core/Sources/Core/Core.swift`. |
| `excluded` | The `-o` report, each report `--report` or `reports:` asks for, and the `.partial` sibling of each, which the run writes itself, and the configuration file it loads, such as `muter.conf.yml`, whose settings `configuration` records, when they are inside the project. They are left out of `files`: a resume compares the configuration key by key instead, but for `operators` and `skipOperators`, whose chosen operators it compares, so a change of `mutationTestWorkers`, `workersShareBuild`, `stopAtFirstFailure`, `buildTimeout`, `oneWorkerSimulator`, `suspectTestFilePercent`, `suspectTestMinimumFiles`, `controlRunEvery`, `suspectKillReruns`, `keepAllLogs`, `keepLogFolders`, `keepSwiftLintPhases`, `failUnder`, `propertyTests`, `propertyTestFilter` or `reports` doesn't refuse it. |
| `treeSHA256` | The SHA-256 of every file's path, a NUL, its hash and a line break, sorted by path. Two trees with the same files and hashes have the same `treeSHA256`. |

A resumed session's header records `projectDelta` instead: only what changed since the last session's tree, which is usually nothing, where a whole `project` on SwiftProjectLint took about 205 KB. The whole tree is the last session's, with `files` added or replacing theirs, without `removed`, and with this `listedBy` and `excluded`. SwiftMutator makes it again as it reads the file, from the tree whose `treeSHA256` is `baseTreeSHA256`, and checks that it comes to this `treeSHA256`. If it doesn't, or no earlier header has that tree, the header doesn't read, and nor do its session's lines, so a resume tests their mutants again.

| Key | Meaning |
|---|---|
| `baseTreeSHA256` | The last session's `treeSHA256` |
| `listedBy` | As in `project` |
| `excluded` | As in `project` |
| `files` | Each file added or changed since the last session, with its SHA-256, as in `project` |
| `removed` | The paths of the files removed since, sorted |
| `treeSHA256` | The whole tree's `treeSHA256`, as in `project` |

- **Always listed**, even when git ignores them: Swift files (which include `Package.swift` and `Package@swift-*.swift`) and `.swift-version`, at any depth. `Package.resolved` too, but only at the root and in an Xcode project's or workspace's `xcshareddata/swiftpm/`.
- **Never listed:** anything in a `.build`, `.git`, `.swiftpm`, `DerivedData` or `xcuserdata` folder at any depth, and `.DS_Store` files. Nor are the files SwiftMutator itself writes at the project's root: `muter-mappings.json`, `muter.xctestrun` and each xcodebuild worker's `muter-worker<n>.xctestrun`, and `.swiftmutator-active-mutant`, which earlier versions wrote there. Nor is `muter.triage.yml` at the root, which `swift-mutator triage` writes and no result reads, so labelling a mutant refuses no `--resume` and tests nothing again in a `--reuse`. A triage file with another name or in another folder isn't left out.
- **Not followed:** with `listedBy` `git`, the walk that adds Swift files skips any folder that holds a `.git` entry, such as a worktree or a clone git ignores.
- **Outside the project:** the local packages your `Package.swift` files name with `.package(path:)`, and your Xcode projects with a local package reference, each by a literal path, and the ones those name in turn. SwiftMutator copies only your project, beside it, so every session builds whatever they hold then. Their files are listed and hashed the same way, where they are. A path a manifest computes isn't followed, and other files outside the project that a build or a test reads, such as sources an Xcode project references there, aren't listed.

#### `since`

What `--since` chose, as it compared the working tree with the merge base before anything was copied:

| Key | Type | Meaning |
|---|---|---|
| `ref` | String | The ref as given. A resumed session, whose Continue line names the merge base, keeps the first session's. |
| `commit` | String | The commit the ref named |
| `mergeBase` | String | The merge base of that commit and HEAD, which the working tree was compared with |
| `changedLines` | Bool | Whether `--changed-lines` was given, so only the mutants on changed lines were tested |
| `files` | [Object] | Each Swift file that changed, before the excludes and the coverage filter: its `path` in the project as the disk spells it, its `sha256` as it was compared, which the copy's had to equal, and, with `--changed-lines`, the `lines` added or changed, as `[first, last]` pairs, and `deletionsAfter`, each line after which lines were only removed (0 is the file's start). A file new to the change has neither, as all of it changed. |
| `foldersNotCompared` | [String] | Only when there are some: the folders in the project that are repositories of their own, submodules or not, whose changes git doesn't compare here, so none of their files was chosen |

A resume compares `mergeBase` and `changedLines`, and whether either session has a `since` at all. The files and lines follow from the working tree: a file changed since is compared as any project file is.

#### `shard`

Which shard `--shard k/n` tested, and what discovery found in every shard:

| Key | Type | Meaning |
|---|---|---|
| `index` | Int | k, from 1 to `count` |
| `count` | Int | n |
| `mutantsInAllShards` | Int | How many mutants discovery found in every shard together. The header's `mutantsDiscovered` and `mutantsToTest` count only this shard's. |
| `mutantsPerShard` | [Int] | How many of them each shard holds, shard 1's first. A shard with none writes no results file, so this tells it from a shard whose file is missing. |
| `allKeysSHA256` | String | SHA-256 over a line for each of those mutants' keys: its `path`, `mutationOperatorId`, `line`, `column` and `occurrence`, each followed by a NUL, then a line break. The lines are sorted by their UTF-8 bytes. Shards whose discoveries found the same mutants have the same. |

A mutant's shard follows from its place alone, its key without `occurrence`. SHA-256 is taken over its `path`, `mutationOperatorId`, `line` and `column`, each followed by a NUL. The first 8 bytes are read as a big-endian number, which is taken modulo `count`, plus 1. So every repeat of one place and operator is in one shard, and a shard's keys are the ones a whole run gives the same mutants. Discovery filters the mutants: a shard's mutated copy holds only its own mutants' switches.

A resume compares `index` and `count`, and whether either session has a `shard` at all. `--reuse` compares neither: it keeps the earlier run's results for the mutants this shard holds. `--shard 1/1` is the whole run, and records no `shard`.

#### `sample`

The sample `--sample N --seed S` took:

| Key | Type | Meaning |
|---|---|---|
| `size` | Int | N |
| `seed` | Int | S, or the seed SwiftMutator chose when there was no `--seed` |
| `mutantsSampledFrom` | Int | How many mutants discovery found, after the excludes, the coverage filter and `--since`, before the sample |
| `mutantsSampled` | Int | How many the sample holds: N, a few more when the last place it took has repeats, or every mutant when there were no more than N. With `--shard` too, the header's `mutantsDiscovered` counts only the shard's part of them. |

A sample takes whole places, a mutant's key without `occurrence`. Each place is ranked by SHA-256 over the seed, in decimal, and its `path`, `mutationOperatorId`, `line` and `column`, each followed by a NUL; the first 8 bytes are read as a big-endian number. Ties are broken by the place. The sample takes places from the lowest rank up until it holds N mutants. So every repeat of one place and operator is in the sample or out of it together, and the sample's keys are the ones a whole run gives the same mutants. Discovery takes the sample after `--changed-lines`, and before `--shard`, so the shards of a sampled split share one sample.

A resume compares `size` and `seed`, and whether either session has a `sample` at all; so does a merge of shards. `--reuse` compares neither: it keeps the earlier run's results for the mutants this sample holds. A sample that held every mutant is the whole run, and its reports say nothing of it.

`mutantsSampledFrom` and `mutantsSampled` aren't compared: they follow from the working tree. After a change, new mutants can rank before some the sample took, and push them out. Their results are retired, as those of mutants no longer discovered are, but the run counts them apart, as they are still discovered: `ℹ️ 2 earlier results no longer count, as the sample no longer takes their mutants.`

A report of a sample's results gives the score's margin unless they are cut short: when the file has fewer results, each its key's last line, than the last header's `mutantsDiscovered`. Those are then a stopped run's first files', not a random part of the sample. A shard's hash doesn't depend on the seed, so a shard's results are a random part of the sample: a shard's own report, and a merge of some of the shards, give a margin from them, unless a shard given has some of its results but not all. One with none, as when its job was cancelled before its first mutant, adds nothing, as if its file weren't given.

### `mutant`

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"mutant"` | |
| `session` | Int | The session that tested it, as in its header; for a result with `reusedFrom`, the session that reused it |
| `path` | String | The mutant's file, relative to `mutatedProjectPath`. The mutated copy has your project's layout, so this is also the file's path in your project. It is absolute if the file is outside the copy. |
| `line`, `column` | Int | Where the mutant is in the original file |
| `occurrence` | Int | 0, or n for the nth repeat in the run of the same `path`, operator, `line` and `column` |
| `mutationOperatorId` | String | `RelationalOperatorReplacement`, `RelationalBoundary`, `RemoveSideEffects`, `ChangeLogicalConnector`, `SwapTernary`, `NegateConditional`, `ChangeArithmeticOperator`, `FlipBooleanLiteral`, `ReplaceBooleanValue` or `ReplaceReturnValue` |
| `switchID` | String | The ID that switched the mutant on: under `swift test`, the contents of the worker's active-mutant file beside its folder, named after the folder without `.noindex`, as `<project>_mutated.active-mutant` or `<project>_mutated_worker<n>.active-mutant`; otherwise an environment variable of that name. It is the file's name without `.swift`, a hash of `path`, the operator, `line`, `column` and `utf8Offset`, joined by `_`. Only for diagnosis: repeats of one place and operator share one, and results files from before the hash, and runs of a test plan made before it, have no hash in it. |
| `utf8Offset` | Int | The mutant's offset in the file as SwiftMutator prepared it, which has lines SwiftMutator added at the top |
| `snapshot` | `{before, after, description}` | The code before and after the mutation, as the report shows it |
| `outcome` | String | `failed` (killed: a test failed), `runtimeError` (killed: the tests crashed), `passed` (survived, or not covered with `activated: false`), `timeout` (stopped at the time limit without showing a failure) or `buildError` |
| `activated` | Bool | [Whether the mutant's code ran](../README.md#whether-a-mutants-code-ran): `true` if its block ran, `false` if the run reached mutated code but not its block, which makes a `passed` line a mutant not covered. Absent when the run showed neither, as a test host that can't write its marker doesn't, and on a line from before this key: nothing is known then, so test for `false`, never for anything but `true`. A line with `rerun` because `timeout` or `codeNotShownRunning` records `false` for showing neither too, as its session showed that its runs can say. One because `onlySuspectTestsFailed` records `true` if its first run showed the block ran, and otherwise what this run showed, so absent when it showed neither. |
| `endedBy` | String | How the test run ended: `exited` by itself; `timedOut`, stopped at the time limit; `stoppedAtFailedTest`, stopped at its first failed test (`stopAtFirstFailure`); `stoppedAtCrash`, stopped at a test process's crash before any failed test, also by `stopAtFirstFailure`, with `outcome` `runtimeError`; or `couldNotRun`, when its log couldn't be opened or its command couldn't start, and `outcome` is `buildError`. A [mutant that doesn't compile](../README.md#mutants-that-dont-compile), which was taken out of the build, has this with no run behind it: `durationSeconds` 0, `worker` 0, and a `log` that gives the compiler's error. A cancelled run is never written, as its outcome says nothing about the mutant. |
| `exitStatus` | Int | Only for `exited`: the exit code, or the number of the signal that ended it |
| `durationSeconds` | Double | From the start of the mutant's test run to its outcome, to the millisecond |
| `worker` | Int | Where it ran. For SwiftPM, 0 is the mutated project, and n is its clone `<project>_mutated_worker<n>.noindex`, or, when workers share one build, a worker that also tests in the mutated project. For xcodebuild, n is a simulator, not a copy: every worker tests in the mutated project, worker n on a simulator SwiftMutator made for it, from `muter-worker<n>.xctestrun` (`muter.xctestrun` for worker 0). One worker tests as worker 0, on your `-destination`, or on a simulator SwiftMutator made for it (`oneWorkerSimulator`). |
| `finishedAt` | Date | When the line was written |
| `killedBy` | `[{name, location}]` | See [below](#killedby). Only for `failed`, `runtimeError` and `timeout`. A session by an older SwiftMutator left it out when `failedTestLinesAreReliable` was false. |
| `failedTestCount` | Int | With `killedBy`: how many different tests the log shows failing, without the limit of 20 |
| `firstFailedTestLine` | String | With `killedBy`: the first line that shows a failed test, without colour codes, cut to 500 characters. Left out when no line does. |
| `log` | String | Only when the mutant kept a log. Absent for a mutant killed by a failed test its line names, as `killedBy` and `firstFailedTestLine` stand in for its log, unless `keepAllLogs: true` is set or the run is `--mutant`'s; only a format-4 session's lines leave it out. Present for a survivor, a crash, a timeout, a build error, and a kill whose line names no test. The name of the mutant's kept log in its session's `logDirectory`: `<operator> @ <file name>-<line>-<column> <path hash>.log`, with ` (#2)`, ` (#3)` and so on before `.log` for a repeat. The hash is of `path`, as `switchID`'s is. So each mutant of a session keeps a log of its own, same-named files' mutants and repeats included. A line with `rerun` names the second run's log, with ` (rerun)` before `.log`, and the first run's line keeps naming its own; each goes by the rule above. In results files whose log names have no hash, such mutants share a name, and only the last one tested kept its log. Under xcodebuild, a run the simulator failed to launch runs again at once, on the same worker, and only the second run has a line, which names its log. The first run's log is kept with ` (launch failed)` before `.log`, whether or not the second run keeps its own, and no line names it. | A line with `rerun` because `onlySuspectTestsFailed` uses ` (alone)` where others use ` (rerun)`. Such a rerun that timed out or failed to build writes no line but keeps that log, and the session also keeps `tests alone with no mutant on.log`, its run with no mutant on.
| `leftOutWithOthers` | Bool | Only `true`, and only on the line of a [mutant that doesn't compile](../README.md#mutants-that-dont-compile) taken out of the build with others, as the compiler's error could be any of theirs, so it may compile. `--fail-under` counts it as not killed. |
| `fileSHA256` | String | The SHA-256 of the mutant's file as SwiftMutator copied it, before it prepared it for mutation, or in a run of a test plan as the plan's copy held it when tested: the file's entry in the header's `project.files`. Left out when the header has no `project`, or the file isn't in it. |
| `reusedFrom` | `{resultsFile, session, despiteChanges}` | Only for a result that a session `--reuse` started kept rather than tested: the results file and session that tested it, and `despiteChanges` true when `--reuse-ignoring`, `--force-reuse`, `--resume-ignoring` or `--force-resume` let a change through since. Each of those sessions' headers says which (`waived`, `forced`). Everything else is as it was tested, but for `session`, `utf8Offset` and `switchID`, which are the reusing session's, and `log`, which names a copy of the log in its `logDirectory`. Only a log the reusing session would keep is copied, by the rule [`log`](#mutant) gives and its own `keepAllLogs`, so a reused kill by a test its line names has no `log`, and nor has a result recorded with none. A result reused again keeps where it was first tested. |
| `rerun` | `{because, workers, alone?}` | On the line of a mutant that a session ran again: why, `timeout`, `codeNotShownRunning` or `onlySuspectTestsFailed`, and how many mutants it ran at once meanwhile. With `onlySuspectTestsFailed`, [`alone`](../README.md#kills-tested-again-alone) lists the tests that failed in its first run, which this line replaces, each as `{name, file, result}`: `failedAgain`, `passed`, `failedWithItsCodeNotRunning`, or none when its log showed nothing of it, or when `--reuse` copied the line. A session that tests on several workers runs each of its timeouts again once every other mutant is tested, on a quarter of the workers, at least one, under the same time limit. The line follows the first run's, which it replaces by the last-line rule (see [Reading it](#reading-it)). A result that `--reuse` keeps keeps its `rerun`, as it keeps everything else it was tested with, though its own session didn't run it, so a session's own reruns are its lines with `rerun` and no `reusedFrom`. A kill whose `activated` isn't `true`, or on one worker such a timeout, is run again alone, as `codeNotShownRunning`, in a session where any run showed its code ran. `because` is a string, so a later SwiftMutator may give another reason. |

#### `killedBy`

`killedBy` lists the tests the run's log shows failing, in the order they first failed, at most 20. A test that failed several times is listed once. Tests with the same name in different files are listed separately.

- **Swift Testing** names a test as it prints it: `sum()`, `"Adds two numbers"` (quotes included), or `Suite "Parsing"` for an issue a suite recorded itself. `location` is where the issue was recorded, such as `SumTests.swift:12:5`, and is left out if the line doesn't say.
- **XCTest** names a test `-[Module.Class testName]` and gives no `location`.
- **Lines that don't count:** known issues, warnings and SwiftMutator's own notes never name a test, nor does a line naming one of the header's `failedTestLookalikes`: a test the passing baseline's lines showed failing. Such a line doesn't count toward `failedTestCount` or give `firstFailedTestLine` either.
- **When the list is complete:** when `endedBy` is `exited` and `failedTestCount` equals the length of `killedBy`. A run stopped at its first failed test, or at the time limit, shows only the tests that failed before it was stopped.
- **An empty list** means the log shows no failed test, for example in a run that timed out.
- **In the reports.** The plain, HTML and JSON reports show these lists, and every report works out its suspect tests from them. See [Killing tests and suspect tests](../README.md#killing-tests-and-suspect-tests).

### `retired`

A session that `--resume` adds no longer stands by some of the earlier sessions' results: those of the mutants it tests again, those of mutants its discovery no longer finds, and with `--sample` those of mutants its sample no longer takes. It lists their keys in one line, right after its header, when there are any.

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"retired"` | |
| `session` | Int | The resumed session, as in its header |
| `keys` | `[{path, mutationOperatorId, line, column, occurrence}]` | The keys of the results it retires, sorted. Each is a key as a `mutant` line has it. |

### `control`

A control run is the test command with no mutant on, run every so often among a session's mutants, on whichever worker is free, under the mutants' time limit and the same load. It never stops at its first failed test, so it shows every test that failed. A test that fails in one is flaky: the reports call it suspect, and count a kill that only flaky or suspect tests were recorded failing for as one without them (see [Killing tests and suspect tests](../README.md#killing-tests-and-suspect-tests)). A session runs one for each whole `controlRunEvery` mutants it tests, 100 by default, and none with `controlRunEvery: 0` or `--mutant`. Control run k starts once (k − 1) × `controlRunEvery` + `controlRunEvery` / 2 of the session's mutants have, halfway through its stretch. Its log is kept as `control run <k>.log` in the session's log folder. It is never a `mutant` line, and `end`'s `recorded` doesn't count it.

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"control"` | |
| `session` | Int | The session that ran it, as in its header |
| `number` | Int | 1 for the session's first |
| `afterMutants` | Int | How many of the session's mutants had started before it |
| `outcome` | String | As a mutant's: `passed`, `failed`, `runtimeError`, `timeout` or `buildError` |
| `endedBy` | String | As a mutant's |
| `exitStatus` | Int | As a mutant's |
| `durationSeconds` | Double | As a mutant's |
| `worker` | Int | Where it ran, as a mutant's `worker` says |
| `finishedAt` | Date | |
| `failedTests` | `[{name, location}]` | For a run that failed, crashed or timed out: the tests its log shows failing, as a mutant's [`killedBy`](#killedby) names them, at most 20, leaving out the header's `failedTestLookalikes` |
| `failedTestCount` | Int | With `failedTests`: how many different tests the log shows failing, without the limit |
| `firstFailedTestLine` | String | With `failedTests`: the first line that shows a failed test, as a mutant's |
| `log` | String | The kept log's file name in the session's `logDirectory`: `control run <number>.log` |

### `propertyRerun`

With `propertyTestFilter` set, once every mutant is tested, and after any timeouts are tested again, a session tests again each of its kills whose recorded tests include none that `propertyTests` picks out, with only the tests the filter selects: under `swift test` and the test bundles run directly, with `--filter <entry>` for each entry, and under xcodebuild with `-only-testing:<entry>`. It stops at the first failed test as the mutants' runs do. A run stopped at its first failed test records that test alone, so this line tells a kill only by examples from one by both (see [Example tests and property tests](../README.md#example-tests-and-property-tests)). A crash that names no test, and `--mutant`'s one mutant, aren't tested again.

First the filtered tests run once with no mutant on, and their log is kept as `property tests with no mutant on.log`. If they ran no test, as a filter that matches none doesn't, or didn't pass, no kill is tested again, and the run says why. The line follows its mutant's `mutant` line and never replaces it, and `end`'s `recorded` doesn't count it. A later `mutant` line of the same key, a new result, sets it aside, as does a `retired` line. A resumed session keeps an earlier session's lines for the results it keeps, and tests again the kills that have none; a session `--reuse` starts tests again every reused kill that needs one, as the earlier file's lines aren't copied.

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"propertyRerun"` | |
| `session` | Int | The session that ran it, as in its header |
| `path`, `line`, `column`, `occurrence`, `mutationOperatorId` | | The mutant's key, as its `mutant` line has it |
| `outcome` | String | How the property tests came out with the mutant on: `failed` or `runtimeError` is a kill by a property too, so by both; `passed` is a kill by examples alone; `timeout` or `buildError` settles nothing |
| `endedBy`, `exitStatus`, `durationSeconds`, `worker`, `finishedAt` | | As a mutant's |
| `killedBy`, `failedTestCount`, `firstFailedTestLine` | | As a mutant's, for the property tests that failed |
| `log` | String | The kept log's file name in the session's `logDirectory`, the mutant's own with ` (properties)` before `.log`. Absent when the property tests passed, or a property test the line names failed, unless `keepAllLogs: true` is set. |

### `end`

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"end"` | |
| `session` | Int | The session it ends, as in its header |
| `endedAt` | Date | |
| `reason` | String | `finished`; `aborted`, stopped by an error; or `interrupted`, stopped by a signal |
| `detail` | String | Only when mutation testing stopped early. When `interrupted`: the signal that stopped it, `SIGINT` (Ctrl-C), `SIGTERM` or `SIGHUP`, so a Ctrl-C can be told apart from a `kill` or a closed terminal. When `aborted`: a short code for why. `tooManyBuildErrors` means 5 build errors in a row. `workerBaselineTestFailed(worker: n)`, only in a file from before clones were built ahead of the header, means a worker clone's baseline run didn't pass. `mutantNotSwitchedOn` means a mutant's run couldn't be told to switch it on: under xcodebuild, its `muter.xctestrun` or `muter-worker<n>.xctestrun` couldn't be written. `controlRunNotSwitchedOff(number: n)` means control run n's xcodebuild worker's `.xctestrun` couldn't be written with no mutant on. `simulatorUnavailable(worker: n)` means the simulator xcodebuild worker n tested on was gone, as when it was deleted during the run: every run on it would have failed without testing its mutant. The run that found it gone has no line, and its log is kept with ` (simulator gone)` before `.log`. A resume makes new simulators for its workers; if the simulator was the one your `-destination` names, make it again first. Any other error gives its type's name. It is never a log. |
| `testDurationSeconds` | Double | How long the session's mutation testing took. For a run's first session, the duration the report shows, before rounding. A resumed run's report shows every session's added up. |
| `recorded` | Int | How many `mutant` lines the session wrote, those with `reusedFrom` or `rerun` included. So it can be more than the mutants the session tested: count the lines with neither for those, but for those that didn't compile, which are among them with `endedBy` `couldNotRun` and no run behind them. |

### `stopped`

The only line of the results file of a run that stopped before its first mutant ([#117](https://github.com/Joseph-Cursio/SwiftMutator/issues/117)), in its log folder. A resumed run that stops so writes it in its own log folder, and leaves the file it was resuming as it was, so that run can still be resumed. `report` says why the run stopped and exits as it did, and `--resume` and `--reuse` refuse the file ([Exit status](#exit-status)). Nothing is written for a run stopped by any other error, such as a configuration that doesn't parse, for `mutate-without-running`, or for a run with no log folder. A run killed with SIGKILL writes none either.

```
{"detail":"buildTimeoutReached","failedTestCount":1,"failedTests":[{"location":"CLITests.swift:31:9","name":"runsTheCLI()"}],"kind":"stopped","limitSeconds":600,"log":"baseline run.log","logDirectory":"/Users/me/code/SwiftProjectLint_muter_logs/Nov 8, 2026 at 9:00 AM","projectPath":"/Users/me/code/SwiftProjectLint","reason":"timedOut","startedAt":"2026-11-08T09:00:02.104Z","step":"baseline","stoppedAt":"2026-11-08T09:11:40.551Z"}
```

| Key | Type | Meaning |
|---|---|---|
| `startedAt`, `stoppedAt` | Date | When the run started, and when it stopped. |
| `step` | String | Where it was: `preparing` (any other step, such as copying the project, finding its files and mutants, or making the xcodebuild workers' simulators), `coverageRun`, `buildForTesting` (one of xcodebuild's builds), `baseline` (one of the baseline's runs), `directTestRun`, `workerBaselines` (the worker clones' baselines), `workerCheckRuns` (the xcodebuild workers' runs with no mutant on) or `timedTestRun`. |
| `reason` | String | `failed`: a baseline didn't pass, or a build for testing didn't build. `timedOut`: the step ran past `buildTimeout`. `interrupted`: a signal stopped the run. |
| `detail` | String | For `failed` and `timedOut`, the abort's code, as an end line's `detail` gives it: `baselineTestFailed`, `workerBaselineTestFailed(worker: n)`, `buildForTestingFailed` or `buildTimeoutReached`, with `(worker: n)` for a clone's. For `interrupted`, the signal: `SIGINT`, `SIGTERM` or `SIGHUP`. |
| `limitSeconds` | Double | For `timedOut`, the limit. |
| `log` | String | The step's log, by its name in `logDirectory`: a failed or stopped step's kept log, or, for a signal, the coverage run's log, or the output a baseline, direct or timed run was writing, under `running/`. Left out when there is none. |
| `failedTests`, `failedTestCount` | [Object], Int | The tests the step's log shows failing, at most 20, each as [`killedBy`](#killedby) gives one, and how many. Left out for a signal. |
| `projectPath`, `logDirectory` | String | As in the [header](#header). |
| `resuming` | String | For a `--resume`, the results file it was resuming, which it left as it was. |

## How it is written

- **Durable at once.** Each line is written whole and then flushed to disk with `fsync`. That happens before SwiftMutator shows the mutant's progress or keeps its log, and before its worker starts the next mutant. A line on disk survives SwiftMutator being killed, even with SIGKILL, and an operating-system crash.
- **Before an abort.** A mutant's line is written before the build-error check, so the fifth build error in a row, which stops the run, is in the file.
- **Locked while open.** The running SwiftMutator holds an exclusive `flock` on the file, so no other SwiftMutator process writes to it. The lock goes when the process exits, however it exits. While it holds the lock, it records its process ID, when that process started and its host in a hidden file beside the results file, `.results.jsonl.holder` (`.results-2.jsonl.holder` for `results-2.jsonl`, and so on), and removes it as it closes the file. So `run --resume` of a file that a run still holds is refused, naming that process and its host, and exits with status 6. A record is believed only while a process with that ID and start still runs, so a record that a run left as it ended without closing the file, such as one killed at once, names no one; the next run to hold the file replaces it. A record from another host, which this host can't check, is named as only a record. Without a record, as when a SwiftMutator older than this one holds the file, the refusal names the process and host that wrote the file's last session, and says it may not be the holder: a resume holds the lock long before it writes a session. Reading takes no lock, so you can read the file while the run is still writing it.
- **A cut-off line is ended.** Before a resumed session writes, it adds a line break to a last line that doesn't end in one, such as a line a killed run cut off, so that its own first line stands alone. Readers still skip a cut-off line.
- **A session's first lines go together.** A resumed session's header and its `retired` line are written in one write and flushed together, and a stop at once ends the session only after both. On macOS a run killed as it starts leaves both lines or neither. On Linux, or when a write is cut short, as on a full disk, it can leave a cut-off line, which readers skip. If the cut falls in the `retired` line, the file stands by the earlier results the session meant to retire until the next session writes its own `retired` line. Nothing is wrongly reused, because a resume checks the earlier results again.
- **Failures don't stop the run.** If the file can't be created, SwiftMutator says so once and the run goes on without it. If a write fails, it says so once and writes nothing more, so a half-written line is never followed by another. Either way the report at the end is complete.

## Reading it

- **Read it line by line.** Look at `kind` first. Skip kinds you don't know, and ignore keys you don't know.
- **Skip a line that doesn't parse.** The last line of a run killed in the middle of a write can be cut off, and after a power loss the file can end in NUL bytes. The lines before it are complete.
- **Key mutants by `path`, `mutationOperatorId`, `line`, `column` and `occurrence`.** Each key is unique within a run, and a file that hasn't changed gives its mutants the same keys in the next run. An edit to the file can change a key, or keep it for a different mutant, so compare `snapshot` too before you match results across runs. Never key mutants by the order of their lines, which depends on when each one finished, or by `switchID`.
- **The last line wins.** If a key appears more than once, its last `mutant` line is the one that counts. That is how a timeout run again at lower load, whose second line has `rerun`, takes that run's result.
- **A `retired` line drops a key.** No `mutant` line before it counts for a key it lists. A `mutant` line after it records the key again.

### Compatibility

New keys and new kinds of line are added without changing `formatVersion`, so a reader that skips what it doesn't know keeps working. `formatVersion` changes only for a change that an older reader would misread. A reader should refuse a file whose header has a `formatVersion` it doesn't know.

- **A run stopped before its first mutant** writes a file with only a `stopped` line, which a SwiftMutator from before it refuses as a file with no header line, rather than report a run with no result.
- **Format 1** is a run's first session, also one that `--reuse` starts. A SwiftMutator from before `--reuse` reads the results such a session kept as tested in it.
- **A control run** is a `control` line, a kind a SwiftMutator from before control runs skips. Its reports then name no flaky test.
- **A timeout run again** has a second `mutant` line for its key, so a SwiftMutator from before `rerun` takes that line for the mutant's result, by the last-line rule, and ignores `rerun`.
- **Format 2** is a resumed session. Its file can hold `retired` lines, and a reader that skipped them would report results the run no longer stands by, so a SwiftMutator from before `--resume` refuses the file. A file that was never resumed stays in format 1, which those read.
- **Format 3** is a resumed session that records `projectDelta`. A format-2 reader would take it for a session with no `project`, which `--reuse` and a merge of shards skip rather than check, so a SwiftMutator from before `projectDelta` refuses the file. A file resumed by such a SwiftMutator holds format-2 sessions, which this one reads.
- **Format 4** is any session whose `mutant` lines may have no `log`: by default, a kill by a failed test its line names keeps no log. A format-3 reader can't read such a line, and would skip it as unreadable, losing that mutant's result, so a SwiftMutator from before format 4 refuses the file. A session that writes a `log` on every line keeps to formats 1 to 3: one with `keepAllLogs: true` that copies no result without a `log`, a `--mutant` run, and a resumed session with nothing left to test. A file all of whose sessions are such stays readable by older SwiftMutators.

## Reports from the file

`swift-mutator report` makes a run's report from its results file, in any of the formats `run` writes:

```
swift-mutator report <results>… [-f plain|json|html|xcode|markdown|stryker|sarif] [-o <path>] [--fail-under <percent>] [--baseline <path> [--max-new-survivors <count>] [--max-score-drop <points>]] [--max-doubtful-kills <count>] [--write-baseline <path>] [--summary <path>] [--force-merge] [--merge-ignoring <glob>]…
```

One results file is reported as it is. The results files of a `run --shard` split's shards, one alone included, are merged first ([Shards](#shards)).

It only reads the results file: it mutates nothing, prints no banner and makes no log folder. Reading takes no lock, so it can report on a run that is still writing the file.

### What it takes

- **`<results>`** is a results file, or a run's log folder, `<project>_muter_logs/<run>/`, that holds one, or the log folder of a session that resumed the run.
  - In a folder, only the names a run gives its results file count: `results.jsonl`, and `results-2.jsonl` up to `results-99.jsonl`.
  - A resumed session's folder holds none, but a note, `resumed session.txt`, whose first line is the path of the file the session added to. That file is reported. A folder whose note doesn't start with an absolute path to a file with one of those names is refused as one with none.
  - So a glob over a run's log folders, such as `<project>_muter_logs/*/`, names the file once through the first session's folder and once through each resumed session's. A file that a note names, and that is also given another way, is reported once, however each spells its path. A file given twice by its own path or folder is still given twice, so a shard's file given twice is refused.
  - A folder with none, and no note, is refused.
  - So is a folder with several, one for each run that started in that minute, as a folder from before each run got its own can hold. The error names them in the order the runs started in, so you can pass the one you want.
  - A path that isn't a folder is read as a results file.
- **`-f`** chooses the format, as in `run`: `plain` (the default), `json`, `html`, `xcode`, `markdown`, `stryker` or `sarif`.
- **`-o`** saves the report at that path, replacing any file there.
  - The path is used exactly as given, but for a leading `~`, which is the home folder even where a shell leaves it, and any folder on the way to it that isn't there is made. A report of a stopped run isn't named `.partial`, as `run`'s partial report is, because you chose the name.
  - A path that would destroy what is there is refused before anything is printed: the results file itself, by any name (through a symbolic link, a hard link, or a different case on a case-insensitive volume), and a folder.
- **`--report format:path`** also saves a report in another format at that path, as `markdown:summary.md`; repeat it for several. Never `xcode`, whose warnings only `-f xcode` prints. The `reports:` the header records are never saved again, as that would replace the run's own files. A relative path is resolved against the current folder, and a leading `~` is the home folder, which a shell doesn't expand after `markdown:`. Each path is refused as `-o`'s is, and so is one that is `-o`'s, `--summary`'s or another `--report`'s, checked again once each report is saved. A path where a run would put another's partial report is taken, as `report` writes none. One that can't be saved stops `report` before the status lines, as for `-o`, and a folder on the way to it is made as for `-o`, and for `--summary`.
- **`--fail-under`** checks the report's headline score against a percent from 0 to 100, with up to 6 decimals, once the report is made, as a run checks its own ([Failing on a low score](../README.md#failing-on-a-low-score)): the exact score, so a score equal to it passes. Below it, `report` exits with 2. The verdict comes last on standard error: `Mutation score 71.4% is below the required 80%.` `report` reads no configuration, so only this flag sets a threshold, never the run's `failUnder`.
  - **One results file** is checked on what it holds. For a run that was interrupted or has no end line, the verdict says how many of its mutants have results: `… Only 1103 of 2497 mutants have results, as the run didn't finish.` A run that stopped on an error exits as it did, and its score isn't checked: `The required 80% isn't checked: the run stopped on an error.`
  - **Shards' files** are checked on the merged score, the whole run's. When the merged report lacks results, it exits as it would without the flag, and says `The required 80% isn't checked: the merged report lacks results.`
  - **A run of one mutant** (`--mutant`) isn't checked: its score isn't the project's.
  - **Nothing to score** passes, and **every mutant a build error** fails: nothing shows the threshold is met. So does **a run that didn't finish with no results yet** for the mutants it discovered, as when it was stopped just after its baseline.
  - **A mutant with `leftOutWithOthers`** counts as not killed, so the score checked can be below the report's headline.
- **`--baseline`** compares the report's survivors with a baseline file's, as a run compares its own ([Failing on new survivors](../README.md#failing-on-new-survivors)), and exits with 2 when more are new than `--max-new-survivors` allows, 0 unless given. The verdict comes last on standard error, after the score's, with each new survivor, up to 20. The file is read before the results files, and refused with status 8 when it isn't there, can't be read, holds a key SwiftMutator doesn't know, is of a newer format, or records another scope than the results header's: other operators, `skipCoverage`, or another `arguments`, `buildSystem`, `coverageThreshold`, `exclude`, `excludeCalls` or `mutationTestTimeout`. The scope isn't compared for results whose survivors aren't: a run of one mutant's (`--mutant`), which is said not to be compared, a run that stopped on an error, and a merge that lacks results. A run that didn't finish is compared on the results it has, and the verdict says how many; `report` of it, of a sample's or of a `--changed-lines` run's doesn't know the mutants left out, so it matches an entry only at its own key. As for `--fail-under`, `report` reads no configuration and compares only what this flag names.
  - **One results file** is compared on what it holds; a run that stopped on an error exits as it did, and says `The survivors aren't compared with the baseline file …: the run stopped on an error.`
  - **Shards' files** are compared on the merged survivors. When the merged report lacks results, it exits as it would without the flag, and says the survivors aren't compared.
  - **Lines.** A survivor is matched by what it changes and its line, read from the run's project, under the header's `projectPath`. On another machine, where that path isn't there, the line isn't known, and a survivor is matched by its change alone; the verdict says how many were.
- **`--max-score-drop`**, with `--baseline`, compares the score `--fail-under` checks with the baseline file's, as a run does ([Failing on a score drop](../README.md#failing-on-a-score-drop)), and exits with 2 when it fell more than that many points below it, a number from 0 to 100 with up to 6 decimals. The verdict comes on standard error after the survivors': `Mutation score 81.2% is 1.4 points below the baseline file muter.baseline.yml's 82.6%, within the 2 allowed.` Only a whole run's score is compared, so `report` doesn't compare that of a run of one mutant, a shard's, a merge of only some shards, a sample's, a `--since` run's, a `--files-to-mutate` run's, a run that didn't finish, one that stopped on an error, a merge that lacks results, or one of shards whose runs didn't discover the same mutants, as some may have no result, and says why; nor when the run, or the file, scored no mutant. Every shard's files, merged, are compared.
- **`--max-doubtful-kills`** counts the kills the results' own evidence doesn't back, as a run does ([Failing on doubtful kills](../README.md#failing-on-doubtful-kills)), with or without `--baseline`, and exits with 2 when there are more than that whole number. The verdict comes last on standard error, with each doubtful kill, up to 20. A run that stopped on an error, a merge that lacks results, and a run that didn't finish with mutants left to test, whose resume tests them, then its suspect kills again alone, aren't counted, and say so; a run that didn't finish with none left is counted, as a resume would rerun nothing. Merged shards' kills are each judged by their own shard's suspect tests, as that shard's run judged them.
- **`--write-baseline`** saves the report's survivors as a baseline file at that path, after the reports, and says so on standard error: `Baseline file saved to /path/to/muter.baseline.yml`, the path made absolute against the current folder. Only a whole run's results make one: a run that finished, or every shard of a split, merged. Of a run that didn't finish, stopped on an error or stopped before its first mutant, a merge that lacks results, covers only some shards or of shards that discovered different mutants, a run whose every mutant was a build error, a run of one mutant, a shard's, a sample's, a `--since` run's and a `--files-to-mutate` run's, it saves none and says why, which changes no exit status. Its path is refused as `-o`'s is, and may be `--baseline`'s own, which is read first.
- **`--property-tests`** splits the report's kills between example tests and the property tests its globs pick out, in place of the `propertyTests` the last session's header records ([Example tests and property tests](../README.md#example-tests-and-property-tests)). Repeat it for several globs. Without it, the header's are used, so the report splits the kills as the run's own did.
- **`--summary`** also saves the run's [summary.json](../README.md#summaryjson) at that path, with `ended` from the last session's end line; for merged shards, `aborted` if a shard was, else `interrupted` if one was, else `finished`, and left out when a shard has no end line or the file of a shard that holds mutants wasn't given. The same paths are refused as for `-o`, and so are `-o`'s own and each `--report`'s, even spelled in another case on a volume that ignores case: the summary is then refused once the report is saved. Its `reports` lists the `--report` reports saved. With `--fail-under`, its `gate` holds the verdict: `gate.failUnder` is the threshold `report` checked, and `run.configuration.failUnder`, if the header has one, the run's own. With `--baseline`, its `newSurvivors` holds the verdict on the survivors, and with `--max-score-drop` its `scoreDrop` the verdict on the score against the file's. With `--max-doubtful-kills`, its `doubtfulKills` holds the verdict on the kills.

### What the report holds

The report is made from each mutant's last line (see [Reading it](#reading-it)) and the last header. The mutants come in the order the run tested and reported them, not the order they finished in. `report` works that order out the way discovery sorted them: files by their path in the mutated project (`path` under the header's `mutatedProjectPath`, or `path` itself for a file outside it), then each file's mutants by `line` and `column` as numbers, then by `mutationOperatorId`, and repeats of one place and operator by `occurrence`. Never by `utf8Offset`, which a resumed session's kept result holds as the session that tested it counted it.

- **A finished run** gets back the report it made itself, in every format, unless it is from before that order (below). The header holds the project paths, the coverage and the update notice the report shows, and the end line holds its exact test duration. Only what depends on when and where a report is made can differ:
  1. **The HTML footer** gives the time the report was made.
  2. **The Xcode format's warnings**, one for each survivor, come in the order the run tested the mutants. A run with several workers prints them as its mutants finish. The warnings are the same, and so is the summary.
  3. **The plain report's colours** are added when standard output is a terminal, unless `NO_COLOR` is set. The same rule applies to `run` and `report`, so the reports match when both write to a terminal, or neither does.
  4. **JSON keys** can come in a different order in the JSON report. The JSON is the same once it is parsed. The Stryker and SARIF reports sort theirs.
  5. **The results file's path** in the Run section and the JSON's `run` is spelled as `report` found it, from the path or folder it was given, which can differ from the run's spelling, as through a symbolic link.
  6. **The source the Stryker report embeds**, and the columns and fingerprints the Stryker and SARIF reports take from it, are read from each file as it is when the report is made: a report of an old results file shows today's code, even where it has changed since the run. The SARIF report's paths are from the work tree the project's folder is in when the report is made, and where that folder is gone, as for a results file from another machine, from the work tree the current folder is in.
- **A run that was stopped by a signal or an error** gets a report of the mutants it tested, made the same way. It matches the partial report the run wrote beside its `-o`, if it wrote one, with the same six exceptions. The end line's `testDurationSeconds` gives the test duration.
- **A run with no end line**, which is still going, was killed or crashed, gets a report of the mutants it tested. The test duration runs from the header's `startedAt` to the last mutant's `finishedAt`.
- **A run stopped before any mutant finished** has no `mutant` lines, and gets an empty report: `Report of 0 of 2497 mutants`.
- **Lines that don't read** are skipped, as a reader should skip them, and the status says which.
- **A run by a SwiftMutator from before that order**, which sorted each file's mutants by `switchID` as text, gets them in line order. Its report listed them by operator, and line 10 before line 9.

**Killing tests.** The report names each mutant's tests from its line's `killedBy`, `failedTestCount` and `endedBy`. It works out the Killing Tests summary, the suspect tests and the score without them from those lines alone, the way the run does (see [Killing tests and suspect tests](../README.md#killing-tests-and-suspect-tests)). So a run and its `report` name the same tests and the same suspects.

- **Completeness** is judged mutant by mutant, as [`killedBy`](#killedby) says. So a file whose sessions ran with different `stopAtFirstFailure` settings gives each mutant's list the right verdict.
- **A resumed run** keeps a kill it has a result for, except to [test it alone](../README.md#kills-tested-again-alone), which it does only with a mutant left to test. Any other kept list that a stopped run left short stays short.
- **No list** was recorded by a session of a SwiftMutator from before `failedTestLookalikes`, when its header has `failedTestLinesAreReliable` false. Its kills name no tests, and its mutants don't count toward suspect tests.
- **Flaky tests** are those that failed in any session's `control` line, or didn't fail again often enough in lines' `rerun.alone`; a report of merged shards takes every shard's. A `--reuse` copies no `control` line and clears each `alone` entry's `result`, so neither counts from the reused run.
- **A test's reach** counts a line with `rerun.alone` by the tests that list names, its first run's, whatever the line's outcome or `killedBy`.
- **Suspect tests** are those of the thresholds in the last session's `configuration`, `suspectTestFilePercent` and `suspectTestMinimumFiles`, 15% and 10 when it has none. A report of merged shards uses the reference shard's.

The report doesn't say whether the run finished. The status on standard error does, and so does `--summary`'s `ended`.

### Where the output goes

- **Standard output** holds the report alone, followed by a line break, when there's no `-o`; a `--report` never writes there. So `swift-mutator report <log folder> -f json > report.json` gives valid JSON. The Xcode format also prints its warnings there, before the report, with or without `-o`, as `run` does.
- **Standard error** says how many mutants the report covers, out of how many the run found, where the file is, and how the run ended. When the report has suspect tests, it then gives the warning a run ends with, without the emoji. With `-o`, it then says where the report was saved, and so for each `--report`, after it:

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

  For a file of more than one session, or with results that `--reuse` kept, the next line says which sessions tested the report's results: how many the last session tested, how many each earlier session did, and how many `--reuse` kept, by the results file each was first tested in. Each result counts once, for the line the report takes for its key ([Sessions](#sessions)), so the counts add up to the first line's:

  ```
  Of these, 1394 were tested in the last session, session 3, and 1103 in earlier ones (900 in session 1 and 203 in session 2).
  Of these, 300 were tested and 2197 kept by --reuse, tested in /Users/me/code/SwiftProjectLint_muter_logs/Oct 31, 2026 at 7:08 PM/results.jsonl.
  ```

  A result whose `endedBy` is `couldNotRun` wasn't tested, so it isn't counted as tested, and the line ends with how many there were, such as `and 8 didn't run, as they couldn't build or start`. The last session is always named, even when it tested none of them: `Of these, none were tested in the last session, session 2, and 2497 in session 1.` An earlier session with no result left in the report isn't named. A file of one session that kept nothing, and an empty report, get no such line.

  When lines were skipped, another line numbers them, and says when the last was cut off as it was written: `Skipped 1 line that didn't read: 812; the last was cut off as it was written.`

  The status has no emoji, so it can be searched for in CI logs. Numbers have no thousands separators.

### Exit status

- **0** when the report was made, an empty one included, unless the run stopped on an error, or a check failed: `--fail-under`, `--baseline`'s `--max-new-survivors`, `--max-score-drop` or `--max-doubtful-kills`.
- **2** when the score is below `--fail-under`, every mutant with a result was a build error, a run that didn't finish has no results, more survivors are new against `--baseline`'s file than `--max-new-survivors` allows, the score fell more than `--max-score-drop` points below that file's, or more kills are doubtful than `--max-doubtful-kills` allows. Every failed check exits with 2. The report, the status, the baseline file and the summary come first.
- **8** when `--baseline`'s file is refused: it isn't there, can't be read, holds a key SwiftMutator doesn't know, is of a newer format, or records another scope than the results. The reasons are said on standard error, and no report is made.
- **4** or **255** when the report was made of a run that stopped on an error, its last session's end line `aborted`: the status the run itself exited with, so a script that checks the report fails as one that checked the run would. 4 is for an abort, whose `detail` names its reason, such as `tooManyBuildErrors`; 255 for any other error. The report and the status come first, as for any other run. Shards' files exit with 4, or a stopped shard's status, whenever the report is known to lack results ([Shards](#shards)). An error's status wins over `--fail-under`, `--baseline`, `--max-score-drop` and `--max-doubtful-kills`, which then aren't checked. Earlier SwiftMutators exited with 255 for both.
- **3** or **4** for a run that stopped before its first mutant, whose file holds only a [`stopped`](#stopped) line: `report` says why on standard error, makes no report, and exits as the run did, 3 for a failed or timed-out build or baseline, and 4 for a signal, of which the run itself died. Given with other files, it is said and left out, and the others are reported, exiting with their status, or else its.
- **1** with `Error: …` on standard error, when:
  - the path is missing or can't be read;
  - the file isn't a results file, because it has no header line;
  - a newer SwiftMutator wrote it, so its `formatVersion` is one this SwiftMutator doesn't know;
  - a folder holds no results file, or several;
  - `-o` is the results file or a folder;
  - the report can't be saved. Unlike `run`, `report` doesn't print a report it couldn't save, because the results file still holds everything. Fix the path and make the report again;
  - several results files can't be merged ([Shards](#shards)).
- **64** for a usage error, such as no path.

### Sessions

A run's file holds one session, and one more for each time `run --resume` continued it. Each session runs from its header to its end line. `report` reports them as one run:

- each mutant's last line, from whichever session wrote it, unless a later `retired` line dropped its key;
- the last header's project paths, coverage and update notice;
- every session's test duration, added up;
- how the run ended, from the last session's end line;
- how many mutants the run found, from the last header's `mutantsDiscovered`.

So a resumed run that finished gets back the report its last session made, which covers every mutant, kept or tested again. The status counts every mutant with a result, whichever session tested it, and its next line says how many each session tested: `Report of 2497 of 2497 mutants, from …: the run finished.`, then `Of these, 1394 were tested in the last session, session 2, and 1103 in session 1.` A result tested again, as a timeout under a longer limit is, counts for the session that tested it again, and a rerun at lower load is one result, of its own session.

### Shards

Given the results files of a split's shards, each run with `--shard k/n`, `report` merges them into the whole run's report:

```
swift-mutator report <results> <results>… [--force-merge] [--merge-ignoring <glob>]… [-f …] [-o …]
```

One shard's file alone is a merge of one, so that a CI job's glob that finds one file is judged as one that finds two. `--force-merge` and `--merge-ignoring` are accepted with it, and do nothing.

Each is read as a single file is, and the last header of each must have a `shard` whose counts hold together, as every header SwiftMutator writes has them: `count` from 1 to 1000, `index` from 1 to `count`, a `mutantsPerShard` entry for each shard, adding up to `mutantsInAllShards`, and the shard's own entry equal to the header's `mutantsDiscovered`. They must all have the same `count`, and no `index` may be given twice. The shard with the lowest `index` given is the reference: each of the others is compared with it, by its last header, as a resume compares a run.

- **Compared:** every configuration key some outcome depends on, but for the `operators` and `skipOperators` keys, as the operators they choose are compared; `operators`, `filesToMutate` and `skipCoverage`; `since`'s `mergeBase` and `changedLines`; and the SwiftMutator build, the toolchain and its environment. A difference in the build or the toolchain is let through by `--force-merge`, and nothing else is.
- **The project's files** are compared path by path, as a resume compares them, with what each shard left out, its `-o` report and the configuration file, taken out of both. `--merge-ignoring` lets files that differ through, by glob, as `--resume-ignoring` does.
- **Mutants:** none may have a result in two files. Shards that discovered the same mutants, by `allKeysSHA256`, must have split them alike, by `mutantsPerShard`.

Every reason found is given at once, with exit status 1, and no report is made.

The report is made from every shard's results, each its file's last line for the key, as for a single file. The mutants come in the order a whole run tests them, under the reference shard's `mutatedProjectPath`. The reference shard's last header gives the project paths, the coverage, `since`, `sample`, the suspect-test thresholds and the update notice. The mutants of code no test ran are every shard's last header's `mutantsNotCovered` together, each key once. The test duration is the longest shard's, as the shards are meant to run at once, and each shard's adds up its own sessions. When every shard that holds mutants is given, the report stands for the whole run, and has no `shards`. Otherwise its `shards` names the shards given, and the plain and HTML reports say that only their mutants were tested.

Standard error says, for one shard's file alone, what it says of any file, naming the shard: `Report of 1228 of 1228 mutants in shard 1 of 2, from …: the run finished.` For several:

```
Report of 2460 of 2463 mutants, merged from the results files of 2 of 2 shards.
Shard 1 of 2, 1228 of its 1228 mutants, from …/results.jsonl: the run finished.
Shard 2 of 2, 1232 of its 1235 mutants, from …/results.jsonl: the run was interrupted by SIGINT.
```

- The first line's total is `mutantsInAllShards`. If the shards' `allKeysSHA256` differ, their discoveries did, as when coverage differed between the machines: the line gives no total, and another says how many mutants in all each shard's run discovered.
- A shard whose file isn't given, or whose file says only why its run stopped before its first mutant, is named with the mutants `mutantsPerShard` gives it: `No results were given for shard 2 of 3, which holds 812 mutants.` A shard that holds none wrote no file, and is said to: `Shard 3 of 3 holds no mutant, so it has no results file.`
- Which sessions tested a file's results, and lines skipped in it, are said for its shard, after its own line: `In shard 2 of 2's file: of these, 300 were tested in the last session, session 2, and 932 in session 1.` The first line gives no such count, as the shards' sessions differ.
- What `--force-merge` and `--merge-ignoring` let through is said, as is a shard whose own sessions let changes through when it was resumed or reused, by their headers' `forced` or `waived`.

`report` exits with the status of the first shard, by its index, that stopped on an error, as that shard's run did, 4 or 255, and otherwise with 4, whenever the report is known to lack results: any shard's last session stopped on an error; a shard has fewer results than its header's `mutantsDiscovered`, as one that was interrupted, killed or is still running has; or a shard that holds mutants has no file among those given, as a shard whose baseline failed, which writes none. `--fail-under` then isn't checked. So a CI job that checks the merged report fails as one that checked every shard's run would. Discoveries that differ only warn: each shard has its own mutants' results.

## `jq` recipes

The first five recipes read every `mutant` line. A timeout run again at lower load has a second line in its session, with `rerun`. In a file that `run --resume` added sessions to, a mutant tested again has a line from each session that tested it, and a `retired` line can drop a result. Run them on `latest.jsonl`, which the last recipe makes, to read only the lines that count.

The tests that killed the most mutants:

```bash
jq -r 'select(.kind == "mutant") | .killedBy[]?.name' results.jsonl | sort | uniq -c | sort -rn | head
```

How many mutants each test killed on its own. A test that is the only failure of many mutants may be failing under the load of mutation testing rather than because of the mutants. The reports' Killing Tests section gives both counts, from mutants a failed test killed, and flags as suspect a test that failed for mutants in too many files:

```bash
jq -r 'select(.kind == "mutant" and .endedBy == "exited" and .failedTestCount == 1) | .killedBy[0].name' results.jsonl | sort | uniq -c | sort -rn | head
```

The survivors, as `path:line:column`, with the mutants no test reached among them unless `activated` is `false`:

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

How each session ended, one line each, with its `session`. If the last session has none, it is still running, or was killed:

```bash
jq -c 'select(.kind == "end")' results.jsonl
```

Plain `jq` stops at the first line that doesn't parse, such as a cut-off last line, after printing what the lines before it gave. The three recipes below read each line as text and skip any that doesn't parse (`fromjson?`), so they also work on a file from a run that was killed. They follow sessions too, so they work on a file that `run --resume` added sessions to.

The progress of a run: how many mutants its last session has tested, of those it set out to test. A resumed session, or one that `--reuse` started, adds how many results it kept, and so how many of the run's mutants have one:

```bash
jq -nR '[inputs | fromjson?] | (map(select(.kind == "header")) | last) as $header | (map(select(.kind == "mutant" and .session == $header.session and (has("reusedFrom") | not) and (has("rerun") | not))) | length) as $tested | "\($tested) of \($header.mutantsToTest) tested" + if $header | has("mutantsReused") then ", and \($header.mutantsReused) results kept from earlier sessions: \($tested + $header.mutantsReused) of \($header.mutantsDiscovered) mutants have results" else "" end' results.jsonl
```

The score so far, worked out as the report works it out: from each mutant's line that counts (see [Reading it](#reading-it)), killed (`failed` and `runtimeError`) divided by everything but `buildError`, then times 100 and rounded down, or -1 when no mutant has a result. Keep that order: multiplying first can give a score 1 higher than the report's, such as 29 rather than 28 for 29 killed out of 100.

```bash
jq -nR 'def key: [.path, .mutationOperatorId, .line, .column, .occurrence] | tojson; reduce (inputs | fromjson?) as $line ({}; if $line.kind == "mutant" then .[$line | key] = $line.outcome elif $line.kind == "retired" then reduce ($line.keys[] | key) as $retired (.; del(.[$retired])) else . end) | [.[]] | (map(select(. == "failed" or . == "runtimeError")) | length) as $killed | (map(select(. != "buildError")) | length) as $scored | {results: length, killed: $killed, score: (if length == 0 then -1 elif $scored > 0 then ($killed / $scored * 100 | floor) else 0 end)}' results.jsonl
```

Each mutant's line that counts, as the report reads them: its last `mutant` line, unless a later `retired` line dropped its key. They go into `latest.jsonl`, one a line, which the recipes at the top can read in place of `results.jsonl`:

```bash
jq -cnR 'def key: [.path, .mutationOperatorId, .line, .column, .occurrence] | tojson; reduce (inputs | fromjson?) as $line ({}; if $line.kind == "mutant" then .[$line | key] = $line elif $line.kind == "retired" then reduce ($line.keys[] | key) as $retired (.; del(.[$retired])) else . end) | .[]' results.jsonl > latest.jsonl
```
