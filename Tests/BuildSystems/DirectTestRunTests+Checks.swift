@testable import muterCore
import XCTest

extension DirectTestRunTests {
    func test_whyNot_acceptsARunOfTheBaselinesTestsInEachBundle_inAnyOrder() {
        let baseline = """
            Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
            ✔ Test run with 4294 tests in 500 suites passed after 11.641 seconds.
            ✔ Test run with 1 test in 1 suite passed after 0.040 seconds.
            """
        let direct = """
            ✔ Test run with 1 test in 1 suite passed after 0.040 seconds.
            ✔ Test run with 4294 tests in 500 suites passed after 11.889 seconds.
            """

        XCTAssertNil(DirectTestRun.whyNot(baselineLog: baseline, outcome: .passed, log: direct))
        XCTAssertNotNil(DirectTestRun.whyNot(baselineLog: baseline, outcome: .failed, log: direct))
        XCTAssertEqual(
            DirectTestRun.whyNot(baselineLog: baseline, outcome: .passed, log: "✔ Test run with 4295 tests "),
            "running the test bundles directly ran 4295 Swift Testing tests, where `swift test` ran 1, 4294"
        )
        XCTAssertEqual(
            DirectTestRun.whyNot(baselineLog: "Executed 0 tests, with 0 failures", outcome: .passed, log: ""),
            "the baseline ran no XCTest or Swift Testing test"
        )
    }

    // On macOS, each bundle's suite names it: a bundle that ran fewer XCTest tests, or none, fails the check.
    func test_whyNot_comparesTheXCTestTestsOfEachBundle() {
        let baseline = """
            Test Suite 'All tests' started at 2026-11-20 15:07:01.000.
            Test Suite 'BonMotTests.xctest' passed at 2026-11-20 15:07:02.000.
            	 Executed 85 tests, with 3 tests skipped and 0 failures (0 unexpected) in 0.1 (0.1) seconds
            Test Suite 'All tests' passed at 2026-11-20 15:07:02.000.
            	 Executed 85 tests, with 3 tests skipped and 0 failures (0 unexpected) in 0.1 (0.1) seconds
            Test Suite 'UITests.xctest' passed at 2026-11-20 15:07:02.000.
            	 Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds
            ✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
            ✔ Test run with 4 tests in 1 suite passed after 0.001 seconds.
            """
        let direct = """
            ✔ Test run with 4 tests in 1 suite passed after 0.001 seconds.
            Test Suite 'BonMotTests.xctest' passed at 2026-11-20 15:08:02.000.
            	 Executed 85 tests, with 3 tests skipped and 0 failures (0 unexpected) in 0.1 (0.1) seconds
            ✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
            """

        XCTAssertNil(DirectTestRun.whyNot(baselineLog: baseline, outcome: .passed, log: direct))
        XCTAssertEqual(
            DirectTestRun.whyNot(
                baselineLog: baseline, outcome: .passed, log: direct.replacingOccurrences(of: "85", with: "84")
            ),
            "running the test bundles directly ran XCTest tests as 84 in BonMotTests.xctest, "
                + "where `swift test` ran 85 in BonMotTests.xctest"
        )
        XCTAssertEqual(
            DirectTestRun.whyNot(
                baselineLog: baseline, outcome: .passed, log: direct.replacingOccurrences(of: "BonMot", with: "Other")
            ),
            "running the test bundles directly ran XCTest tests as 85 in OtherTests.xctest, "
                + "where `swift test` ran 85 in BonMotTests.xctest"
        )
        XCTAssertEqual(
            DirectTestRun.whyNot(baselineLog: baseline, outcome: .passed, log: "✔ Test run with 4 tests "
                + "✔ Test run with 0 tests "),
            "running the test bundles directly ran XCTest tests as none, "
                + "where `swift test` ran 85 in BonMotTests.xctest"
        )
        XCTAssertEqual(
            DirectTestRun().withXCTestBundles(ranIn: baseline).xctestBundles, ["BonMotTests"]
        )
    }

