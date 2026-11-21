@testable import muterCore
import XCTest

/// Each test target's `<target>-test-runner` run directly on Linux, for its XCTest tests, then its Swift Testing tests
/// (#281). The script is plain `sh`, so it runs here on any platform.
extension DirectTestRunTests {
    /// Stands for a `<target>-test-runner`: says what it was given, then, with no argument, runs its target's XCTest
    /// "tests", named for what they do, printing Linux XCTest's summary, whose suite is the products folder's; with
    /// arguments, its Swift Testing "tests".
    static let fakeRunner = #"""
        #!/bin/sh
        printf 'runner ran: %s' "$(basename "$0")"; for argument in "$@"; do printf ' %s' "$argument"; done; echo
        printf 'library path=%s\n' "$LD_LIBRARY_PATH"
        name=$(basename "$0" -test-runner)
        if [ $# -eq 0 ]; then
          case "$name" in
            *XCFails)
              echo "/p/Tests/SampleTests.swift:6: error: SampleTests.testSample : XCTAssertTrue failed"
              echo "Test Case 'SampleTests.testSample' failed (0.001 seconds)"
              echo "Test Suite 'Debug-linux-aarch64.xctest' failed at 2026-11-20 23:15:53.292"
              echo "	 Executed 2 tests, with 1 failure (0 unexpected) in 0.0 (0.0) seconds"
              exit 1 ;;
            *XCCrashes) kill -USR1 $$ ;;
          esac
          echo "Test Suite 'Debug-linux-aarch64.xctest' passed at 2026-11-20 23:15:53.292"
          echo "	 Executed 2 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds"
          exit 0
        fi
        case "$name" in
          *NoSwiftTesting) echo "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds."; exit 69 ;;
        esac
        echo "✔ Test run with 2 tests in 1 suite passed after 0.1 seconds."
        """#

    func test_theLinuxScript_runsEachRunnerForXCTestThenSwiftTesting_withNoHelperOrDefaults() {
        let direct = makeLinuxRun(bundles: ["MTests", "STests"], ranXCTest: true, productsFolder: ".b")
        let runs = { (bundle: String) in
            let runner = "'/w/p/.b/\(bundle)-test-runner'"
            let process = "/w/p/.b/\(bundle)-test-runner"
            let status = [
                "status=$?",
                "case $status in 129|130|143) exit $status ;; esac",
                "if [ $status -gt 128 ]; then",
            ]
            let signal = #"  printf "error: Process '%s' exited with unexpected signal code %d\n" "#
            return [runner] + status + [
                signal + "'\(process)' $((status - 128)) >&2",
                "fi",
                "[ $status -eq 0 ] || failed=1",
                "\(runner) '--skip-build' '--quiet' '--testing-library' 'swift-testing'",
            ] + status + [
                signal + "'\(process) --skip-build --quiet --testing-library swift-testing' $((status - 128)) >&2",
                "fi",
                "[ $status -eq 0 ] || [ $status -eq 69 ] || failed=1",
            ]
        }
        let expected = [
            #"export LD_LIBRARY_PATH='/w/p/.b'"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}""#,
            "export NO_COLOR='1'",
            "failed=0",
        ] + runs("MTests") + runs("STests") + ["exit $failed"]

        XCTAssertEqual(
            direct.script(in: URL(fileURLWithPath: "/w/p")).split(separator: "\n").map(String.init),
            expected
        )
    }

    // A baseline that ran no XCTest test needs no XCTest run, and `swift test`'s Swift Testing runs take 69 as a pass.
    func test_theLinuxScriptWithoutXCTestTests_startsOnlyTheSwiftTestingRuns() {
        let script = makeLinuxRun(bundles: ["STests"], ranXCTest: false, productsFolder: ".b")
            .script(in: URL(fileURLWithPath: "/w/p"))

        let lines = script.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0.hasPrefix("'/w/p/.b/") }, [
            "'/w/p/.b/STests-test-runner' '--skip-build' '--quiet' '--testing-library' 'swift-testing'",
        ])
        XCTAssertTrue(lines.contains("[ $status -eq 0 ] || [ $status -eq 69 ] || failed=1"), script)
    }

    func test_aLinuxRun_startsEachRunnerTwice_inItsWorkersBuild_andTakes69AsAPass() async throws {
        try makeRunners(["MTests", "XNoSwiftTesting"])

        let run = try await runAMutant(
            bundles: [], with: makeLinuxRun(bundles: ["MTests", "XNoSwiftTesting"], ranXCTest: true)
        )

        let products = worker.appendingPathComponent(".build/out/Products/Debug").path
        XCTAssertEqual(run.testLog.split(separator: "\n").filter { $0.hasPrefix("runner ran:") }, [
            "runner ran: MTests-test-runner",
            "runner ran: MTests-test-runner --skip-build --quiet --testing-library swift-testing",
            "runner ran: XNoSwiftTesting-test-runner",
            "runner ran: XNoSwiftTesting-test-runner --skip-build --quiet --testing-library swift-testing",
        ], run.testLog)
        XCTAssertTrue(run.testLog.contains("library path=\(products)"), run.testLog)
        XCTAssertEqual(run.outcome, .passed, run.testLog)
    }

    func test_aFailedXCTestTestOnLinux_killsTheMutant() async throws {
        try makeRunners(["AppXCFails", "CoreTests"])

        let run = try await runAMutant(
            bundles: [], with: makeLinuxRun(bundles: ["AppXCFails", "CoreTests"], ranXCTest: true)
        )

        XCTAssertEqual(run.exitStatus, 1)
        XCTAssertEqual(run.outcome, .failed, run.testLog)
        XCTAssertTrue(run.testLog.contains("runner ran: CoreTests-test-runner --skip-build"), run.testLog)
    }

    func test_aRunnerKilledBySignal_isReportedAsSwiftTestReportsIt() async throws {
        try makeRunners(["AppXCCrashes", "CoreTests"])

        let run = try await runAMutant(
            bundles: [], with: makeLinuxRun(bundles: ["AppXCCrashes", "CoreTests"], ranXCTest: true)
        )

        let runner = worker.appendingPathComponent(".build/out/Products/Debug/AppXCCrashes-test-runner").path
        XCTAssertTrue(
            run.testLog.contains("error: Process '\(runner)' exited with unexpected signal code \(SIGUSR1)\n"),
            run.testLog
        )
        XCTAssertEqual(run.outcome, .runtimeError)
    }

    // As `swift test` sets it, so the runners find the package's libraries first.
    func test_theLinuxScript_putsTheProductsBeforeTheLibraryPathItWasGiven() throws {
        let script = makeLinuxRun(bundles: [], ranXCTest: false).script(in: worker)
        let exports = script.split(separator: "\n").filter { $0.hasPrefix("export ") }.joined(separator: "\n")
        let products = worker.appendingPathComponent(".build/out/Products/Debug").path

        XCTAssertEqual(try printedLibraryPath(exports, given: "/given"), "\(products):/given")
        XCTAssertEqual(try printedLibraryPath(exports, given: nil), products)
    }

    // MARK: - Helpers

    func makeLinuxRun(
        bundles: [String],
        ranXCTest: Bool,
        productsFolder: String = ".build/out/Products/Debug"
    ) -> DirectTestRun {
        DirectTestRun(
            platform: .linux,
            productsFolder: productsFolder,
            bundles: bundles,
            testFiles: [:],
            arguments: ["--skip-build", "--quiet"],
            xctestBundles: ranXCTest ? ["Debug-linux-aarch64"] : []
        )
    }

    /// Makes a fake `<bundle>-test-runner` for each of `bundles` in the worker's build.
    func makeRunners(_ bundles: [String]) throws {
        let products = worker.appendingPathComponent(".build/out/Products/Debug")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        for bundle in bundles {
            let runner = products.appendingPathComponent("\(bundle)-test-runner")
            try Self.fakeRunner.write(to: runner, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        }
    }

    /// What `LD_LIBRARY_PATH` is after `exports`, in a shell given `given` as it.
    func printedLibraryPath(_ exports: String, given: String?) throws -> String {
        let shell = Foundation.Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", exports + "\nprintf %s \"$LD_LIBRARY_PATH\""]
        var environment = ProcessInfo.processInfo.environment
        environment["LD_LIBRARY_PATH"] = given
        shell.environment = environment
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        return String(lossyUTF8: data)
    }
}
