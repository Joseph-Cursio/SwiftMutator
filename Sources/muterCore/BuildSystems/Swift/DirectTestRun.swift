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
    /// The build's products folder, relative to the project, so each worker's clone runs its own build.
    let productsFolder: String
    /// The test bundles' names, in name order.
    let bundles: [String]
    /// The macOS platform's `Developer` folder, whose frameworks the test bundles load XCTest and Swift Testing from.
    let platformDeveloperFolder: String
    /// What follows `test` in a mutant's `swift test` command, `--skip-build` included. `swift test` passes its own
    /// arguments to each helper, which reads the test filters among them and ignores the rest.
    let arguments: [String]

    /// Why the bundles can't be run directly. A nil `reason` isn't worth telling: on Linux, say, or when `executable`
    /// isn't `swift` itself, as for a wrapper.
    struct Unavailable: Error, Equatable {
        let reason: String?
    }
}

extension DirectTestRun {
    /// The `/bin/sh` script that runs each bundle in `folder`, the mutated project or a worker's clone, and exits 1 if
    /// any helper failed. A helper killed by a signal is reported as `swift test` reports it, with a line that
    /// `TestSuiteOutcome` reads as a crash. Every bundle runs, as under `swift test`, unless the run is stopped. A
    /// helper ended by SIGINT, SIGTERM or SIGHUP ends the script at once, with its status, so that a signal from outside
    /// SwiftMutator reads as one (`MutationTestingDelegate.mayHaveEndedByAnOutsideSignal`), not as a crash.
    ///
    /// The script sets `environment(in:)` itself: macOS drops every `DYLD_` variable from the environment of a
    /// protected binary such as `/bin/sh` as it starts, so they would never reach the helpers otherwise.
    func script(in folder: URL) -> String {
        let exports = environment(in: folder).sorted { $0.key < $1.key }.map { name, value in
            "export \(name)=\(Logger.shellQuoted(value))"
        }
        let products = folder.appendingPathComponent(productsFolder).path
        let passedOn = arguments.map(Logger.shellQuoted).joined(separator: " ")
        let runs = bundles.map { bundle in
            let executable = Logger.shellQuoted("\(products)/\(bundle).xctest/Contents/MacOS/\(bundle)")
            let process = Logger.shellQuoted("\(helper) --test-bundle-path \(products)/\(bundle).xctest")
            return """
                \(Logger.shellQuoted(helper)) --test-bundle-path \(executable) \(passedOn) \(executable) \
                --testing-library swift-testing
                status=$?
                case $status in 129|130|143) exit $status ;; esac
                if [ $status -gt 128 ]; then
                  printf "error: Process '%s' exited with unexpected signal code %d\\n" \(process) $((status - 128)) >&2
                fi
                [ $status -eq 0 ] || failed=1
                """
        }
        return (exports + ["failed=0"] + runs + ["exit $failed"]).joined(separator: "\n")
    }

