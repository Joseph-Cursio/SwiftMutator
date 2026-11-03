# The results file

SwiftMutator saves each mutant's result as soon as its test run finishes, as one line of JSON in the run's log folder. A run that is stopped, killed or crashes keeps every result it finished, and you can read a run's results while it is still going. The report at the end is written as before and doesn't depend on this file. `swift-mutator report` makes a run's report from the file, in any format, at any time: see [Reports from the file](#reports-from-the-file). `swift-mutator run --resume` continues a stopped run from it, testing only the mutants without a result that still holds: see [Resuming a run](../README.md#resuming-a-run). `swift-mutator run --reuse` starts a new run from it, with a file of its own: see [Reusing an earlier run](../README.md#reusing-an-earlier-run).

## Where it is

- `<project>_muter_logs/<run>/results.jsonl`, next to your project, beside the run's kept logs. For example, `SwiftProjectLint_muter_logs/Oct 4, 2026 at 1:16 PM/results.jsonl`.
- The run's folder is named for the minute it started in. A run that starts in a minute that already has a folder gets one of its own, the same name followed by ` (2)`, then ` (3)` and so on, so a folder holds one run's logs. Should a folder already have a `results.jsonl`, the file is `results-2.jsonl`, then `results-3.jsonl`, up to `results-99.jsonl`. An existing file is never overwritten. While a run holds a results file, a hidden file beside it, `.results.jsonl.holder`, records which process holds it: see [How it is written](#how-it-is-written). `report`, `--resume` and `--reuse` ignore it.
- SwiftMutator prints the path when it creates the file ("SwiftMutator saves each mutant's result as it finishes, in …"). After the report it prints it again ("Each mutant's result is in …"), if every line was written. When mutation testing stops early, it prints it on standard error instead ("Each tested mutant's result is in …"), on the same condition. If a mutant has a result, the command that makes a report from the file follows it, with the path quoted for the shell: "Full report: swift-mutator report '…/results.jsonl'". Then comes the command that continues the run, which repeats SwiftMutator's own arguments but for an earlier `--resume`, `--reuse`, `--force-resume` and `--force-reuse`, with each `--reuse-ignoring` as a `--resume-ignoring`, and `--since`'s ref as the merge base it chose: "Continue: swift-mutator run … --resume '…/results.jsonl'". A run of a test plan's line repeats `run-without-mutating` and the plan's path as they were given, with any `--plan-ignoring`: "Continue: swift-mutator run-without-mutating muter-mappings.json --resume '…/results.jsonl'".
- `run --reuse` only reads the earlier run's file, and writes one of its own in its own log folder, as a first session does.
- `run --resume` adds a session to the file it continues, which stays where it is, in the first session's log folder. The new session prints the file's path as it starts testing, as a first session does. Its kept logs go to a log folder of its own, named for the minute it started in as any run's is, followed by ` (2)`, ` (3)` and so on if that minute already has one. So a later session's folder holds no results file, but a note, `resumed session.txt`, whose first line is the file's path, by itself. `report`, `--resume` and `--reuse` follow the note, so they take that folder as well as the file or the first session's folder. The note is written once the session's header and `retired` line are, so a resume whose baseline fails leaves none. A session that keeps no log, such as one that runs no coverage and has nothing left to test, still keeps its folder, with the note in it. A run that keeps nothing in its folder, such as a refused resume, leaves no folder.
- It is always written, and there's no option to turn it off. A line takes about 0.5–1 KB, so a run of 2,500 mutants writes an estimated 2–3 MB, beside well over a gigabyte of logs. The header's list of the project's files adds about 140 bytes a file: about 205 KB for a project of 1,450 files.
- `run` and `run-without-mutating` write one. `mutate-without-running` tests no mutants and writes none.

## What's in it

The file is [JSON Lines](https://jsonlines.org): UTF-8, one JSON object per line, each line ending in a line break. Every object has a `kind`:

1. **`header`**, once per session. A run's first session writes it when the baseline test run has passed, before the first mutant is tested, so a run whose baseline fails writes no file. A run that `--resume` continues adds a session to the same file, which starts with a header of its own on the same condition, so one whose baseline fails adds nothing. One with nothing left to test runs no baseline, and writes its header at once, as does a run that `--reuse` starts with nothing left to test and nothing changed since the earlier run.
2. **`retired`**, only in a resumed session, right after its header: the earlier results it no longer stands by. See [below](#retired).
3. **`mutant`**, one for each tested mutant, written as its test run finishes. With several workers, mutants finish in a different order from the one they started in. A session that tests on several workers then runs its timeouts again at lower load, and writes a second line for each, with `rerun`, which replaces the first. A run that `--reuse` starts first writes one for each result it keeps from the earlier run, right after its header, each with `reusedFrom`, and with `rerun` too for a result that a rerun gave.
4. **`end`**, last in each session. It is written when mutation testing stops: when it finishes, when an error stops it, and when Ctrl-C (SIGINT), SIGTERM or SIGHUP stops it (see [Stopping a run](../README.md#stopping-a-run)). A run that is killed with SIGKILL or crashes has no end line. Nor does one stopped at once, by a second signal or after 30 seconds of stopping, unless it had already written the end line.

Here is a header, three of a run's mutant lines, and the end line of a run that stopped after 1,103 mutants:

```
{"baselineSeconds":32.104,"configuration":{"arguments":["test","--skip","ParallelListDriftDogfoodTests"],"coverageThreshold":0,"exclude":[],"excludeCalls":[],"executable":"/Users/me/.swiftly/bin/swift","mutationTestWorkers":4},"failedTestLinesAreReliable":true,"filesToMutate":[],"formatVersion":1,"kind":"header","logDirectory":"/Users/me/code/SwiftProjectLint_muter_logs/Oct 4, 2026 at 1:16 PM","mutantsDiscovered":2497,"mutantsToTest":2497,"mutatedProjectPath":"/Users/me/code/SwiftProjectLint_mutated","newVersion":"","operators":["ChangeLogicalConnector","RelationalOperatorReplacement","RemoveSideEffects","SwapTernary"],"project":{"excluded":["mutation-report.partial.txt","mutation-report.txt"],"files":{"Package.swift":"d8e6cfa092102bced71ebe7272d359840b485d3327142a9e70b6bd44820cdbea","Packages/Core/Sources/Core/ExecutableTargetDetector.swift":"4452598a90734d67d923000920d537103f35f50f081e3725b0530f9dcb7ad52f","Packages/Core/Sources/Core/RuleRegistry.swift":"9cffc889f169316bfc58efb2aa7d036813cceb51b6328d3b4549e686034b7298","Packages/Core/Sources/Core/Walker.swift":"c09bd4febfd3fa9d9f30e1bdafe8d16fcffd723ddf1985a02aa8b9b567283db9","README.md":"b77adc82295d39069fd44b76ebf7c6f1c6c37ef0f9d0b0fe4927b6bec34c4e20"},"listedBy":"git","treeSHA256":"2ad7d4dc5bcf04035334eaf0af91884f5d1c063f5fa5b915d7e82223e39f17bb"},"projectPath":"/Users/me/code/SwiftProjectLint","provenance":{"arguments":["run","--skip-coverage","-o","mutation-report.txt"],"host":"studio.local","processIdentifier":81234,"swiftMutator":{"executablePath":"/usr/local/bin/swift-mutator","executableSHA256":"9f2c41d07b5e8a3c6e1f0d2b4a7c9e8f1d3b5a7c9e0f2d4b6a8c0e2f4d6b8a0c","version":"0.1.0"},"toolchain":{"environment":{"SDKROOT":"/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"},"testCommandVersion":"Apple Swift version 6.4 (swiftlang-6.4.0.1.2 clang-1800.0.1.1)\nTarget: arm64-apple-macosx27.0"}},"session":1,"skipCoverage":true,"startedAt":"2026-10-04T13:16:04.512Z","stopsAtFirstFailure":false,"testRunSeconds":10.75,"timeoutIsDefault":true,"timeoutSeconds":86,"usingTestPlan":false,"workers":4}
{"column":22,"durationSeconds":31.207,"endedBy":"exited","exitStatus":1,"failedTestCount":2,"fileSHA256":"4452598a90734d67d923000920d537103f35f50f081e3725b0530f9dcb7ad52f","finishedAt":"2026-10-04T13:18:02.118Z","firstFailedTestLine":"✘ Test detectsExecutableTargets() recorded an issue at ExecutableTargetDetectorTests.swift:41:9: Expectation failed: (targets.count → 0) == 1","killedBy":[{"location":"ExecutableTargetDetectorTests.swift:41:9","name":"detectsExecutableTargets()"},{"location":"ExecutableTargetDetectorTests.swift:58:9","name":"\"Skips test targets\""}],"kind":"mutant","line":73,"log":"RelationalOperatorReplacement @ ExecutableTargetDetector.swift-73-22 1202e16ea88d5e02.log","mutationOperatorId":"RelationalOperatorReplacement","occurrence":0,"outcome":"failed","path":"Packages/Core/Sources/Core/ExecutableTargetDetector.swift","session":1,"snapshot":{"after":"<","before":">","description":"changed > to <"},"switchID":"ExecutableTargetDetector_1202e16ea88d5e02_RelationalOperatorReplacement_73_22_3361","utf8Offset":3361,"worker":2}
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
| `formatVersion` | Int | 1 for a run's first session, and 2 for a resumed one, whose file can hold `retired` lines. See [Compatibility](#compatibility). |
| `session` | Int | 1 for a run's first session, then one more for each session `--resume` adds to the file |
| `startedAt` | Date | When mutation testing started. The run's test duration is measured from here. |
| `provenance` | Object | The SwiftMutator build and toolchain the run used. See [below](#provenance). |
| `configuration` | Object | The configuration as `muter.conf.yml` set it, under its own keys (`executable`, `arguments`, `exclude`, …), with `--workers` and `--timeout`, when given, as `mutationTestWorkers` and `mutationTestTimeout`. An `executable` given as a bare name, such as `swift`, is resolved to its full path. Optional settings that weren't set, such as `mutationTestTimeout`, are left out. |
| `operators` | [String] | The mutation operators used, by name, sorted |
| `filesToMutate` | [String] | The files given with `--files-to-mutate`, or `[]` |
| `skipCoverage` | Bool | Whether `--skip-coverage` was given |
| `usingTestPlan` | Bool | Whether the run tested a test plan (`run-without-mutating`). Only `run-without-mutating` resumes a run that did, and only `run` one that didn't. |
| `testPlan` | `{path, sha256, formatVersion, swiftMutatorVersion}` | Only in a session that tested a test plan: the plan's path as it was read, the SHA-256 of its bytes, which change when it is made again or edited, its format, and the SwiftMutator version that made it, left out for a plan from before plans recorded it. A resume of the run needs a plan with the same SHA-256. Results files from earlier SwiftMutators' `run-without-mutating` don't have it, so their runs can't be resumed. |
| `projectPath` | String | Your project |
| `mutatedProjectPath` | String | The mutated copy that SwiftMutator tested. Each mutant's `path` is relative to it. |
| `logDirectory` | String | The session's log folder, which holds its kept logs. A resumed session has a folder of its own, and adds to the file in the first session's folder. Its folder holds a note, `resumed session.txt`, naming the file, so it stays even when the session kept no log. |
| `coverage` | `{percent, filesWithoutCoverage}` | The project's coverage, as the report shows it. Left out when the run has none: coverage was skipped, isn't supported for the test command, or couldn't be gathered. |
| `newVersion` | String | The newer SwiftMutator version the update check found, or `""` |
| `baselineSeconds` | Double | How long the baseline test run took, build included. Left out by a resumed session with nothing left to test, which runs no baseline, and by a session that `--reuse` starts with nothing left to test and nothing changed. |
| `testRunSeconds` | Double | How long one run of a mutant's test command took with no mutant on, just after the baseline. The default time limit is based on it. Left out when no run was timed: `mutationTestTimeout` is set, the project isn't built with SwiftPM, the run didn't pass, or a resumed session, or one that `--reuse` started, had nothing left to test. |
| `timeoutSeconds` | Double | The time limit for each mutant's test run: `mutationTestTimeout`, or else the default. With `testRunSeconds` that is 5× it, once more for each worker beyond the first, and at least 20 s; without it, 3× `baselineSeconds`, and at least 10 s. Left out when neither is there: in a resumed session with nothing left to test, or one that `--reuse` started with nothing left to test and nothing changed, without `mutationTestTimeout`. A resume, or a reuse, whose `mutationTestTimeout` changed goes ahead only if it is at least the longest `timeoutSeconds` of the file's sessions, and then tests the timeouts of a session with a shorter one again. |
| `timeoutIsDefault` | Bool | Whether `mutationTestTimeout` wasn't set, so `timeoutSeconds` is the default |
| `workers` | Int | How many mutants were tested at once: `mutationTestWorkers`, but never more than the mutants to test, so 0 in a resumed session, or one that `--reuse` started, with nothing left to test |
| `stopsAtFirstFailure` | Bool | Whether a mutant's test run stopped at its first failed test |
| `failedTestLinesAreReliable` | Bool | False when the passing baseline printed a line that looks like a failed test or a crash. Such lines then don't show that a mutant was killed, so no mutant line has `killedBy`. |
| `mutantsDiscovered` | Int | How many mutants the run found. With `--sample`, how many of them the sample holds; `sample` gives the count it was taken from. With `--shard`, how many the shard holds, of the sample if there is one; `shard` gives the count in every shard. |
| `mutantsToTest` | Int | How many of them it set out to test: all of them in a run's first session, and fewer in a resumed one, or one that `--reuse` starts, which test only those without an earlier result that still holds. It is written before any mutant is tested, so it says nothing about how many were: that is the number of the session's `mutant` lines with neither `reusedFrom` nor `rerun`. |
| `project` | Object | Your project's files, each one's SHA-256, as SwiftMutator copied them, before it prepared any for mutation. See [below](#project). A run of a test plan (`run-without-mutating`) copies nothing, so its `project` is the plan's copy as it was tested: prepared for mutation, and with any fix you made in it by hand. A resume of the run compares the copy with it, never your project. Results files from earlier SwiftMutators' `run-without-mutating` don't have it. |
| `mutantsReused` | Int | Only in a resumed session: how many earlier sessions' results it kept rather than tested again. In a session that `--reuse` starts, how many of the earlier run's results it kept. |
| `waived` | [String] | Only in a resumed session: the project files that changed since the last session and that `--resume-ignoring` let through, by their paths relative to the project, or `[]`. In a session that `--reuse` starts, those that `--reuse-ignoring` let through since any of the earlier run's sessions. |
| `testBundlesRunDirectly` | Bool | Only when the session's mutants ran their test bundles directly, with `swiftpm-testing-helper`, rather than through `swift test`: `true` |
| `reusedFrom` | String | Only in a session that `--reuse` starts: the earlier run's results file |
| `since` | Object | Only in a session run with `--since`: what it chose, below |
| `shard` | Object | Only in a session run with `--shard`: which shard it tested, and what discovery found in every shard, below |
| `sample` | Object | Only in a session run with `--sample`: the sample asked for, and how many mutants it held of how many, below |
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

A run of a test plan lists them in your project too, and hashes each one in the plan's copy once it has locked it and checked its switches, just before it builds: the code the mutants are tested in. The plan file is left out, wherever in the project it is. If a file with mutants differs from what `mutate-without-running` left there, as after a fix by hand, the run says so ("✏️ 1 file of the plan's copy differs from what `swift-mutator mutate-without-running` wrote, and is tested as it is now: …"), and tests it as it is.

| Key | Meaning |
|---|---|
| `listedBy` | `git` or `walk`. `git`: `git ls-files --cached --others --exclude-standard`, run in your project, not in the copy. That lists tracked files, and untracked ones that neither your project's ignore files nor your global ones ignore. A nested repository or submodule is listed by its own git. `walk`: every file, when the project isn't in a git repository, is in a folder its repository ignores (where git lists none of its untracked files), or git fails. |
| `files` | Each file's SHA-256, by its path relative to the project. A symbolic link's is `link:` followed by the SHA-256 of the path it points to; it is never followed. A local package outside the project has its files under its path from the project, such as `../Core/Sources/Core/Core.swift`. |
| `excluded` | The `-o` report and its `.partial` sibling, which the run writes itself, and the configuration file it loads, such as `muter.conf.yml`, whose settings `configuration` records, when they are inside the project. They are left out of `files`: a resume compares the configuration key by key instead, so a change of `mutationTestWorkers`, `stopAtFirstFailure` or `buildTimeout` doesn't refuse it. |
| `treeSHA256` | The SHA-256 of every file's path, a NUL, its hash and a line break, sorted by path. Two trees with the same files and hashes have the same `treeSHA256`. |

- **Always listed**, even when git ignores them: Swift files (which include `Package.swift` and `Package@swift-*.swift`) and `.swift-version`, at any depth. `Package.resolved` too, but only at the root and in an Xcode project's or workspace's `xcshareddata/swiftpm/`.
- **Never listed:** anything in a `.build`, `.git`, `.swiftpm`, `DerivedData` or `xcuserdata` folder at any depth, and `.DS_Store` files. Nor are the files SwiftMutator itself writes at the project's root: `muter-mappings.json` and `muter.xctestrun`, and `.swiftmutator-active-mutant`, which earlier versions wrote there.
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
| `mutationOperatorId` | String | `RelationalOperatorReplacement`, `RemoveSideEffects`, `ChangeLogicalConnector` or `SwapTernary` |
| `switchID` | String | The ID that switched the mutant on: under `swift test`, the contents of the worker's active-mutant file, `<folder>.active-mutant` beside its folder; otherwise an environment variable of that name. It is the file's name without `.swift`, a hash of `path`, the operator, `line`, `column` and `utf8Offset`, joined by `_`. Only for diagnosis: repeats of one place and operator share one, and results files from before the hash, and runs of a test plan made before it, have no hash in it. |
| `utf8Offset` | Int | The mutant's offset in the file as SwiftMutator prepared it, which has lines SwiftMutator added at the top |
| `snapshot` | `{before, after, description}` | The code before and after the mutation, as the report shows it |
| `outcome` | String | `failed` (killed: a test failed), `runtimeError` (killed: the tests crashed), `passed` (survived), `timeout` (stopped at the time limit without showing a failure) or `buildError` |
| `endedBy` | String | How the test run ended: `exited` by itself; `timedOut`, stopped at the time limit; `stoppedAtFailedTest`, stopped at its first failed test (`stopAtFirstFailure`); `stoppedAtCrash`, stopped at a test process's crash before any failed test, also by `stopAtFirstFailure`, with `outcome` `runtimeError`; or `couldNotRun`, when its log couldn't be opened or its command couldn't start, and `outcome` is `buildError`. A cancelled run is never written, as its outcome says nothing about the mutant. |
| `exitStatus` | Int | Only for `exited`: the exit code, or the number of the signal that ended it |
| `durationSeconds` | Double | From the start of the mutant's test run to its outcome, to the millisecond |
| `worker` | Int | Where it ran: 0 is the mutated project, and n is its clone `<project>_mutated_worker<n>` |
| `finishedAt` | Date | When the line was written |
| `killedBy` | `[{name, location}]` | See [below](#killedby). Only for `failed`, `runtimeError` and `timeout`, and left out when `failedTestLinesAreReliable` is false. |
| `failedTestCount` | Int | With `killedBy`: how many different tests the log shows failing, without the limit of 20 |
| `firstFailedTestLine` | String | With `killedBy`: the first line that shows a failed test, without colour codes, cut to 500 characters. Left out when no line does. |
| `log` | String | The name of the mutant's kept log in its session's `logDirectory`: `<operator> @ <file name>-<line>-<column> <path hash>.log`, with ` (#2)`, ` (#3)` and so on before `.log` for a repeat. The hash is of `path`, as `switchID`'s is. So each mutant of a session keeps a log of its own, same-named files' mutants and repeats included. A line with `rerun` names the second run's log, with ` (rerun)` before `.log`, and the first run's line keeps naming its own. In results files whose log names have no hash, such mutants share a name, and only the last one tested kept its log. |
| `fileSHA256` | String | The SHA-256 of the mutant's file as SwiftMutator copied it, before it prepared it for mutation, or in a run of a test plan as the plan's copy held it when tested: the file's entry in the header's `project.files`. Left out when the header has no `project`, or the file isn't in it. |
| `reusedFrom` | `{resultsFile, session, despiteChanges}` | Only for a result that a session `--reuse` started kept rather than tested: the results file and session that tested it, and `despiteChanges` true when `--reuse-ignoring`, `--force-reuse`, `--resume-ignoring` or `--force-resume` let a change through since. Each of those sessions' headers says which (`waived`, `forced`). Everything else is as it was tested, but for `session`, `utf8Offset` and `switchID`, which are the reusing session's, and `log`, which names a copy of the log in its `logDirectory`. A result reused again keeps where it was first tested. |
| `rerun` | `{because, workers}` | On the line of a mutant that a session ran again: why, `timeout`, and how many mutants it ran at once meanwhile. A session that tests on several workers runs each of its timeouts again once every other mutant is tested, on a quarter of the workers, at least one, under the same time limit. The line follows the first run's, which it replaces by the last-line rule (see [Reading it](#reading-it)). A result that `--reuse` keeps keeps its `rerun`, as it keeps everything else it was tested with, though its own session didn't run it, so a session's own reruns are its lines with `rerun` and no `reusedFrom`. `because` is a string, so a later SwiftMutator may give another reason. |

#### `killedBy`

`killedBy` lists the tests the run's log shows failing, in the order they first failed, at most 20. A test that failed several times is listed once. Tests with the same name in different files are listed separately.

- **Swift Testing** names a test as it prints it: `sum()`, `"Adds two numbers"` (quotes included), or `Suite "Parsing"` for an issue a suite recorded itself. `location` is where the issue was recorded, such as `SumTests.swift:12:5`, and is left out if the line doesn't say.
- **XCTest** names a test `-[Module.Class testName]` and gives no `location`.
- **Lines that don't count:** known issues, warnings and SwiftMutator's own notes never name a test.
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

### `end`

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"end"` | |
| `session` | Int | The session it ends, as in its header |
| `endedAt` | Date | |
| `reason` | String | `finished`; `aborted`, stopped by an error; or `interrupted`, stopped by a signal |
| `detail` | String | Only when mutation testing stopped early. When `interrupted`: the signal that stopped it, `SIGINT` (Ctrl-C), `SIGTERM` or `SIGHUP`, so a Ctrl-C can be told apart from a `kill` or a closed terminal. When `aborted`: a short code for why. `tooManyBuildErrors` means 5 build errors in a row. `workerBaselineTestFailed(worker: n)` means a worker clone's baseline run didn't pass. `mutantNotSwitchedOn` means a mutant's run couldn't be told to switch it on: under xcodebuild, its `muter.xctestrun` couldn't be written. Any other error gives its type's name. It is never a log. |
| `testDurationSeconds` | Double | How long the session's mutation testing took. For a run's first session, the duration the report shows, before rounding. A resumed run's report shows every session's added up. |
| `recorded` | Int | How many `mutant` lines the session wrote, those with `reusedFrom` or `rerun` included. So it can be more than the mutants the session tested: count the lines with neither for those. |

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

- **Format 1** is a run's first session, also one that `--reuse` starts. A SwiftMutator from before `--reuse` reads the results such a session kept as tested in it.
- **A timeout run again** has a second `mutant` line for its key, so a SwiftMutator from before `rerun` takes that line for the mutant's result, by the last-line rule, and ignores `rerun`.
- **Format 2** is a resumed session. Its file can hold `retired` lines, and a reader that skipped them would report results the run no longer stands by, so a SwiftMutator from before `--resume` refuses the file. A file that was never resumed stays in format 1, which those read.

## Reports from the file

`swift-mutator report` makes a run's report from its results file, in any of the formats `run` writes:

```
swift-mutator report <results>… [-f plain|json|html|xcode] [-o <path>] [--force-merge] [--merge-ignoring <glob>]…
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
- **`-f`** chooses the format, as in `run`: `plain` (the default), `json`, `html` or `xcode`.
- **`-o`** saves the report at that path, replacing any file there.
  - The path is used exactly as given. A report of a stopped run isn't named `.partial`, as `run`'s partial report is, because you chose the name.
  - A path that would destroy what is there is refused before anything is printed: the results file itself, by any name (through a symbolic link, a hard link, or a different case on a case-insensitive volume), and a folder.

### What the report holds

The report is made from each mutant's last line (see [Reading it](#reading-it)) and the last header. The mutants come in the order the run tested and reported them, not the order they finished in. `report` works that order out the way discovery sorted them: files by their path in the mutated project (`path` under the header's `mutatedProjectPath`, or `path` itself for a file outside it), then each file's mutants by `line` and `column` as numbers, then by `mutationOperatorId`, and repeats of one place and operator by `occurrence`. Never by `utf8Offset`, which a resumed session's kept result holds as the session that tested it counted it.

- **A finished run** gets back the report it made itself, in every format, unless it is from before that order (below). The header holds the project paths, the coverage and the update notice the report shows, and the end line holds its exact test duration. Only what depends on when and where a report is made can differ:
  1. **The HTML footer** gives the time the report was made.
  2. **The Xcode format's warnings**, one for each survivor, come in the order the run tested the mutants. A run with several workers prints them as its mutants finish. The warnings are the same, and so is the summary.
  3. **The plain report's colours** are added when standard output is a terminal, unless `NO_COLOR` is set. The same rule applies to `run` and `report`, so the reports match when both write to a terminal, or neither does.
  4. **JSON keys** can come in a different order. The JSON is the same once it is parsed.
- **A run that was stopped by a signal or an error** gets a report of the mutants it tested, made the same way. It matches the partial report the run wrote beside its `-o`, if it wrote one, with the same four exceptions. The end line's `testDurationSeconds` gives the test duration.
- **A run with no end line**, which is still going, was killed or crashed, gets a report of the mutants it tested. The test duration runs from the header's `startedAt` to the last mutant's `finishedAt`.
- **A run stopped before any mutant finished** has no `mutant` lines, and gets an empty report: `Report of 0 of 2497 mutants`.
- **Lines that don't read** are skipped, as a reader should skip them, and the status says which.
- **A run by a SwiftMutator from before that order**, which sorted each file's mutants by `switchID` as text, gets them in line order. Its report listed them by operator, and line 10 before line 9.

**Killing tests.** The report names each mutant's tests from its line's `killedBy`, `failedTestCount` and `endedBy`. It works out the Killing Tests summary, the suspect tests and the score without them from those lines alone, the way the run does (see [Killing tests and suspect tests](../README.md#killing-tests-and-suspect-tests)). So a run and its `report` name the same tests and the same suspects.

- **Completeness** is judged mutant by mutant, as [`killedBy`](#killedby) says. So a file whose sessions ran with different `stopAtFirstFailure` settings gives each mutant's list the right verdict.
- **A resumed run** never tests a kill again. A list that a stopped run left short stays short.
- **No list** is recorded by a session whose header has `failedTestLinesAreReliable` false. Its kills name no tests, and its mutants don't count toward suspect tests.

The report doesn't say whether the run finished. The status on standard error does.

### Where the output goes

- **Standard output** holds the report alone, followed by a line break, when there's no `-o`. So `swift-mutator report <log folder> -f json > report.json` gives valid JSON. The Xcode format also prints its warnings there, before the report, with or without `-o`, as `run` does.
- **Standard error** says how many mutants the report covers, out of how many the run found, where the file is, and how the run ended. When the report has suspect tests, it then gives the warning a run ends with, without the emoji. With `-o`, it then says where the report was saved:

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

  The last session is always named, even when it tested none of them: `Of these, none were tested in the last session, session 2, and 2497 in session 1.` An earlier session with no result left in the report isn't named. A file of one session that kept nothing, and an empty report, get no such line.

  When lines were skipped, another line numbers them, and says when the last was cut off as it was written: `Skipped 1 line that didn't read: 812; the last was cut off as it was written.`

  The status has no emoji, so it can be searched for in CI logs. Numbers have no thousands separators.

### Exit status

- **0** when the report was made, an empty one included, unless the run stopped on an error.
- **255** when the report was made of a run that stopped on an error, its last session's end line `aborted`: the status the run itself exited with, so a script that checks the report fails as one that checked the run would. The report and the status come first, as for any other run. Shards' files exit with it whenever the report is known to lack results ([Shards](#shards)).
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

- **Compared:** every configuration key some outcome depends on; `operators`, `filesToMutate` and `skipCoverage`; `since`'s `mergeBase` and `changedLines`; and the SwiftMutator build, the toolchain and its environment. A difference in the build or the toolchain is let through by `--force-merge`, and nothing else is.
- **The project's files** are compared path by path, as a resume compares them, with what each shard left out, its `-o` report and the configuration file, taken out of both. `--merge-ignoring` lets files that differ through, by glob, as `--resume-ignoring` does.
- **Mutants:** none may have a result in two files. Shards that discovered the same mutants, by `allKeysSHA256`, must have split them alike, by `mutantsPerShard`.

Every reason found is given at once, with exit status 1, and no report is made.

The report is made from every shard's results, each its file's last line for the key, as for a single file. The mutants come in the order a whole run tests them, under the reference shard's `mutatedProjectPath`. The reference shard's last header gives the project paths, the coverage, `since`, `sample` and the update notice. The test duration is the longest shard's, as the shards are meant to run at once, and each shard's adds up its own sessions. When every shard that holds mutants is given, the report stands for the whole run, and has no `shards`. Otherwise its `shards` names the shards given, and the plain and HTML reports say that only their mutants were tested.

Standard error says, for one shard's file alone, what it says of any file, naming the shard: `Report of 1228 of 1228 mutants in shard 1 of 2, from …: the run finished.` For several:

```
Report of 2460 of 2463 mutants, merged from the results files of 2 of 2 shards.
Shard 1 of 2, 1228 of its 1228 mutants, from …/results.jsonl: the run finished.
Shard 2 of 2, 1232 of its 1235 mutants, from …/results.jsonl: the run was interrupted by SIGINT.
```

- The first line's total is `mutantsInAllShards`. If the shards' `allKeysSHA256` differ, their discoveries did, as when coverage differed between the machines: the line gives no total, and another says how many mutants in all each shard's run discovered.
- A shard whose file isn't given is named with the mutants `mutantsPerShard` gives it: `No results file was given for shard 2 of 3, which holds 812 mutants.` A shard that holds none wrote no file, and is said to: `Shard 3 of 3 holds no mutant, so it has no results file.`
- Which sessions tested a file's results, and lines skipped in it, are said for its shard, after its own line: `In shard 2 of 2's file: of these, 300 were tested in the last session, session 2, and 932 in session 1.` The first line gives no such count, as the shards' sessions differ.
- What `--force-merge` and `--merge-ignoring` let through is said, as is a shard whose own sessions let changes through when it was resumed or reused, by their headers' `forced` or `waived`.

`report` exits with 255 whenever the report is known to lack results: any shard's last session stopped on an error; a shard has fewer results than its header's `mutantsDiscovered`, as one that was interrupted, killed or is still running has; or a shard that holds mutants has no file among those given. So a CI job that checks the merged report fails as one that checked every shard's run would. Discoveries that differ only warn: each shard has its own mutants' results.

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
