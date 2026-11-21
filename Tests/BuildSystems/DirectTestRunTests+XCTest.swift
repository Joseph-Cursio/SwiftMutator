@testable import muterCore
import XCTest

/// XCTest tests run directly on macOS, by `xctest`, with each bundle's Swift Testing tests run by the helper (#281).
extension DirectTestRunTests {
    /// Stands for `xctest`: says what it was given and whether Swift Testing is on, then runs the XCTest "tests" of
    /// its bundle, its first argument, named for what they do, and prints XCTest's summary of the bundle's suite. The
    /// bundles that fail or crash here have names the fake helper passes, so a test's verdict comes from `xctest`
    /// alone.
    static let fakeXCTest = #"""
        #!/bin/sh
        printf 'xctest ran:'; printf ' %s' "$@"; printf '\n'
        printf 'swift testing=%s\n' "$SWIFT_TESTING_ENABLED"
        bundle=$(basename "$1" .xctest)
        case "$bundle" in
          *XCSignalled) kill -USR1 $$ ;;
          *XCFailsThenWaits) echo "Test Case '-[$bundle.SampleTests testSample]' failed (0.001 seconds)."; sleep 10 ;;
          *XCFailure)
            echo "Test Case '-[$bundle.SampleTests testSample]' failed (0.001 seconds)."
            echo "Test Suite '$bundle.xctest' failed at 2026-11-20 17:00:00.000."
            echo "	 Executed 3 tests, with 1 failure (0 unexpected) in 0.001 (0.001) seconds"
            exit 1 ;;
        esac
        echo "Test Suite '$bundle.xctest' passed at 2026-11-20 17:00:00.000."
        echo "	 Executed 3 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds"
        """#

    // A run of Swift Testing tests alone is the script it was before XCTest tests could run directly, `xctest` found
    // or not.
    func test_theScriptOfASwiftTestingProject_isUnchanged() {
        let direct = DirectTestRun(
            platform: .macOS(helper: "/h", platformDeveloperFolder: "/P", xctest: "/X/xctest"),
            productsFolder: ".b",
            bundles: ["AppTests", "CoreTests"],
            testFiles: [:],
            arguments: ["--skip-build", "--quiet"]
        )
        let folder = #"'/w/it'\''s a p'"#
        let helperRun = { (bundle: String) in
            let executable = "\(folder.dropLast())/.b/\(bundle).xctest/Contents/MacOS/\(bundle)'"
            return [
                #""$helper" --test-bundle-path "# + executable + " '--skip-build' '--quiet' " + executable
                    + " --testing-library swift-testing",
                "status=$?",
                "case $status in 129|130|143) exit $status ;; esac",
                "if [ $status -gt 128 ]; then",
                #"  printf "error: Process '%s' exited with unexpected signal code %d\n" "#
                    + #"'/h --test-bundle-path /w/it'\''s a p/.b/"# + bundle + ".xctest' $((status - 128)) >&2",
                "fi",
                "[ $status -eq 0 ] || failed=1",
            ]
        }
        let expected = [
            "export DYLD_FRAMEWORK_PATH='/P/Library/Frameworks:/P/Library/PrivateFrameworks'",
            "export DYLD_LIBRARY_PATH=\(folder.dropLast())/.b:/P/usr/lib'",
            "export NO_COLOR='1'",
            "helper=\(folder.dropLast()).swiftpm-testing-helper'",
            #"if ln -sf '/h' "$helper" 2>/dev/null; then"#,
            #"  /usr/bin/defaults delete 'it'\''s a p.swiftpm-testing-helper' >/dev/null 2>&1"#,
            "else",
            "  helper='/h'",
            "fi",
            "failed=0",
        ] + helperRun("AppTests") + helperRun("CoreTests") + ["exit $failed"]

        XCTAssertEqual(
            direct.script(in: URL(fileURLWithPath: "/w/it's a p")).split(separator: "\n").map(String.init),
            expected
        )
    }

    // `swift test` runs a bundle's XCTest tests with `xctest`, Swift Testing off, given none of its own arguments,
    // then the helper on every bundle, which finds no test in one of XCTest tests alone and exits 69, a pass.
    func test_aBundleWithXCTestTests_runsThemWithXctest_beforeTheHelper() async throws {
        let run = try await runAMutant(bundles: [], with: makeDirectTestRun(
            bundles: ["AppTests", "CoreNoTests"], xctestBundles: ["CoreNoTests"], arguments: ["--skip-build"]
        ))

        let products = worker.appendingPathComponent(".build/out/Products/Debug").path
        let ran = run.testLog.split(separator: "\n").map(String.init).filter { $0.contains("ran:") }
        XCTAssertEqual(ran, [
            "ran: --test-bundle-path \(products)/AppTests.xctest/Contents/MacOS/AppTests --skip-build "
                + "\(products)/AppTests.xctest/Contents/MacOS/AppTests --testing-library swift-testing",
            "xctest ran: \(products)/CoreNoTests.xctest",
            "ran: --test-bundle-path \(products)/CoreNoTests.xctest/Contents/MacOS/CoreNoTests --skip-build "
                + "\(products)/CoreNoTests.xctest/Contents/MacOS/CoreNoTests --testing-library swift-testing",
        ], run.testLog)
        XCTAssertTrue(run.testLog.contains("swift testing=0\n"), run.testLog)
        XCTAssertEqual(run.outcome, .passed, run.testLog)
    }

    // Without a filter, a bundle the baseline ran no XCTest test in should have Swift Testing tests.
    func test_aHelperThatFindsNoTest_failsABundleWithoutXCTestTests_withoutAFilter() async throws {
        let run = try await runAMutant(bundles: [], with: makeDirectTestRun(
            bundles: ["CoreNoTests"], arguments: ["--skip-build"]
        ))

        XCTAssertFalse(run.testLog.contains("xctest ran:"), run.testLog)
        XCTAssertEqual(run.exitStatus, 1)
    }

    // The helper passes the same bundle, so only `xctest`'s status can fail the run.
    func test_aFailedXCTestTest_killsTheMutant_andTheOtherBundlesRun() async throws {
        let run = try await runAMutant(bundles: [], with: makeDirectTestRun(
            bundles: ["AppXCFailure", "CoreTests"], xctestBundles: ["AppXCFailure"], arguments: ["--skip-build"]
        ))

        let lines = run.testLog.split(separator: "\n").map(String.init)
        let helperRun = try XCTUnwrap(
            lines.firstIndex { $0.hasPrefix("ran:") && $0.contains("AppXCFailure --testing-library") }, run.testLog
        )
        XCTAssertTrue(lines[helperRun...].contains { $0.hasPrefix("✔ Test run with 2 tests") }, run.testLog)
        XCTAssertEqual(run.exitStatus, 1)
        XCTAssertEqual(run.outcome, .failed, run.testLog)
        XCTAssertTrue(run.testLog.contains("CoreTests --testing-library"), run.testLog)
    }

    // As `swift test` reports it, which `CrashLine` and coverage's crash reading take. The helper passes the same
    // bundle, so the crash is `xctest`'s alone.
    func test_anXctestKilledBySignal_isReportedAsSwiftTestReportsIt() async throws {
        let run = try await runAMutant(bundles: [], with: makeDirectTestRun(
            bundles: ["AppXCSignalled", "CoreTests"], xctestBundles: ["AppXCSignalled"], arguments: ["--skip-build"]
        ))

        let bundle = worker.appendingPathComponent(".build/out/Products/Debug/AppXCSignalled.xctest").path
        XCTAssertTrue(
            run.testLog.contains(
                "error: Process '\(xctest.path) \(bundle)' exited with unexpected signal code \(SIGUSR1)\n"
            ),
            run.testLog
        )
        XCTAssertTrue(run.testLog.contains("CoreTests --testing-library"), run.testLog)
        XCTAssertEqual(run.outcome, .runtimeError)
    }

    // `xctest` writes each line as it goes, so a failed XCTest test stops the run at once.
    func test_aRunStoppingAtItsFirstFailure_stopsAtAFailedXCTestTest() async throws {
        let started = Date()
        let run = try await runAMutant(
            bundles: [],
            stoppingAtFirstFailure: true,
            with: makeDirectTestRun(
                bundles: ["AppXCFailsThenWaits", "CoreTests"],
                xctestBundles: ["AppXCFailsThenWaits"],
                arguments: ["--skip-build"]
            )
        )

        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the run didn't stop at the failed test")
        XCTAssertEqual(run.ending, .stoppedAtFailedTest)
        XCTAssertEqual(run.outcome, .failed)
        XCTAssertFalse(run.testLog.contains("CoreTests --testing-library"), run.testLog)
    }
}