    /// The variables `swift test` sets for its test processes in `folder`: where the bundles find their frameworks and
    /// the package's dynamic libraries, and no colour. `script(in:)` sets them.
    func environment(in folder: URL) -> [String: String] {
        let products = folder.appendingPathComponent(productsFolder).path
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

extension DirectTestRun {
    /// Why a mutant's tests can't run directly after a baseline that printed `baselineLog`, given a run that did with
    /// no mutant on, which ended as `outcome` and printed `log`; nil if they can.
    static func whyNot(baselineLog: String, outcome: TestSuiteOutcome, log: String) -> String? {
        let expected = swiftTestingCounts(in: baselineLog).sorted()
        let ran = swiftTestingCounts(in: log).sorted()
        guard outcome == .passed else {
            return "running the test bundles directly, with no mutant on, didn't pass, as `swift test` did"
        }
        guard !expected.isEmpty, expected.reduce(0, +) > 0 else {
            return "the baseline ran no Swift Testing test"
        }
        guard ran == expected else {
            let counts = { (counts: [Int]) in counts.map(String.init).joined(separator: ", ") }
            return "running the test bundles directly ran \(counts(ran)) Swift Testing tests, "
                + "where `swift test` ran \(counts(expected))"
        }
        return nil
    }

    /// Whether `log`, a `swift test` run's, shows an XCTest test run: XCTest's `Executed 3 tests, with …` line. A
    /// bundle with none still prints one, for 0 tests.
    static func ranXCTestTests(in log: String) -> Bool {
        counts(of: #"Executed ([0-9]+) tests?, with "#, in: log).contains { $0 > 0 }
    }

    /// The tests each Swift Testing run in `log` ran, in order, from its `Test run with 12 tests in 3 suites …` line.
    static func swiftTestingCounts(in log: String) -> [Int] {
        counts(of: #"Test run with ([0-9]+) tests? "#, in: log)
    }

    private static func counts(of pattern: String, in log: String) -> [Int] {
        let regex = NSRegularExpression.regexWithPattern(pattern)
        return regex.matches(in: log, range: NSRange(log.startIndex..., in: log)).compactMap { match in
            Range(match.range(at: 1), in: log).flatMap { Int(log[$0]) }
        }
    }
}

extension DirectTestRun {
    /// How `configuration`'s test command would run the bundles of `project`, the mutated project, once its baseline
    /// has built them.
    static func probe(_ configuration: MuterConfiguration, in project: URL) async -> Result<DirectTestRun, Unavailable> {
        #if os(macOS)
        await Prober().probe(configuration, in: project)
        #else
        .failure(Unavailable(reason: nil))
        #endif
    }

    private struct Prober {
        @Dependency(\.process)
        var process: ProcessFactory
        @Dependency(\.fileManager)
        var fileManager: FileSystemManager

        func probe(_ configuration: MuterConfiguration, in project: URL) async -> Result<DirectTestRun, Unavailable> {
            let executable = configuration.testCommandExecutable
            guard URL(fileURLWithPath: executable).lastPathComponent == "swift",
                  configuration.testCommandArguments.first == "test"
            else {
                return .failure(Unavailable(reason: nil))
            }
            guard let helper = await helper(of: executable) else {
                return .failure(Unavailable(reason: "\(executable)'s toolchain has no swiftpm-testing-helper"))
            }
            guard let platform = await output(of: "/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"])
            else {
                return .failure(Unavailable(reason: "`xcrun` didn't say where the macOS platform is"))
            }
            let coverage = SwiftCoverage(platform: .darwin)
            guard let products = await coverage.buildDirectory(configuration)?.canonicalPath else {
                return .failure(Unavailable(reason: "`swift test --show-codecov-path` didn't say where the build is"))
            }
            let projectPath = project.path.canonicalPath
            guard products.hasPrefix(projectPath + "/") else {
                return .failure(Unavailable(reason: "the build, in \(products), is outside the project"))
            }
            let bundles = await coverage.testBundleFiles(in: products, testTargets: coverage.testTargets(configuration))
            guard !bundles.isEmpty else {
                return .failure(Unavailable(reason: "there is no test bundle in \(products)"))
            }
            return .success(DirectTestRun(
                helper: helper,
                productsFolder: String(products.dropFirst(projectPath.count + 1)),
                bundles: bundles.map(\.name),
                platformDeveloperFolder: platform + "/Developer",
                arguments: Array(configuration.testWithoutBuildArguments(with: "").dropFirst())
            ))
        }

        /// The `swiftpm-testing-helper` beside the `swift` that `executable` runs: in `<toolchain>/usr/libexec`, where
        /// its resource folder is `<toolchain>/usr/lib/swift`. Asked of `swift` itself, so `xcrun`'s and swiftly's
        /// proxies, and `TOOLCHAINS`, choose the toolchain as they do for `swift test`.
        private func helper(of executable: String) async -> String? {
            guard let info = await output(of: executable, ["-print-target-info"]),
                  let target = try? JSONDecoder().decode(TargetInfo.self, from: Data(info.utf8))
            else {
                return nil
            }
            let helper = URL(fileURLWithPath: target.paths.runtimeResourcePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("libexec/swift/pm/swiftpm-testing-helper")
                .path
            return fileManager.fileExists(atPath: helper) ? helper : nil
        }

        private struct TargetInfo: Decodable {
            let paths: Paths

            struct Paths: Decodable {
                let runtimeResourcePath: String
            }
        }

        /// What `executable` printed, trimmed, if it succeeded and printed anything.
        private func output(of executable: String, _ arguments: [String]) async -> String? {
            guard let result = await process().runCommand(url: executable, arguments: arguments), result.succeeded
            else {
                return nil
            }
            return result.output.trimmed.nilIfEmpty
        }
    }
}
