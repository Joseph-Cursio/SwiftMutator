# Contributing to SwiftMutator

SwiftMutator is a fork of [Muter](https://github.com/muter-mutation-testing/muter), with one
maintainer. Contributions are welcome. This page says how to find work, set up a toolchain, test a
change and get it merged. [Docs/Architecture.md](Docs/Architecture.md) says how the code is laid
out.

## Finding something to work on

- The [open issues](https://github.com/Joseph-Cursio/SwiftMutator/issues). None are pinned.
- The [improvement review](Docs/improvement-review-2026-10-02.md), which lists known gaps and
  what each would take.

Before you start on something big, say so on its issue, or open one. That way two people don't do
the same work, and you can agree on the approach first.

## Asking for a feature or reporting a bug

Open an [issue](https://github.com/Joseph-Cursio/SwiftMutator/issues). For a feature, say what you
want to do and what stops you now. Examples and links to other tools that do it help. For a bug,
give the command you ran, your `muter.conf.yml`, SwiftMutator's output, and the version it prints
when it starts.

Report a security problem privately instead: see [SECURITY.md](SECURITY.md).

## Toolchain

`Package.swift` targets macOS 13 or later. To build and test SwiftMutator on a Mac, you need:

- **Xcode 26.6 or later.** Its Swift 6.3 is the oldest toolchain CI tests. Xcode 27 (Swift 6.4)
  is the current one, and what the maintainer's Macs use. `Package.swift` says tools version 6.0,
  but one dependency, swift-crypto, needs Swift 6.2 just to load its manifest, so nothing older
  resolves the package.
- **Xcode itself, not only the Command Line Tools,** for everything but the unit tests. The
  acceptance tests need an iOS simulator: they run on an iPhone simulator of the sample
  `ExampleApp`, so install an iOS runtime in Xcode's settings. The regression tests run xcodebuild
  on two sample projects.
- **SwiftLint 0.65.1**, the version CI runs (`brew install swiftlint` gets the latest, which may
  find more).

Pick the Xcode with `xcode-select`, or with `DEVELOPER_DIR` for one shell, as CI does:

```
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
swift --version
```

The tests of the generated code compile it with `/usr/bin/xcrun swiftc`, so they use the selected
Xcode's compiler, whichever `swift` is on your `PATH`. One of them builds with
`-default-isolation MainActor`, and skips itself on a compiler older than Swift 6.2, which lacks
it.

[swiftly](https://www.swift.org/install/macos/swiftly/) can install another Swift toolchain, for
`swift build` and `swift test`. CI doesn't use it, and this page wasn't checked with it. The
improvement review's runs used swiftly's Swift 6.3.3, with `SDKROOT` set to the Command Line
Tools' `MacOSX26.5.sdk`. The acceptance and regression tests still need Xcode.

Linux: the package builds with Swift 6.4 (`swift:6.4-noble`), but some unit tests fail there.
[#130](https://github.com/Joseph-Cursio/SwiftMutator/issues/130) tracks that.

## Building and testing

```
swift build          # debug build
make test            # the unit tests: swift test --filter 'muterTests'
swiftlint lint
../SwiftLintConfig/scripts/swiftlint-analyze.sh   # the analyzer rules
```

SwiftLint's rules come from the shared configuration in `../SwiftLintConfig`, which must be
checked out next to this repository; `.swiftlint.yml` lists only this package's paths.

`make test` runs only the `muterTests` target. A plain `swift test` also runs the acceptance and
regression targets. Their tests read samples that the scripts below generate, and they skip
themselves while the `samples` folder doesn't exist. Once a script has run, they run too, and fail
if what it generated is missing or wrong. While you work, run the tests you touch with
`swift test --filter <TestClass>`, then the whole unit suite before you open a pull request.

Snapshot tests compare against files in `__Snapshots__` folders. When a change means to alter
output, update the snapshot file and check the diff. Don't loosen the test.

`make project` opens the package in Xcode (`xed .`). You can run the unit tests there. Don't run
the acceptance or regression targets from Xcode: they depend on files the scripts generate.

### Package.resolved's pin for Swift 6.3

`Package.resolved` pins `xctest-dynamic-overlay` 1.13.1, which only Swift 6.3 uses, and Swift 6.4
drops that pin whenever it rewrites the file: `swift package update` or `resolve` does, and so can
`swift build` or `swift test`. Don't commit the file without it. Without the pin, CI's Xcode 26.6
job fails at "Resolve dependencies from Package.resolved". If only the pin went, take the change
back with `git checkout Package.resolved`.

Why: swift-custom-dump, which swift-snapshot-testing brings in, ships a second manifest,
`Package@swift-6.1.swift`, which Swift 6.1 to 6.3 read. It names swift-issue-reporting by its old
name, `xctest-dynamic-overlay`, at 1.x. Swift 6.4 reads the `Package.swift` beside it, which wants
swift-issue-reporting 2.x. Each toolchain uses the pin its manifest needs and ignores the other
([#164](https://github.com/Joseph-Cursio/SwiftMutator/pull/164)). After a dependency update, put
the pin back if it went, and check that `swift package resolve --force-resolved-versions` leaves
the file alone under both Xcode 26.6 and Xcode 27. The pin can go once swift-custom-dump stops
shipping its 6.1 manifest, or CI stops testing Xcode 26.6.

### Acceptance and regression tests

```
make acceptance-test     # needs an iOS simulator
make regression-test
```

Each first runs `make build`, an incremental debug build. `make clean` removes `.build` if you
need to build from scratch, after changing Xcode for one. The acceptance script
copies `Repositories/` into `AcceptanceTests/` and runs the debug `swift-mutator` on the iOS
sample `ExampleApp` several ways, saving the output in `AcceptanceTests/samples`. The regression
script runs it on BonMot, FFCParserCombinator and ProjectWithConcurrency in `Repositories/`. Then
each runs its test target, which checks the saved output. The regression script stops first at a
run that fails or writes no report, with that run's status or 1. The acceptance script stops, with
1, at a run that exits with any status but the one it expects: 0 for most, 255 for the project
with nothing to mutate, and 3 for the one whose baseline fails.

Run the acceptance tests when you change how a user runs SwiftMutator or what it prints. Run the
regression tests when you change the reports, which adding or changing an operator does. Run both
before a pull request that touches either. CI runs neither on a pull request, and runs both on
`main` once a day.

To re-record the regression snapshots, run `make regression-test`, read how each report in
`RegressionTests/samples` differs from its snapshot, delete the snapshots in
`RegressionTests/__Snapshots__/RegressionTests`, and run `swift test --filter 'RegressionTests'`.
That run fails as it records them, and the next passes.

### Slow acceptance tests

`make slow-acceptance-test` runs whole SwiftMutator runs on a pinned SwiftProjectLint and checks
every mutant's verdict against reference verdicts. It takes hours, so it isn't run for every pull
request. See [AcceptanceTests/slow/README.md](AcceptanceTests/slow/README.md), which also covers
`make slow-acceptance-reference` and `make slow-acceptance-selftest`.

### Mutation testing SwiftMutator itself

SwiftMutator can test itself, with the `muter.conf.yml` at the repository's root, which runs
`swift test --filter muterTests`. To use the code you're working on:

```
make install prefix=$(brew --prefix)
make mutation-test
```

`make install` builds a release `swift-mutator` and installs it into `$(prefix)/bin`, which is
`/usr/local/bin` by default. `make mutation-test` runs the `swift-mutator` on your `PATH`. It
leaves your `.build` alone. Removing it first gave the same results and saved no time, as the
copied build files aren't reused in the copy. There is no Homebrew formula for SwiftMutator, so that's the
one you installed. `make uninstall` removes it. To tell a development build from another, change
the version in [Sources/muterCore/version.swift](Sources/muterCore/version.swift) locally, but
don't commit it.

## Continuous integration

GitHub Actions ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs on every pull request
and every push to `main`:

- **Unit tests** on `macos-26` with Xcode 26.6 (Swift 6.3), and on `xcode-27` with Xcode 27.0
  (Swift 6.4). Each builds the package and its tests, then runs `swift test --filter
  '^muterTests\.'`, with snapshots never recorded. The first is one Swift release and one macOS
  release behind the current ones, so a failure only there usually means code that needs the
  newest toolchain. GitHub still calls the `xcode-27` image a preview. Each job restores `.build`
  as the last push to `main` left it, for the same toolchain and `Package.resolved`, so the
  dependencies aren't built again. Only pushes to `main` save it.
- **SwiftLint**, in SwiftLint's own 0.65.1 container, with the rules `.swiftlint.yml` takes from
  `../SwiftLintConfig`.
- **SwiftLint analyzer**, on `xcode-27` with SwiftLint 0.65.1: the shared config's analyzer
  rules, which need a compiler log, through
  [Scripts/ci-swiftlint-analyze.sh](Scripts/ci-swiftlint-analyze.sh). Any finding fails it, and
  so does a file SwiftLint couldn't analyze. On a pull request, `unused_import` looks only at
  the Swift files the pull request changes, as it takes 45 minutes or more over every file. A
  push to `main` runs it over every file. The other rules always look at every file. To run
  them all locally, use `../SwiftLintConfig/scripts/swiftlint-analyze.sh`.
- **Unit tests on Linux**, Swift 6.4, only on pushes to `main` and by hand, and never blocking
  ([#130](https://github.com/Joseph-Cursio/SwiftMutator/issues/130)).

A pull request can't be merged into `main` until both macOS unit-test jobs and SwiftLint pass. A
ruleset on `main` requires them. It doesn't require the branch to be up to date with `main`, and
the maintainer can bypass it. It names the jobs, so a change of runner or Xcode, which renames a
job, needs the ruleset changed too.

[.github/workflows/regression-tests.yml](.github/workflows/regression-tests.yml) runs
`make regression-test` on `main` once a day and by hand, on `xcode-27`, in about 15 minutes.
[.github/workflows/acceptance-tests.yml](.github/workflows/acceptance-tests.yml) runs
`make acceptance-test` the same way, on `macos-26` with Xcode 26.6, in about 30 minutes; on
`xcode-27` it took twice as long. Neither runs on a pull request, so neither blocks anything. If one
fails, the run's summary lists the failed tests, or the run of SwiftMutator that exited with the
wrong status, and the reports or samples, mismatched snapshots and logs are attached to the run. A
failed regression run means the reports on `main` no longer match the snapshots.

So run the acceptance and regression tests locally before a pull request that calls for them. If a
unit-test job fails,
the run's summary lists the errors and failing tests, and the full logs and any mismatched
snapshots are attached to the run. SwiftLint's violations show as annotations on the pull
request's files.

## Pull requests

1. Fork [Joseph-Cursio/SwiftMutator](https://github.com/Joseph-Cursio/SwiftMutator), and work on
   a branch of your fork, cut from `main`. Branches here are named `<kind>/<name>`, where the kind
   is one of `fix`, `feat`, `docs`, `perf`, `test`, `ci` and `chore`.
2. Add or update tests for every change in behavior, and docs for every change a user sees.
3. Run the unit tests and SwiftLint, and the acceptance and regression tests if the change calls
   for them.
4. Open a pull request against `main`. The template asks what changed and why, the issue it
   closes, and what you tested.

Pull requests are merged with a merge commit, not squashed or rebased. To bring yours up to date,
merge `main` into it or rebase it on `main`, whichever you prefer. Ask on the pull request if a
conflict is unclear.

## Swift Package Index

[.spi.yml](.spi.yml) holds the [Swift Package Index](https://swiftpackageindex.com)'s build
settings. SPI tries every platform for its compatibility matrix by itself. The file only pins how
it builds on macOS: with SwiftPM. The package isn't listed there yet. The maintainer has to
submit it first.

## Testing philosophy

SwiftMutator is a testing tool, so its own tests need to be thorough. Most of its code was
written test first. A change shouldn't lower its coverage or its mutation score.

A pull request that adds a feature or fixes a bug without new or updated tests won't be merged.
If you're unsure how to test something, ask on the issue before you write it, and we'll work it
out together.

## Code of conduct

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
