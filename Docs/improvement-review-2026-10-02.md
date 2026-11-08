# SwiftMutator improvement review: what's left

This review started on 2 October 2026, at commit `4ba72fc`, as a ranked list of ways to improve SwiftMutator. On 21 October it gained the gaps found by comparing SwiftMutator with swift-mutation-testing. It now covers only what isn't done.

- **Last updated on 8 November 2026,** at `5755b647`. Each item was checked against its issue and the code, and its line references brought up to date.
- **Done items were removed.** Git history keeps them: [this file at `5755b647`](https://github.com/Joseph-Cursio/SwiftMutator/blob/5755b647/Docs/improvement-review-2026-10-02.md) lists every finished item with its PR, and [at `44c1b41`](https://github.com/Joseph-Cursio/SwiftMutator/blob/44c1b41/Docs/improvement-review-2026-10-02.md) has the early write-ups.
- **Section numbers are the original ones,** so references in PRs and notes still work. A missing number is a finished section.
- **Open issues:** [#121], [#122], [#123], [#130], [#181] and [#230]. An item marked "no issue yet" is a known gap that no issue tracks.

---

## 1. Speed

### 1.1 Time before the test helper starts

On macOS, a mutant's Swift Testing bundles run directly with `swiftpm-testing-helper`, not through `swift test`. On SwiftProjectLint that cut the time before the first test from 1.26 s to 0.20 s ([#62], closed). Left (no issue yet):
- **Linux, and projects whose baseline runs XCTest tests,** still run `swift test` for each mutant. Direct runs exist on macOS only (`DirectTestRun.swift:32-33`), and a baseline that ran XCTest tests keeps `swift test`, the only thing that runs them (`PerformMutationTesting+DirectRuns.swift:61-62`). Neither case came up in the projects measured.

### 1.3 Skip mutants that no test reaches

Left:
- **An Xcode project's local packages** (no issue yet). xccov lists no files for a local package's library that an app or framework links, so the package's files count neither toward the percent nor as files without coverage (`XcodeBuildCoverage.swift:279-300`). Their regions are read, so a function no test runs still loses its mutants. On a probe framework with a local package, the percent counts only the framework's lines, and the package's file that no test runs isn't left out. Taking llvm-cov's lines for the project's files that xccov names in no target, and xccov's for the rest, would fix it without changing the counts PR #133 checked.
- **xcodebuild with parallel testing names no failed test** (no issue yet). Its lines are `Test case '…' failed on '…'`, the same for a crash (`XcodeBuildCoverage.swift:108-113`). So a test that fails only under coverage costs all of it there: the run goes on without coverage. Workers turn parallel testing off, and so does one worker on a simulator of its own, the default for 6 mutants or more on a simulator destination (PR #196). A lone worker that stays on the destination with parallel testing on still names no killing test: xcodebuild ends with `** TEST EXECUTE FAILED **`, so each mutant its tests kill is recorded as a runtime error, which is still a kill.

### 1.4 Do less work per run

- **`--shard` on a real project** (no issue yet). It hasn't been timed on SwiftProjectLint. The whole repo took 26.6 min on 31 October, with 4 workers and 2.3 min of setup ([release-and-workers-2026-10.md](release-and-workers-2026-10.md)). So each of two shards, on machines of their own, should take about (26.6 − 2.3) / 2 + 2.3 ≈ 14.5 min, 1.8× faster than one run.

---

## 2. Losing or mis-scoring a run

### 2.4 Discovery and target membership: what's left

Discovery takes a SwiftPM package's files from its targets, keeps only the files that the coverage data names ([#86]), and leaves out `#if` branches the run's build doesn't compile ([#114]). Left (no issue yet):
- **Runs without coverage.** With `--skip-coverage`, or when coverage fails, an xcodebuild project, a package tested through xcodebuild and a wrapper script are walked, and every target of a SwiftPM package and of its local packages is mutated, but test, plugin and snippet targets. So an example app or an unused target gets mutants no test can kill again. The target membership in an Xcode project file, or each product's targets in describe, would still say which files count.
- **Code that runs only in a process the tests start.** SwiftPM's coverage reads the test bundles (`SwiftCoverage.swift:193-197`), so a package's executable that its tests run with `Process` isn't in the data, nor is a library only it links, and their files aren't mutated, though such a test could kill their mutants. Discovery mutated them before it used the coverage data's files. Adding the executables the coverage run built as llvm-cov objects would bring them back, and count their lines.
- **Generated sources that git ignores.** An xcodebuild project's walk still leaves out a source that a build step generates and git ignores, even if a target compiles it, which discovery mutated before it skipped ignored paths. The coverage data names it, but a build step that regenerates it would overwrite its mutants.

---

## 4. Repo health

- **Releases** ([#121]). SwiftMutator has no release or tag on GitHub, and its version is fixed at 0.1.0 (`Sources/muterCore/version.swift`). The release tooling is still Muter's:
  - `make release` runs `Scripts/shipIt.sh` (`Makefile:18-19`), which downloads Muter's release archive, hashes it, and builds and installs a Homebrew formula for Muter.
  - `Scripts/bump_version.py` edits `homebrew-formulae/Formula/muter.rb`, and the `homebrew-formulae` submodule is Muter's formulae repository (`.gitmodules`).
  - The update check asks GitHub's API for SwiftMutator's latest release (`UpdateCheck.swift:30`) on every run not given `--skip-update-check`, and finds none. Cut a release, or make the check opt-in.
- **Linux** ([#130]). CI's Linux job builds SwiftMutator and runs the unit suite, but the suite fails there, so the job doesn't block: it runs with `continue-on-error`, on pushes to main and by hand, not on pull requests (`.github/workflows/ci.yml:161-170`). Its run on 8 November built and then failed its tests. Mutants there also run through `swift test` (§1.1).
- **xcodebuild workers: what's left** (no issue yet; [#103] is closed). Several workers test on simulator destinations only.
  - A failed check run on a simulator made with `simctl create`, because the destination's simulator was booted, doesn't say that shutting it down would let the next run clone it, with its settings and data.
  - macOS and Mac Catalyst destinations stay on 1 worker: their tests would share the Mac's `UserDefaults`, saved state and container (`MuterConfiguration.swift:515-535`).
  - The default worker count for xcodebuild is still 1, as each simulator takes about 3 GB at its peak (`MuterConfiguration.swift:496-502`). [#116] changed only SwiftPM's.
  - xcodebuild runs have no fail-fast: `stopAtFirstFailure` applies to SwiftPM only.

---

## 6. Gaps found by comparing with swift-mutation-testing

Added on 21 October, from a comparison with swift-mutation-testing v1.6.3 (`937f128`), checked against SwiftMutator `af38f174`. Left:

- **xcodebuild arguments in mutant runs** ([#123]). The user's `arguments` reach the build, the coverage run and the baseline, but a mutant's run gets only `test-without-building`, the first `-destination`, `-xctestrun` and a worker's own arguments (`MuterConfiguration.swift:817-830`). So an argument that changes what a test run does, such as `-only-testing`, holds for the baseline and maybe not for the mutants. The issue also proposes the flags a headless run needs.
- **Configuration checks and a smarter `init`** ([#122]). Report settings are done (`reports:`, [#119]). Left:
  - An unknown key in `muter.conf.yml` is dropped without a word, so a misspelled `mutationTestTimeout` leaves the default time limit.
  - Values aren't checked: the issue lists those that fall back to a default on a wrong type, or are taken out of range.
  - A run with no configuration file stops (`LoadConfiguration.swift:28`), rather than running with what `init` would write.
  - `init` replaces an existing file (`Init.swift:42-47`), writes a bare YAML dump, and guesses the scheme and destination.
- **Releases, a real version and an update check that works** ([#121]): see §4.

## Other open issues

These came after the review and have no section of their own.

- **The baseline's time counts time asleep or suspended** ([#181]). Every mutant's run is timed on the monotonic clock, less Ctrl-Z suspensions, but the baseline with `Date()`, and its time sets the default limit where there's no timed test run.
- **More `#if`s to decide** ([#230]): xcodebuild's per-file targets, a Swift package's scheme under xcodebuild, and `swift(…)` conditions. An `#if` that discovery can't decide keeps its mutants, which coverage can still leave out.

---

## Checked and not worth doing

- **One mutant per line.** On 2 October, 2,478 inserted mutants sat on 2,205 lines, so a cap would save at most 11%. That was before PR #25 inserted every mutant, but that run's 2,487 logs give the same 11%.
- **One long-lived test process for many mutants.** PR #13's per-process environment cache, and other static state that persists between mutants, make this unsafe.

## Outside this repo

- **Upstream Muter.** The fixes in PRs #25, #27, #49 and #52–#55 also apply to upstream Muter at `7f1f258`, and PR #26's once muter#309 and muter#312 are in. Each PR's body says how to port it. They're held until upstream's CI is green again.
- **`swift-quality`,** at dotfiles-claude `a5dcf5f`.
  - It prints `swift --version` (line 75) before it changes into the project folder (line 80), so its header can name the wrong toolchain.
  - Add start and end timestamps to `summary.txt`.
  - Copy the "Mutation Score without suspect tests" and "Suspect tests" lines into `summary.txt`. Anchor the killed-count `grep` (line 214) to the line that starts "Of the".
  - Drop `--skip-coverage` (line 211), now that coverage works with several test bundles (PR #60), so runs leave out the mutants no test runs.
  - It removes `${repo}_mutated` by name (line 213), so it misses the copy, `${repo}_mutated.noindex` ([#104]). SwiftMutator's next run of the repo still removes either name.

[#62]: https://github.com/Joseph-Cursio/SwiftMutator/issues/62
[#86]: https://github.com/Joseph-Cursio/SwiftMutator/issues/86
[#103]: https://github.com/Joseph-Cursio/SwiftMutator/issues/103
[#104]: https://github.com/Joseph-Cursio/SwiftMutator/issues/104
[#114]: https://github.com/Joseph-Cursio/SwiftMutator/issues/114
[#116]: https://github.com/Joseph-Cursio/SwiftMutator/issues/116
[#119]: https://github.com/Joseph-Cursio/SwiftMutator/issues/119
[#121]: https://github.com/Joseph-Cursio/SwiftMutator/issues/121
[#122]: https://github.com/Joseph-Cursio/SwiftMutator/issues/122
[#123]: https://github.com/Joseph-Cursio/SwiftMutator/issues/123
[#130]: https://github.com/Joseph-Cursio/SwiftMutator/issues/130
[#181]: https://github.com/Joseph-Cursio/SwiftMutator/issues/181
[#230]: https://github.com/Joseph-Cursio/SwiftMutator/issues/230
