# The test plan

`swift-mutator mutate-without-running` copies the project to `<project>_mutated.noindex` beside it, as `run` does, puts every mutant's switch into the copy, and writes the test plan, `muter-mappings.json`, in the project folder. It tests nothing. `swift-mutator run-without-mutating muter-mappings.json` then tests the copy's mutants. In between you can fix the copy by hand, for example code that the rewriting left unable to compile.

`mutate-without-running` takes `--files-to-mutate`, `--operators` and `--skip-operators`, and follows the `operators` and `skipOperators` keys, as `run` does, to choose which mutants the plan holds:

```
swift-mutator mutate-without-running --files-to-mutate Sources/Foo/Bar.swift --operators SwapTernary
```

The plan records them, and a run of the plan records them in its results file, as a run that finds its own mutants records the options it was given. When the plan is made, SwiftMutator says what it holds and what to run next:

```
💾 Mutation test plan created: /Users/me/Foo/muter-mappings.json (3 mutants in 1 file, operator SwapTernary)
✏️ You can fix its copy, ../Foo_mutated.noindex, by hand before testing it.
▶️ Test it: swift-mutator run-without-mutating /Users/me/Foo/muter-mappings.json
⚠️ A later `swift-mutator run` or `mutate-without-running` of this project removes that copy, and any fix in it.
```

