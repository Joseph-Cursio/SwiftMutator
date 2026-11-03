# The test plan

`swift-mutator mutate-without-running` copies the project to `<project>_mutated` beside it, as `run` does, puts every mutant's switch into the copy, and writes the test plan, `muter-mappings.json`, in the project folder. It tests nothing. `swift-mutator run-without-mutating muter-mappings.json` then tests the copy's mutants. In between you can fix the copy by hand, for example code that the rewriting left unable to compile.

`mutate-without-running` takes `--files-to-mutate` and `--operators`, as `run` does, to choose which mutants the plan holds:

```
swift-mutator mutate-without-running --files-to-mutate Sources/Foo/Bar.swift --operators SwapTernary
```

The plan records them, and a run of the plan records them in its results file, as a run that finds its own mutants records the options it was given. When the plan is made, SwiftMutator says what it holds and what to run next:

```
💾 Mutation test plan created: /Users/me/Foo/muter-mappings.json (3 mutants in 1 file, operator SwapTernary)
✏️ You can fix its copy, ../Foo_mutated, by hand before testing it.
▶️ Test it: swift-mutator run-without-mutating /Users/me/Foo/muter-mappings.json
⚠️ A later `swift-mutator run` or `mutate-without-running` of this project removes that copy, and any fix in it.
```

## Where it is, and where to run it

- The plan is `muter-mappings.json` at the project's root. You can move or rename it: what it names is relative to the project folder, not to the plan.
- Its paths are relative, so the project and its copy can move together. The copy's path is relative to the folder the plan was made in, normally `../<project>_mutated`. Each mutant's file is relative to the copy, as `Sources/Foo/Bar.swift`. A copy that shares no folder with the project but the root, as on another volume, is named by its absolute path, and so is a file outside the copy.
- Run `run-without-mutating` in the project folder, as `mutate-without-running` was: the plan's copy is found from the folder the command runs in, which is also where it loads `muter.conf.yml`.
- A copy that moved can hold absolute paths in its `.build` folder or in Xcode's DerivedData, which still point to where it was. Remove the copy's `.build` after moving it.
- A later `swift-mutator run` or `mutate-without-running` of the project removes the copy, with any fix you made in it. A plan whose copy isn't there is refused (see [When a plan is refused](#when-a-plan-is-refused)).

## What's in it

The plan is one JSON object, pretty-printed with two spaces, its keys sorted, its slashes unescaped, and one line break at the end. Here is a plan with one mutant:

```
{
  "filesToMutate" : [

  ],
  "formatVersion" : 1,
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
  "mutatedProject" : "../Foo_mutated",
  "operators" : [
    "ChangeLogicalConnector",
    "RelationalOperatorReplacement",
    "RemoveSideEffects",
    "SwapTernary"
  ],
  "projectCoverage" : 72,
  "swiftMutatorVersion" : "0.1.0"
}
```

| Key | Type | What it is |
|---|---|---|
| `formatVersion` | Int | The plan's format: 1. See [Compatibility](#compatibility). |
| `swiftMutatorVersion` | String | The version of the SwiftMutator that made the plan. It is for you to read; SwiftMutator doesn't compare it. |
| `mutatedProject` | String | The copy, relative to the folder the plan was made in. |
| `projectCoverage` | Int | The project's code coverage, as a percentage. Left out when coverage wasn't gathered, as with `--skip-coverage`. |
| `operators` | [String] | The operators the mutants were chosen by, sorted: those `--operators` named, or every one. |
| `filesToMutate` | [String] | The files the mutants were chosen from, as `--files-to-mutate` gave them; empty when it wasn't given. |
| `mappings` | [Object] | Each file with mutants, sorted by path: its `filePath`, relative to the copy, and its mutants, in the order they are tested. |

Each mutant has:

| Key | Type | What it is |
|---|---|---|
| `id` | String | The ID the copy's code switches the mutant on by: the file's name without `.swift`, a hash of its path in the copy, the operator, `line`, `column` and `utf8Offset`, joined by `_`. SwiftMutator reads it as it is, so it still matches the code once the copy has moved. |
| `filePath` | String | The mutant's file, relative to the copy. |
| `mutationOperatorId` | String | The mutation operator. |
| `position` | Object | Where the mutant is in the original file: `line` and `column`, and `utf8Offset`, the byte offset in the file as SwiftMutator prepared it. |
| `snapshot` | Object | The code `before` and `after` the mutation, each on one line, and a `description` of it. |

The plan holds no date, host name, absolute path or hash of the SwiftMutator executable. So two plans of the same sources, made by the same version of SwiftMutator in project folders of the same name, are the same bytes, wherever the folders are. That holds on one platform: Foundation on Linux could lay the JSON out differently.

## Compatibility

- A format changes only for a change that a reader of the earlier one would misread. A new key needs none: readers ignore keys they don't know.
- **Format 0** is the plan SwiftMutators wrote before format 1: no `formatVersion`, `mutatedProjectPath` in place of `mutatedProject`, absolute paths throughout, a `projectCoverage` of -1 when coverage wasn't gathered, no `operators` or `filesToMutate`, and, from before the path hash, mutants without an `id`. This SwiftMutator still reads it. Its absolute paths are used as they are, wherever the command runs, and a run of it records every operator and no `--files-to-mutate`, as before. A `swift test` plan made before the active-mutant file is refused, as before: make it again.
- A plan in a **newer format** than this SwiftMutator reads is refused, with exit status 7.
- An **older SwiftMutator** can't read a format-1 plan: it stops on the missing `mutatedProjectPath` before it locks, builds or tests anything. Test a plan with the SwiftMutator that made it, or a newer one.

## When a plan is refused

`run-without-mutating` refuses a plan that might not describe the project, or can't be tested as it is. It tests nothing, says why and what would let the plan through, and exits with status 7:

- The plan is in a newer format than this SwiftMutator reads.
- The plan's copy isn't there. This is checked once the copy is locked, since another run of the project could be making it until then. Make the plan again with `swift-mutator mutate-without-running`.
