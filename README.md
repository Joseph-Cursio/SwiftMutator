# SwiftMutator

[![CI](https://github.com/Joseph-Cursio/SwiftMutator/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Joseph-Cursio/SwiftMutator/actions/workflows/ci.yml)

Automated [mutation testing](https://en.wikipedia.org/wiki/Mutation_testing) for Swift.

SwiftMutator is based on [Muter](https://github.com/muter-mutation-testing/muter) by the Muter
contributors, and keeps its history. Muter introduces small changes (*mutants*) into your
code, such as `==` becoming `!=` or a call being removed, and runs your tests against each one.
A mutant your tests don't catch shows a behavior your tests don't check. The mutation score is
the share of mutants caught.

## Why a separate project

Muter's last release is 16 (September 2023). On current toolchains its `main` branch reports a
0% score for SwiftPM projects ([muter#307](https://github.com/muter-mutation-testing/muter/issues/307)),
and fixes wait months for review. SwiftMutator starts from Muter's `main` and adds:

- **Mutants that actually apply:** schemata keyed by stable source position, nested blocks kept,
  ternary swaps that don't corrupt code, and simulator, PATH and module-cache fixes (from
  [muter#309](https://github.com/muter-mutation-testing/muter/pull/309), by John Marshall).
- **Parallel workers:** `mutationTestWorkers: N` tests N mutants at once on SwiftPM projects,
  each in its own APFS clone of the mutated project.
- **A default timeout:** without `mutationTestTimeout`, a mutant's test run stops after 3× the
  baseline (at least 10 s), so a mutant that loops forever can't hang the run.
- **Logging through the injected printer**, so log output can be captured and tested.

Fixes that apply to Muter are offered upstream too.

## Build and run

```bash
swift build -c release --product swift-mutator
.build/release/swift-mutator init      # writes muter.conf.yml in the current project
.build/release/swift-mutator run       # runs mutation testing
```

`make install` installs `swift-mutator` into `/usr/local/bin`.

## Configuration

SwiftMutator reads Muter's `muter.conf.yml`, so existing Muter configurations work unchanged.
The options are documented in [Muter's README](Docs/Muter-README.md#configuration-options);
SwiftMutator adds:

| Key | Meaning |
|---|---|
| `mutationTestWorkers` | How many mutants to test at once (SwiftPM projects only; default 1) |
| `mutationTestTimeout` | Seconds before a mutant's test run is stopped (default: 3× the baseline, at least 10) |

## Development

`make test` runs the unit tests (the `muterTests` target). CI runs them on every pull request
and every push to `main`, on two Xcode versions (see [ci.yml](.github/workflows/ci.yml)).
[CONTRIBUTING.md](CONTRIBUTING.md) covers the acceptance and regression tests, which CI doesn't
run.

## License

MIT, as Muter is. See [LICENSE](LICENSE).