A plan's run tests its copy as it is, so it doesn't take [mutants that don't compile](../README.md#mutants-that-dont-compile) out of the build, as a run that finds its own mutants does: one stops the run at its build, at the baseline with exit status 3, or for xcodebuild in its build for testing with 255. Fix it in the copy, or make the plan again without its operator.

## Where it is, and where to run it

- The plan is `muter-mappings.json` at the project's root. You can move or rename it: what it names is relative to the project folder, not to the plan.
- Its paths are relative, so the project and its copy can move together. The copy's path is relative to the folder the plan was made in, normally `../<project>_mutated.noindex`. Each mutant's file is relative to the copy, as `Sources/Foo/Bar.swift`. A copy that shares no folder with the project but the root, as on another volume, is named by its absolute path, and so is a file outside the copy.
- Run `run-without-mutating` in the project folder, as `mutate-without-running` was: the plan's copy is found from the folder the command runs in, which is also where it loads `muter.conf.yml`. The configuration is loaded first: in a folder without `muter.conf.yml`, as the project's `Sources`, and without `--configuration`, the run stops on the missing file, with exit status 255, before it reads the plan. A run in a folder with a configuration that holds none of the files the plan mutates, nor any other file the plan recorded beside them, is refused (see [When a plan is refused](#when-a-plan-is-refused)).
- A copy that moved can hold absolute paths in its `.build` folder or in Xcode's DerivedData, which still point to where it was. Remove the copy's `.build` after moving it.
- A later `swift-mutator run` or `mutate-without-running` of the project removes the copy, with any fix you made in it. A plan whose copy isn't there is refused (see [When a plan is refused](#when-a-plan-is-refused)).

## What's in it

The plan is one JSON object, pretty-printed with two spaces, its keys sorted, its slashes unescaped, and one line break at the end. Here is a plan with one mutant:

```
{
  "filesToMutate" : [

  ],
  "formatVersion" : 2,
  "mappings" : [
    {
      "filePath" : "Sources/Foo/Bar.swift",
      "mappings" : [
        {
          "filePath" : "Sources/Foo/Bar.swift",
          "id" : "Bar_1a2b3c4d5e6f7081_SwapTernary_12_9_412",
          "mutationOperatorId" : "SwapTernary",
          "position" : {
            "column" : 9,
            "line" : 12,
            "utf8Offset" : 412
          },
          "snapshot" : {
            "after" : "a ? c : b",
            "before" : "a ? b : c",
            "description" : "swapped ternary operator"
          }
        }
      ]
    }
  ],
  "mutatedFiles" : {
    "Sources/Foo/Bar.swift" : "9f2c…"
  },
  "mutatedProject" : "../Foo_mutated.noindex",
  "operators" : [
    "ChangeLogicalConnector",
    "NegateConditional",
    "RelationalBoundary",
    "RelationalOperatorReplacement",
    "RemoveSideEffects",
    "SwapTernary"
  ],
  "projectCoverage" : 72,
  "sources" : {
    "excluded" : [
      "muter.conf.yml"
    ],
    "files" : {
      "Package.swift" : "5b0e…",
      "Sources/Foo/Bar.swift" : "e3a1…",
      "Tests/FooTests/BarTests.swift" : "07d4…"
    },
    "listedBy" : "git",
    "treeSHA256" : "c81f…"
  },
  "swiftMutatorVersion" : "0.1.0"
}
```

| Key | Type | What it is |
|---|---|---|
| `formatVersion` | Int | The plan's format: 2. See [Compatibility](#compatibility). |
| `swiftMutatorVersion` | String | The version of the SwiftMutator that made the plan. It is for you to read; SwiftMutator doesn't compare it. |
| `mutatedProject` | String | The copy, relative to the folder the plan was made in. |
| `projectCoverage` | Int | The project's code coverage, as a percentage. Left out when coverage wasn't gathered, as with `--skip-coverage`. |
| `operators` | [String] | The operators the mutants were chosen by, sorted: what `--operators`, `--skip-operators` and the `operators` and `skipOperators` keys left, or every one. |
| `filesToMutate` | [String] | The files the mutants were chosen from, as `--files-to-mutate` gave them; empty when it wasn't given. |
| `sources` | Object | The project's own files when the plan was made, before any was rewritten, which a run of the plan checks the project against: `files`, each file's SHA-256 by its path relative to the project; `excluded`, the paths left out, such as `muter.conf.yml`; `listedBy`, `git`, or `walk` outside a repository; and `treeSHA256`, over them all. They are found as a run's results file records them (see [The results file](results-file.md)). |
| `mutatedFiles` | Object | The SHA-256 of each file with mutants as the plan left it in the copy, by its path relative to the copy. A run of the plan names the files that differ, as after a fix by hand, and tests them as they are; it never refuses them. |
| `linkedFiles` | Object | The SHA-256 of what each file with mutants that is a symbolic link in the project held when the plan was made, by its path relative to the project: `sources` records only where such a link points. Left out when no file with mutants is a link. |
| `mappings` | [Object] | Each file with mutants, sorted by path: its `filePath`, relative to the copy, and its mutants, in the order they are tested. |

Each mutant has:

| Key | Type | What it is |
|---|---|---|
| `id` | String | The ID the copy's code switches the mutant on by: the file's name without `.swift`, a hash of its path in the copy, the operator, `line`, `column` and `utf8Offset`, joined by `_`. SwiftMutator reads it as it is, so it still matches the code once the copy has moved. |
| `filePath` | String | The mutant's file, relative to the copy. |
| `mutationOperatorId` | String | The mutation operator. |
| `position` | Object | Where the mutant is in the original file: `line` and `column`, and `utf8Offset`, the byte offset in the file as SwiftMutator prepared it. |
| `snapshot` | Object | The code `before` and `after` the mutation, each on one line, and a `description` of it. |

The hashes are shortened here. The plan holds no date, host name, absolute path or hash of the SwiftMutator executable. So two plans of the same sources, made by the same version of SwiftMutator in project folders of the same name, are the same bytes, wherever the folders are. That holds on one platform: Foundation on Linux could lay the JSON out differently.

## Compatibility

- A format changes only for a change that a reader of the earlier one would misread. A new key needs none: readers ignore keys they don't know.
- **Format 0** is the plan SwiftMutators wrote before format 1: no `formatVersion`, `mutatedProjectPath` in place of `mutatedProject`, absolute paths throughout, a `projectCoverage` of -1 when coverage wasn't gathered, no `operators`, `filesToMutate`, `sources` or `mutatedFiles`, and, from before the path hash, mutants without an `id`. This SwiftMutator still reads it. Its absolute paths are used as they are, wherever the command runs, and a run of it records every operator and no `--files-to-mutate`, as before. With no `sources`, the project isn't checked against it: the run says so, and goes ahead. A `swift test` plan made before the active-mutant file is refused, as before: make it again.
- **Format 1** has format 2's keys. Its copy is named as SwiftMutators named it before the `.noindex` names, normally `../<project>_mutated`. This SwiftMutator reads it as before, and locks `<project>_mutated.lock` for its copy, the file the SwiftMutator that made it locks.
- **Format 2** names a copy whose name ends in `.noindex`, normally `../<project>_mutated.noindex`. The lock keeps the name it had, `<project>_mutated.lock`, but a SwiftMutator from before the `.noindex` names would lock `<project>_mutated.noindex.lock` for that copy, and a later `run` would then remove the copy while it tested in it. So such a SwiftMutator refuses a format-2 plan as a newer format, with exit status 7, before it locks anything.
- A plan in a **newer format** than this SwiftMutator reads is refused, with exit status 7.
- A SwiftMutator from **before format 1** can't read a format-1 or format-2 plan: it stops on the missing `mutatedProjectPath` before it locks, builds or tests anything. Test a plan with the SwiftMutator that made it, or a newer one.

## When a plan is refused

`run-without-mutating` refuses a plan that might not describe the project, or can't be tested as it is. It tests nothing, says why and what would let the plan through, and exits with status 7:

- The plan is in a newer format than this SwiftMutator reads.
- The folder the command runs in holds none of the files the plan mutates, nor any other file the plan recorded in the folders at the top of the project that hold them, as `Sources`, so it isn't the project the plan was made from. Run it in that project's folder. This is checked once the configuration is loaded: a folder without `muter.conf.yml`, and without `--configuration`, stops on that first, with exit status 255. A file at the top, as `Package.swift`, is in most projects, so it doesn't count. In the project, a file the plan mutates that was renamed or removed is a change like any other (see [When the project changed](#when-the-project-changed)).
- A file the plan mutates changed in the project since the plan was made, or was removed (see [When the project changed](#when-the-project-changed)).
- The plan's copy isn't there. This is checked once the copy is locked, since another run of the project could be making it until then, or when the folder the copy should be in isn't there either, so that it can't be locked. If the copy was moved, or the project without it, move the copy to where the message says. Otherwise make the plan again with `swift-mutator mutate-without-running`.

## When the project changed

`run-without-mutating` checks the project's own files against the plan's `sources` before it locks or reads anything in the copy. It never checks the copy against them: you may have fixed the copy by hand on purpose, and `run-without-mutating` checks every mutant's switch is still in the copy's code once it is locked. Its results file records the copy as it was tested, each file's SHA-256 in its header's `project`, and the plan it tested, by its path and SHA-256, in `testPlan` (see [The results file](results-file.md)).

- A file the plan mutates that changed, or was removed or renamed, refuses the plan. A file with mutants that is a symbolic link counts as changed when the file it points to changed. The copy holds the file as it was, so its mutants' places, and the reports' lines in the file, would describe code you no longer have. The message names each such file, up to 10, and the flags that let the changes through:

  ```
  SwiftMutator won't test the plan '/Users/me/Foo/muter-mappings.json': 1 file it mutates changed since `swift-mutator mutate-without-running` made it:
    - Sources/Foo/Bar.swift changed
  The plan's copy holds it as it was, so its mutants' places, and the report's lines in this file, would describe code you no longer have. Make the plan again, or test the copy as it is with:
    --plan-ignoring 'Sources/Foo/Bar.swift'
  Nothing was tested.
  ```

  Make the plan again, or give `--plan-ignoring <glob>` to test the copy as it is. The glob is matched against each path relative to the project, and `*` also matches `/`, so `--plan-ignoring 'Sources/*'` lets every change under `Sources` through. It can be given more than once. The run then says which changes it let through.
- A change to any other file, such as a test or `Package.resolved`, is only said, with or without `--plan-ignoring`: the copy holds the file as it was, and its mutants are tested with it. Make the plan again to test with the file as it is now.
- Only the files of the mutants the run tests count. With `--mutant`, a change to a file with the plan's other mutants is only said, as a file a run of those mutants would refuse.
- The plan itself, wherever in the project it is, and what a run leaves out of its results file's project files, such as the `-o` report and `muter.conf.yml`, are never changes.
- The check hashes every file of the project, as a run does when it records them, so it takes about as long.

## Resuming a run of the plan

`run-without-mutating` writes a results file as `run` does, and a stopped run of a plan is continued as a stopped run is (see [Resuming a run](../README.md#resuming-a-run)). Its summary ends with the command, which repeats the plan's path as you gave it, and any `--plan-ignoring`:

```
▶️ Continue: swift-mutator run-without-mutating muter-mappings.json --resume '/…/results.jsonl'
```

- Run it in the project folder, as any run of the plan.
- Every session checks the project against the plan, as the first one did (see [When the project changed](#when-the-project-changed)).
- The plan must be the one the run tested, byte for byte: the results file records its SHA-256. A plan whose bytes changed since, because it was edited, or made again from changed sources or with other options, is refused, with exit status 5, and no `--force-resume` lets it through: start a new run without `--resume`. A plan made again of the same sources is the same bytes (see [What's in it](#whats-in-it)), so it is the same plan, and the check of its copy, below, decides: making the plan again doesn't start the run afresh, and a fix by hand that it overwrote is a change of the copy. To start afresh, leave out `--resume`.
- The results are judged by the plan's copy, not by your project: the results file records the copy as each session tested it. Once the copy is locked, the resume compares it with the last session's. A file of the copy that changed since, as after a fix by hand, is refused with status 5, and the message names the flags that let it through:

  ```
  SwiftMutator won't resume the run in '/…/results.jsonl', so that no result is reused that this run might not reproduce:
    - 1 file of the test plan's copy, /Users/me/Foo_mutated.noindex, changed since the run's last session, as a fix by hand would: Sources/Foo/Bar.swift (changed).
      If it can't change any test's result: --resume-ignoring 'Sources/Foo/Bar.swift'
      Mutants in a changed source file are tested again either way.
  Nothing was copied or removed.
  ```

  With `--resume-ignoring`, the mutants in a changed file are tested again, and the other results kept, and the run says which files of the copy it let through:

  ```
  ⚠️ Results are reused although 1 file of the test plan's copy, /Users/me/Foo_mutated.noindex, changed (--resume-ignoring): Sources/Foo/Bar.swift
  ```
- Only the copy's own changes count. Its files are the ones the plan recorded and the last session tested, not the ones your project lists now, so a file you `git rm` in the project, or that another branch doesn't have, is still the copy's as it was. What SwiftMutator's build writes in the copy, which keeps it from one session to the next, is left out: for xcodebuild, its `-derivedDataPath` and `TestContents`. A `Package.resolved` the project didn't have when the plan was made, as one it ignores, is written by the copy's build: a change to it is only said, and the results are reused. Start the run again without `--resume` to test every mutant with the dependencies as they are resolved now.
- `run --resume` with the results file of a run of a plan is refused for that alone: it doesn't compare your project with the plan's copy.
- `--force-resume` works as it does for `run`. `--reuse` isn't offered for a plan.
- `run` can't resume a run of a plan, and `run-without-mutating` can't resume a run without one. Nor can a run of a plan by an earlier SwiftMutator, which recorded neither the plan nor its copy, be resumed.

## Testing one mutant of the plan

`run-without-mutating` with `--mutant` tests one of the plan's mutants on its own, as after a fix by hand meant to change its verdict:

```
swift-mutator run-without-mutating muter-mappings.json --mutant 'Bar.swift:12:9'
```

- It takes the mutant as `run --mutant` does, and prints its change, its tests' log, its verdict, and the command that runs its tests in the copy with it on (see [Testing one mutant](../README.md#testing-one-mutant)).
- It tests the plan's copy as it is, under the plan's lock, and never rewrites it: only the plan's list of mutants is narrowed to that one.
- The project is checked against the plan as for a whole run, but only that mutant's file can refuse it. Its change is shown from your project's file, or, when that file changed since the plan was made and `--plan-ignoring` let it through, or the plan doesn't record it, as a plan in format 0 doesn't, as the mutant records it.
- Its results file is a run of one mutant: no whole run resumes or reuses it, and `--resume` can't be given with `--mutant`.
- `run --mutant` makes a copy of its own, `<project>_mutant.noindex`, so it never removes the plan's copy or a fix in it.
