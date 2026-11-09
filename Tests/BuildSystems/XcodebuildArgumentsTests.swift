@testable import muterCore
import XCTest

final class XcodebuildArgumentsTests: XCTestCase {
    // An option takes a value only where xcodebuild takes one for it, so a value never reads as an action, and an
    // option it doesn't list, such as a wrapper script's, stands alone.
    func test_eachArgument_isReadWithItsValue() {
        let read = XcodebuildArguments([
            "-scheme", "test", "-only-testing:AppTests", "-only-testing", "@tests.txt", "-quiet", "--wrapper-flag",
            "value", "OTHER_SWIFT_FLAGS=-DMOCKS", "clean", "test", "-derivedDataPath",
        ])

        XCTAssertEqual(read.arguments, [
            .init(kind: .option, name: "-scheme", written: ["-scheme", "test"]),
            .init(kind: .option, name: "-only-testing", written: ["-only-testing:AppTests"]),
            .init(kind: .option, name: "-only-testing", written: ["-only-testing", "@tests.txt"]),
            .init(kind: .option, name: "-quiet", written: ["-quiet"]),
            .init(kind: .option, name: "--wrapper-flag", written: ["--wrapper-flag"]),
            .init(kind: .other, name: "value", written: ["value"]),
            .init(kind: .other, name: "OTHER_SWIFT_FLAGS=-DMOCKS", written: ["OTHER_SWIFT_FLAGS=-DMOCKS"]),
            .init(kind: .action, name: "clean", written: ["clean"]),
            .init(kind: .action, name: "test", written: ["test"]),
            // The last argument has no value to take.
            .init(kind: .option, name: "-derivedDataPath", written: ["-derivedDataPath"]),
        ])
    }

    func test_aRunFromTheTestRunFile_leavesOutWhatWouldBreakOrSlowIt_eachWithItsValue() {
        let arguments = XcodebuildArguments([
            "-xctestrun", "App.xctestrun", "-testProductsPath", "App.xctestproducts",
            "-resultBundlePath", "out.xcresult", "-enableCodeCoverage", "YES", "-enumerate-tests",
            "-resultStreamPath", "stream.json", "-quiet", "-skip-testing:AppUITests", "build-for-testing",
        ])

        XCTAssertEqual(arguments.forARunFromTheTestRunFile(worker: nil, filtered: false), ["-skip-testing:AppUITests"])
    }

    func test_refusal_isTheFirstArgumentThatBreaksACall_andNoneForTestCleanOrBuild() {
        XCTAssertNil(XcodebuildArguments(["-scheme", "archive", "clean", "build", "test", "-quiet"]).refusal)
        XCTAssertNil(XcodebuildArguments(["-enableCodeCoverage", "YES", "test"]).refusal)
        XCTAssertEqual(
            XcodebuildArguments(["-enumerate-tests", "-xctestrun", "App.xctestrun"]).refusal,
            "`-enumerate-tests` in `arguments` lists the tests without running them, so every mutant would survive. "
                + "Leave it out."
        )
        for action in ["analyze", "archive", "install", "installsrc", "docbuild"] {
            XCTAssertEqual(
                XcodebuildArguments([action, "test"]).refusal,
                "`\(action)` in `arguments` isn't an action SwiftMutator can test with: it runs your tests with "
                    + "`test`, and builds them with `build-for-testing` itself. Give `test` as the action instead.",
                action
            )
        }
    }

    // Each says what to do instead.
    func test_eachRefusal_namesTheArgument_andWhatToDoInstead() {
        let refusals: [(arguments: [String], reason: String)] = [
            (
                ["test-without-building"],
                "`test-without-building` in `arguments` is an action SwiftMutator runs itself: it builds once with "
                    + "`build-for-testing`, then tests each mutant with `test-without-building`. Give `test` as the "
                    + "action instead."
            ),
            (
                ["-xctestrun", "App.xctestrun", "test"],
                "`-xctestrun` in `arguments` names what SwiftMutator tests each mutant from itself, the `.xctestrun` "
                    + "its build for testing writes. Leave it out, and name the project or workspace and the scheme "
                    + "to build, with `-project` or `-workspace` and `-scheme`."
            ),
            (
                ["-testProductsPath", "App.xctestproducts", "test"],
                "`-testProductsPath` in `arguments` can't be used: each mutant's run tests from the `.xctestrun` "
                    + "SwiftMutator's build for testing writes, which xcodebuild won't take with it. Leave it out."
            ),
            (
                ["-resultBundlePath", "out.xcresult", "test"],
                "`-resultBundlePath` in `arguments` would have SwiftMutator's coverage run, build for testing and "
                    + "baseline write one result bundle, and xcodebuild fails a run whose bundle is already there. "
                    + "Leave it out."
            ),
        ]
        for (arguments, reason) in refusals {
            XCTAssertEqual(XcodebuildArguments(arguments).refusal, reason, "\(arguments)")
        }
    }

    // `build` would build a second time, and `test` would run every test, in the build for testing's place.
    func test_theBuild_leavesOutTheTestAndBuildActions_butNotAValueThatReadsLikeOne() {
        XCTAssertEqual(
            XcodebuildArguments(["-scheme", "build", "clean", "build", "test"]).forTheBuild,
            ["-scheme", "build", "clean"]
        )
    }

    func test_theCoverageRun_leavesOutTheTestCommandsEnableCodeCoverage_withItsValue() {
        XCTAssertEqual(
            XcodebuildArguments(["-enableCodeCoverage", "NO", "-scheme", "App", "test"]).forTheCoverageRun,
            ["-scheme", "App", "test"]
        )
    }
}
