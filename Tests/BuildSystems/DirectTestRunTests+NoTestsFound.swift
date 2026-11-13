@testable import muterCore
import XCTest

extension DirectTestRunTests {
    // With a test filter, a bundle it leaves no test in exits 69, as swift-testing's helper does, and `swift test`
    // takes that as a pass: a bundle of property tests alone, with the property tests skipped, must not fail the run.
    func test_aBundleWithNoTestToRun_passes_whenATestFilterIsGiven() async throws {
        let run = try await runAMutant(bundles: ["NoTests", "CoreTests"])

        XCTAssertEqual(run.outcome, .passed, run.testLog)
    }

    // Without one, no bundle should find no test, so a helper's 69 is a failure as any other status is.
    func test_theScriptWithoutATestFilter_takesNoStatusButZeroAsAPass() {
        let filtered = makeDirectTestRun(bundles: ["CoreTests"])
        let unfiltered = DirectTestRun(
            helper: helper.path,
            productsFolder: ".build/out/Products/Debug",
            bundles: ["CoreTests"],
            testFiles: [:],
            platformDeveloperFolder: "/Developer",
            arguments: ["--skip-build"]
        )

        XCTAssertTrue(filtered.script(in: worker).contains("[ $status -eq 0 ] || [ $status -eq 69 ] || failed=1"))
        XCTAssertTrue(unfiltered.script(in: worker).contains("[ $status -eq 0 ] || failed=1"))
        XCTAssertFalse(unfiltered.script(in: worker).contains("69"))
        XCTAssertTrue(unfiltered.adding(["--skip", "Properties"]).script(in: worker).contains("$status -eq 69"))
    }
}