    // On Linux, every runner's suite is the products folder's, so the runs' counts are compared, in any order.
    func test_whyNot_comparesTheXCTestTestsOfEachLinuxRunner() {
        let summary = { (tests: Int) in
            "Test Suite 'Debug-linux-aarch64.xctest' passed at 2026-11-20 23:15:53.292\n"
                + "\t Executed \(tests) tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n"
                + "Test Suite 'All tests' passed at 2026-11-20 23:15:53.292\n"
                + "\t Executed \(tests) tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n"
        }
        let swiftTesting = "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.\n"
        let baseline = summary(2) + summary(0) + summary(1) + swiftTesting

        XCTAssertNil(DirectTestRun.whyNot(
            baselineLog: baseline, outcome: .passed, log: summary(1) + swiftTesting + summary(2) + summary(0)
        ))
        XCTAssertEqual(
            DirectTestRun.whyNot(baselineLog: baseline, outcome: .passed, log: summary(3) + swiftTesting),
            "running the test bundles directly ran XCTest tests as 3 in Debug-linux-aarch64.xctest, "
                + "where `swift test` ran 1 in Debug-linux-aarch64.xctest, 2 in Debug-linux-aarch64.xctest"
        )
        XCTAssertEqual(
            DirectTestRun().withXCTestBundles(ranIn: baseline).xctestBundles, ["Debug-linux-aarch64"]
        )
    }

    // A run that starts XCTest runs only for the bundles the log names would leave the others' tests out.
    func test_whyNot_refusesXCTestTestsThatNoBundleSuiteNames() {
        XCTAssertEqual(
            DirectTestRun.whyNot(
                baselineLog: "Executed 4 tests, with 0 failures (0 unexpected)\n✔ Test run with 2 tests ",
                outcome: .passed,
                log: "✔ Test run with 2 tests "
            ),
            "the baseline's log doesn't say which bundles ran its XCTest tests"
        )
    }

    func test_xctestTests_needSwiftTest_withAFilter_anOptionThatChangesTheirRun_orNoXctest() {
        let xctestRun = DirectTestRun(arguments: ["--skip-build"], xctestBundles: ["CoreTests"])
        let filters = "the test command filters tests, and only `swift test` turns a filter into XCTest's test names"

        XCTAssertNil(xctestRun.whyXCTestTestsNeedSwiftTest)
        XCTAssertNil(DirectTestRun(arguments: ["--filter", "Core"]).whyXCTestTestsNeedSwiftTest)
        XCTAssertEqual(xctestRun.adding(["--filter", "Core"]).whyXCTestTestsNeedSwiftTest, filters)
        XCTAssertEqual(xctestRun.adding(["--skip=Slow"]).whyXCTestTestsNeedSwiftTest, filters)
        XCTAssertEqual(
            xctestRun.adding(["--num-workers=4"]).whyXCTestTestsNeedSwiftTest,
            "the test command has --num-workers, which changes how `swift test` runs XCTest tests"
        )
        for option in DirectTestRun.xctestOptions {
            XCTAssertNotNil(xctestRun.adding([option]).whyXCTestTestsNeedSwiftTest, option)
        }
        XCTAssertEqual(
            DirectTestRun(xctest: nil, xctestBundles: ["CoreTests"]).whyXCTestTestsNeedSwiftTest,
            "the baseline ran XCTest tests, and `xcrun --find xctest` didn't say where `xctest` is"
        )
        XCTAssertNil(DirectTestRun(platform: .linux, xctestBundles: ["Debug-linux-x86_64"]).whyXCTestTestsNeedSwiftTest)
    }

