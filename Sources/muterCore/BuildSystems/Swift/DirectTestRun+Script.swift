import Foundation

extension DirectTestRun {
    /// The `/bin/sh` script that runs each bundle in `folder`, the mutated project or a worker's clone, in the order
    /// `bundles(forMutantIn: filePath)` gives, and exits 1 if any of its runs failed. For each bundle, its XCTest run,
    /// if it has one (`runsXCTest(in:)`), then its Swift Testing run, as `swift test` starts them, though `swift test`
    /// runs every bundle's XCTest tests before any Swift Testing test. A run killed by a signal is reported as `swift
    /// test` reports it, with a line that `TestSuiteOutcome` reads as a crash, and that stops a run that stops at its
    /// first failure (`CrashLine`). Every bundle runs, as under `swift test`, unless the run is stopped. A run ended by
    /// SIGINT, SIGTERM or SIGHUP ends the script at once, with its status, so that a signal from outside SwiftMutator
    /// reads as one (`MutationTestingDelegate.mayHaveEndedByAnOutsideSignal`), not as a crash.
    ///
    /// A Swift Testing run that found no test to run exits 69 (`EX_UNAVAILABLE`, swift-testing's "no tests found"),
    /// which passes, as `swift test` takes it, where a bundle can have none: on Linux always; on macOS with a test
    /// filter among `arguments`, `--filter` or `--skip`, as a bundle of property tests alone runs none of them with the
    /// property tests skipped, and in a bundle with XCTest tests. Elsewhere 69 fails, as any status but 0 does.
    func script(in folder: URL, forMutantIn filePath: String? = nil) -> String {
        switch platform {
        case let .macOS(helper, _, xctest):
            macOSScript(in: folder, forMutantIn: filePath, helper: helper, xctest: xctest)

        case .linux:
            linuxScript(in: folder, forMutantIn: filePath)
        }
    }

    /// The script on macOS. It sets `environment(in:)` itself: macOS drops every `DYLD_` variable from the environment
    /// of a protected binary such as `/bin/sh` as it starts, so they would never reach the bundles otherwise.
    ///
    /// It starts each helper through `helperLink(forWorkerIn: folder)`, which it makes, so the Swift Testing tests'
    /// `UserDefaults` are the folder's own (see `defaultsDomain(forWorkerIn:)`). It empties them first, so that a
    /// mutant's run sees none of what an earlier run in that folder wrote, as a mutant's changes could fail the runs
    /// after it. `defaults` does that, in about 5 ms, rather than SwiftMutator, whose own copy of the domain would be
    /// written back to disk when it exits. If the link can't be made, it starts the helper itself and leaves its
    /// domain, which other `swift test` runs share, alone. `xctest` has a bundle identifier, which fixes its tests'
    /// domain whatever its file is named, so they share it, as under `swift test`.
    private func macOSScript(in folder: URL, forMutantIn filePath: String?, helper: String, xctest: String?) -> String {
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
        let products = products(in: folder)
        let passedOn = arguments.map(Logger.shellQuoted).joined(separator: " ")
        let filtered = arguments.contains("--filter") || arguments.contains("--skip")
        let runs = bundles(forMutantIn: filePath).flatMap { bundle in
            let xctestRun = xctest.flatMap { xctest -> String? in
                guard runsXCTest(in: bundle) else { return nil }
                let path = "\(products)/\(bundle).xctest"
                return Self.run(
                    "SWIFT_TESTING_ENABLED=0 \(Logger.shellQuoted(xctest)) \(Logger.shellQuoted(path))",
                    as: "\(xctest) \(path)",
                    passingNoTestsFound: false
                )
            }
            let executable = Logger.shellQuoted("\(products)/\(bundle).xctest/Contents/MacOS/\(bundle)")
            let helperRun = Self.run(
                "\"$helper\" --test-bundle-path \(executable) \(passedOn) \(executable) "
                    + "--testing-library swift-testing",
                as: "\(helper) --test-bundle-path \(products)/\(bundle).xctest",
                passingNoTestsFound: filtered || runsXCTest(in: bundle)
            )
            return [xctestRun, helperRun].compactMap(\.self)
        }
        return (exports + [startHelper, "failed=0"] + runs + ["exit $failed"]).joined(separator: "\n")
    }

    /// The script on Linux, which starts each `<bundle>-test-runner` twice, as `swift test` does: with no arguments,
    /// for its XCTest tests, then with `swift test`'s own and `--testing-library swift-testing`, for its Swift Testing
    /// tests. Every worker's tests share `UserDefaults`, in `~/.config/<bundle>-test-runner.plist`, as under `swift
    /// test`: the domain is the runner's real name, which a link doesn't change.
    private func linuxScript(in folder: URL, forMutantIn filePath: String?) -> String {
        let exports = environment(in: folder).sorted { $0.key < $1.key }.map { name, value in
            let before = name == "LD_LIBRARY_PATH" ? "\"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\"" : ""
            return "export \(name)=\(Logger.shellQuoted(value))\(before)"
        }
        let products = products(in: folder)
        let swiftTesting = arguments + ["--testing-library", "swift-testing"]
        let runs = bundles(forMutantIn: filePath).flatMap { bundle in
            let runner = "\(products)/\(bundle)-test-runner"
            let xctestRun = runsXCTest(in: bundle)
                ? Self.run(Logger.shellQuoted(runner), as: runner, passingNoTestsFound: false)
                : nil
            let swiftTestingRun = Self.run(
                ([runner] + swiftTesting).map(Logger.shellQuoted).joined(separator: " "),
                as: ([runner] + swiftTesting).joined(separator: " "),
                passingNoTestsFound: true
            )
            return [xctestRun, swiftTestingRun].compactMap(\.self)
        }
        return (exports + ["failed=0"] + runs + ["exit $failed"]).joined(separator: "\n")
    }

    /// The lines that run `command`, the process `swift test` would name `process`, and fold its status into
    /// `failed`: a stopping signal's ends the script, another signal's is reported as `swift test` reports a crash,
    /// and any status but 0 fails, or but 0 and 69 with `passingNoTestsFound`.
    private static func run(_ command: String, as process: String, passingNoTestsFound: Bool) -> String {
        let verdict = passingNoTestsFound
            ? "[ $status -eq 0 ] || [ $status -eq 69 ] || failed=1"
            : "[ $status -eq 0 ] || failed=1"
        return """
            \(command)
            status=$?
            case $status in 129|130|143) exit $status ;; esac
            if [ $status -gt 128 ]; then
              printf "error: Process '%s' exited with unexpected signal code %d\\n" \(Logger.shellQuoted(process)) \
            $((status - 128)) >&2
            fi
            \(verdict)
            """
    }
}
