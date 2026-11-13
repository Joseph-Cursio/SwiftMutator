import Foundation

/// How a SwiftPM mutant's tests run without `swift test`: each test bundle by SwiftPM's own `swiftpm-testing-helper`,
/// one after another, given what `swift test --skip-build` gives it. `swift test` spends about a second of every run
/// before its first test starts, loading the package graph and planning the build it then skips: on SwiftProjectLint,
/// with three bundles, a run that matched no test took 1.26 s through `swift test` and 0.20 s this way (#62).
///
/// Only on macOS, and only for Swift Testing: `swift test` runs XCTest tests with `xctest`, once it has found which
/// bundles hold any, so a project whose baseline ran an XCTest test keeps `swift test`. Every mutant runs on the build
/// the baseline made, so what holds for one run with no mutant on holds for every mutant's: before the mutants, that
/// run must pass and run as many Swift Testing tests in each bundle as the baseline did (`whyNot`).
struct DirectTestRun: Equatable, Sendable {
    /// `swiftpm-testing-helper`, in the toolchain of the test command's `swift`.
    let helper: String
    /// The build's products folder, relative to the project, so each worker's clone runs its own build, unless
    /// `sharedBuild` names one for them all.
    let productsFolder: String
    /// The test bundles' names, in name order.
    let bundles: [String]
    /// The names of each bundle's test files, without `.swift`, from its test target's sources, for
    /// `bundles(forMutantIn:)`.
    let testFiles: [String: [String]]
    /// The macOS platform's `Developer` folder, whose frameworks the test bundles load XCTest and Swift Testing from.
    let platformDeveloperFolder: String
    /// What follows `test` in a mutant's `swift test` command, `--skip-build` included. `swift test` passes its own
    /// arguments to each helper, which reads the test filters among them and ignores the rest.
    let arguments: [String]
    /// The folder whose build, and whose copy of the project, every worker's runs use, when workers share one build
    /// rather than each have a clone (`sharingBuild(of:)`). Nil when each folder runs its own.
    var sharedBuild: URL?

    /// Why the bundles can't be run directly. A nil `reason` isn't worth telling: on Linux, say, or when `executable`
    /// isn't `swift` itself, as for a wrapper.
    struct Unavailable: Error, Equatable {
        let reason: String?
    }

    /// This run with `more` given to each helper after its own arguments, such as a test filter.
    func adding(_ more: [String]) -> Self {
        Self(
            helper: helper,
            productsFolder: productsFolder,
            bundles: bundles,
            testFiles: testFiles,
            platformDeveloperFolder: platformDeveloperFolder,
            arguments: arguments + more,
            sharedBuild: sharedBuild
        )
    }

    /// This run with every worker's runs starting in `project`, on its build. What else is a worker's own goes by its
    /// folder's name, which then needs no folder: its active-mutant file, helper link, `UserDefaults`, activation
    /// markers and temporary folder.
    func sharingBuild(of project: URL) -> Self {
        var copy = self
        copy.sharedBuild = project
        return copy
    }