    // A baseline that ran XCTest tests but named no bundle's suite still keeps a filter or option on `swift test`,
    // with its reason, before any check run: on Linux a filtered run's root is `Selected tests`, and `--parallel`
    // prints no summary at all.
    func test_xctestTests_thatNoBundleSuiteNames_needSwiftTest_beforeAnyCheckRun() {
        let filters = "the test command filters tests, and only `swift test` turns a filter into XCTest's test names"
        let linuxFiltered = "Test Suite 'Selected tests' passed at 2026-11-20 23:15:53.292\n"
            + "\t Executed 3 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n"
            + "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.\n"
        let parallel = "[1/4] Testing XTests.CalcTests/testAdd\n[2/4] Testing MTests.MixTests/testMix\n"
            + "✔ Test run with 1 test in 1 suite passed after 0.001 seconds.\n"
        let linux = DirectTestRun(platform: .linux)

        XCTAssertEqual(
            linux.adding(["--filter", "CalcTests"]).withXCTestBundles(ranIn: linuxFiltered).whyXCTestTestsNeedSwiftTest,
            filters
        )
        XCTAssertEqual(
            linux.adding(["--skip", "Slow"]).withXCTestBundles(ranIn: linuxFiltered).whyXCTestTestsNeedSwiftTest,
            filters
        )
        for run in [linux, DirectTestRun()] {
            XCTAssertEqual(
                run.adding(["--parallel"]).withXCTestBundles(ranIn: parallel).whyXCTestTestsNeedSwiftTest,
                "the test command has --parallel, which changes how `swift test` runs XCTest tests"
            )
        }
        XCTAssertEqual(
            linux.withXCTestBundles(ranIn: linuxFiltered).whyXCTestTestsNeedSwiftTest,
            "the baseline's log doesn't say which bundles ran its XCTest tests"
        )
        XCTAssertEqual(
            DirectTestRun.whyNot(baselineLog: parallel, outcome: .passed, log: "✔ Test run with 1 test in 1 suite "),
            "the baseline's log doesn't say which bundles ran its XCTest tests"
        )
        // Swift Testing tests alone under `--parallel` print no such line, and still run directly.
        let swiftTestingOnly = "✔ Test run with 4 tests in 1 suite passed after 0.001 seconds.\n"
        XCTAssertNil(
            linux.adding(["--parallel"]).withXCTestBundles(ranIn: swiftTestingOnly).whyXCTestTestsNeedSwiftTest
        )
    }

    // A property rerun adds a filter, so a run of XCTest tests leaves the bundles for `swift test`, in each worker's
    // own folder; Swift Testing's helper takes the filter itself.
    func test_aPropertyRerun_ofXCTestTests_runsThroughSwiftTest() throws {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            propertyTests: ["*Properties*"],
            propertyTestFilter: ["Properties"]
        )
        let xctest = configuration.withDirectTestRun(DirectTestRun(xctestBundles: ["CoreTests"]))
        let swiftTesting = configuration.withDirectTestRun(DirectTestRun())

        XCTAssertNil(try XCTUnwrap(xctest.withPropertyTestFilter()).directTestRun)
        XCTAssertNil(try XCTUnwrap(xctest.withPropertyTestsSkipped()).directTestRun)
        XCTAssertTrue(xctest.propertyRerunsLeaveDirectRuns)
        XCTAssertNotNil(try XCTUnwrap(swiftTesting.withPropertyTestFilter()).directTestRun)
        XCTAssertFalse(swiftTesting.propertyRerunsLeaveDirectRuns)
        XCTAssertFalse(MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
            .withDirectTestRun(DirectTestRun(xctestBundles: ["CoreTests"])).propertyRerunsLeaveDirectRuns)
    }

    func test_onlyAMacOSRunOfSwiftTestingTestsAlone_givesEachWorkerItsOwnDefaults() {
        XCTAssertTrue(DirectTestRun().isolatesUserDefaults)
        XCTAssertFalse(DirectTestRun(xctestBundles: ["CoreTests"]).isolatesUserDefaults)
        XCTAssertFalse(DirectTestRun(platform: .linux).isolatesUserDefaults)
    }

    func test_ranXCTestTests_countsOnlyARunOfSome() {
        XCTAssertFalse(DirectTestRun.ranXCTestTests(in: "Executed 0 tests, with 0 failures (0 unexpected)"))
        XCTAssertTrue(DirectTestRun.ranXCTestTests(in: "Executed 1 test, with 1 failure (0 unexpected)"))
        XCTAssertFalse(DirectTestRun.ranXCTestTests(in: "✔ Test run with 12 tests in 3 suites passed"))
        XCTAssertTrue(DirectTestRun.ranXCTestTests(in: "Building…\n[3/12] Testing CoreTests.ParserTests/testEmpty\n"))
        XCTAssertFalse(DirectTestRun.ranXCTestTests(in: "[3/12] Compiling Core Parser.swift\n"))
    }
}

private extension DirectTestRun {
    /// A run of one bundle, on macOS unless `platform` says otherwise.
    init(
        platform: Platform? = nil,
        xctest: String? = "/Xcode/usr/bin/xctest",
        arguments: [String] = ["--skip-build"],
        xctestBundles: Set<String> = []
    ) {
        self.init(
            platform: platform ?? .macOS(helper: "/h", platformDeveloperFolder: "/P", xctest: xctest),
            productsFolder: ".build/out/Products/Debug",
            bundles: ["CoreTests"],
            testFiles: [:],
            arguments: arguments,
            xctestBundles: xctestBundles
        )
    }
}