    /// The `/bin/sh` script that runs each bundle in `folder`, the mutated project or a worker's clone, in the order
    /// `bundles(forMutantIn: filePath)` gives, and exits 1 if any helper failed. A helper killed by a signal is
    /// reported as `swift test` reports it, with a line that `TestSuiteOutcome` reads as a crash, and that stops a run
    /// that stops at its first failure (`CrashLine`). Every bundle runs, as under `swift test`, unless the run is
    /// stopped. A helper ended by SIGINT, SIGTERM or SIGHUP ends the script at once, with its status, so that a signal
    /// from outside SwiftMutator reads as one (`MutationTestingDelegate.mayHaveEndedByAnOutsideSignal`), not as a
    /// crash. With a test filter among `arguments`, `--filter` or `--skip`, a helper that found no test to run, as a
    /// bundle the filter leaves nothing in does, exits 69 (`EX_UNAVAILABLE`, swift-testing's "no tests found"), which
    /// passes, as `swift test` takes it: a bundle of property tests alone runs none of them with the property tests
    /// skipped.
    ///
    /// The script sets `environment(in:)` itself: macOS drops every `DYLD_` variable from the environment of a
    /// protected binary such as `/bin/sh` as it starts, so they would never reach the helpers otherwise.
    ///
    /// It starts each helper through `helperLink(forWorkerIn: folder)`, which it makes, so the tests' `UserDefaults`
    /// are the folder's own (see `defaultsDomain(forWorkerIn:)`). It empties them first, so that a mutant's run sees
    /// none of what an earlier run in that folder wrote, as a mutant's changes could fail the runs after it. `defaults`
    /// does that, in about 5 ms, rather than SwiftMutator, whose own copy of the domain would be written back to disk
    /// when it exits. If the link can't be made, it starts the helper itself and leaves its domain, which other
    /// `swift test` runs share, alone.
    func script(in folder: URL, forMutantIn filePath: String? = nil) -> String {
        let exports = environment(in: folder).sorted { $0.key < $1.key }.map { name, value in
            "export \(name)=\(Logger.shellQuoted(value))"
        }
        let link = Logger.shellQuoted(Self.helperLink(forWorkerIn: folder).path)
        let startHelper = """
            helper=\(link)
            if ln -sf \(Logger.shellQuoted(helper)) "$helper" 2>/dev/null; then
              /usr/bin/defaults delete \(Logger.shellQuoted(Self.defaultsDomain(forWorkerIn: folder))) >/dev/null 2>&1
            else
              helper=\(Logger.shellQuoted(helper))
            fi
            """
        let products = (sharedBuild ?? folder).appendingPathComponent(productsFolder).path
        let passedOn = arguments.map(Logger.shellQuoted).joined(separator: " ")
        let noTestsFoundPasses = arguments.contains("--filter") || arguments.contains("--skip")
        let verdict = noTestsFoundPasses
            ? "[ $status -eq 0 ] || [ $status -eq 69 ] || failed=1"
            : "[ $status -eq 0 ] || failed=1"
        let runs = bundles(forMutantIn: filePath).map { bundle in
            let executable = Logger.shellQuoted("\(products)/\(bundle).xctest/Contents/MacOS/\(bundle)")
            let process = Logger.shellQuoted("\(helper) --test-bundle-path \(products)/\(bundle).xctest")
            return """
                "$helper" --test-bundle-path \(executable) \(passedOn) \(executable) \
                --testing-library swift-testing
                status=$?
                case $status in 129|130|143) exit $status ;; esac
                if [ $status -gt 128 ]; then
                  printf "error: Process '%s' exited with unexpected signal code %d\\n" \(process) $((status - 128)) >&2
                fi
                \(verdict)
                """
        }
        return (exports + [startHelper, "failed=0"] + runs + ["exit $failed"]).joined(separator: "\n")
    }

    /// The bundles in the order a mutant in `filePath` runs them: first those with a test file named after the mutated
    /// file, such as `FooTests.swift` or `FooParsingTests.swift` for `Foo.swift`, then the rest, each in name order. A
    /// run stopped at its first failed test or crash ends sooner when the bundle that kills the mutant comes first.
    /// Which bundles run, and so the verdict, don't change: only how long a killed mutant takes. With no `filePath`, as
    /// for a run with no mutant on, name order.
    func bundles(forMutantIn filePath: String?) -> [String] {
        guard let filePath else { return bundles }
        let name = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        let first = bundles.filter { bundle in
            testFiles[bundle, default: []].contains { Self.isTestFile($0, of: name) }
        }
        return first + bundles.filter { !first.contains($0) }
    }

    /// Whether `testFile`, a test file's name without `.swift`, is named after the source file `name`: `name`, then
    /// more words or none, ending `Tests` or `Test`. `FormatterTests` isn't named after `Format`.
    static func isTestFile(_ testFile: String, of name: String) -> Bool {
        guard !name.isEmpty, testFile.hasPrefix(name), testFile.hasSuffix("Tests") || testFile.hasSuffix("Test") else {
            return false
        }
        return testFile.dropFirst(name.count).first?.isUppercase ?? false
    }

    /// The variables `swift test` sets for its test processes in `folder`: where the bundles find their frameworks and
    /// the package's dynamic libraries, and no colour. `script(in:)` sets them.
    func environment(in folder: URL) -> [String: String] {
        let products = (sharedBuild ?? folder).appendingPathComponent(productsFolder).path
        return [
            "DYLD_FRAMEWORK_PATH": [
                "\(platformDeveloperFolder)/Library/Frameworks",
                "\(platformDeveloperFolder)/Library/PrivateFrameworks",
            ].joined(separator: ":"),
            "DYLD_LIBRARY_PATH": "\(products):\(platformDeveloperFolder)/usr/lib",
            "NO_COLOR": "1",
        ]
    }
}
