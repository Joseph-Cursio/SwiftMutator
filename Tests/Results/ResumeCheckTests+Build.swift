@testable import muterCore
import XCTest

extension ResumeCheckTests {
    func test_aChangedBuildToolchainOrSDKROOT_refuses_unlessForced_andForcingNamesIt() {
        let cases: [(provenance: Provenance, difference: ResumeCheck.Difference)] = [
            (
                provenance(executableSHA256: "b916"),
                .init(name: "swiftMutator.executableSHA256", was: #""9f2c""#, isNow: #""b916""#)
            ),
            (
                provenance(testCommandVersion: "Apple Swift version 6.3.3\nTarget: arm64-apple-macosx26.0"),
                .init(
                    name: "toolchain.testCommandVersion",
                    was: #""Apple Swift version 6.4""#,
                    isNow: #""Apple Swift version 6.3.3\nTarget: arm64-apple-macosx26.0""#
                )
            ),
            (
                provenance(environment: ["SDKROOT": "/Applications/Xcode.app/MacOSX27.0.sdk"]),
                .init(
                    name: "toolchain.environment",
                    was: #"{"SDKROOT":"/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"}"#,
                    isNow: #"{"SDKROOT":"/Applications/Xcode.app/MacOSX27.0.sdk"}"#
                )
            ),
            (
                provenance(environment: [:]),
                .init(
                    name: "toolchain.environment",
                    was: #"{"SDKROOT":"/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"}"#,
                    isNow: "{}"
                )
            ),
        ]

        for (provenance, difference) in cases {
            let name = difference.name

            XCTAssertEqual(check(current(provenance: provenance)).refusals, [.needsForce(difference)], name)
            XCTAssertEqual(check(current(provenance: provenance)).forced, [], name)
            XCTAssertEqual(
                check(current(provenance: provenance), forcing: true),
                ResumeCheck.Verdict(forced: [name]),
                name
            )
        }
    }

    func test_needsForce_saysWhatChangedAndThatForceLetsItThrough() {
        XCTAssertEqual(
            String(
                describing: ResumeRefusal.needsForce(
                    .init(name: "toolchain.testCommandVersion", was: #""6.3.3""#, isNow: #""6.4""#)
                )
            ),
            #"The toolchain (toolchain.testCommandVersion) was "6.3.3" and is "6.4" now. "#
                + "--force-resume reuses the results anyway."
        )
        XCTAssertEqual(
            "\(ResumeRefusal.needsForce(.init(name: "swiftMutator.executableSHA256", was: #""9f2c""#, isNow: nil)))",
            #"SwiftMutator (swiftMutator.executableSHA256) was "9f2c" and is unknown now. "#
                + "--force-resume reuses the results anyway."
        )
        XCTAssertEqual(
            "\(ResumeRefusal.needsForce(.init(name: "swiftMutator.executableSHA256", was: nil, isNow: nil)))",
            "SwiftMutator (swiftMutator.executableSHA256) is unknown, so it may have changed. "
                + "--force-resume reuses the results anyway."
        )
    }

    func test_anUnidentifiedBuild_needsForce() {
        let unidentified = provenance(executableSHA256: nil)
        let difference = ResumeCheck.Difference(name: "swiftMutator.executableSHA256", was: nil, isNow: nil)

        let verdict = check(current(provenance: unidentified), recorded: header(of: current(provenance: unidentified)))

        XCTAssertEqual(verdict.refusals, [.needsForce(difference)])
        XCTAssertEqual(
            check(current(provenance: unidentified), recorded: header(of: current()), forcing: true).forced,
            ["swiftMutator.executableSHA256"]
        )
    }

    func test_aToolchainWhoseVersionIsUnknown_needsForce() {
        let unidentified = provenance(testCommandVersion: nil)

        let verdict = check(current(provenance: unidentified), recorded: header(of: current(provenance: unidentified)))

        XCTAssertEqual(
            verdict.refusals,
            [.needsForce(.init(name: "toolchain.testCommandVersion", was: nil, isNow: nil))]
        )
    }

    func test_aWrapperTestCommand_isIdentifiedByItsSHA256_notItsVersion() {
        let wrapper = MuterConfiguration(executable: "/project/Scripts/test.sh", arguments: [])
        let hashed = provenance(testCommandVersion: nil, testExecutableSHA256: "77aa")
        let same = current(configuration: wrapper, provenance: hashed)

        XCTAssertEqual(check(same, recorded: header(of: same)), ResumeCheck.Verdict())

        let edited = current(
            configuration: wrapper,
            provenance: provenance(testCommandVersion: nil, testExecutableSHA256: "88bb")
        )
        XCTAssertEqual(
            check(edited, recorded: header(of: same)).refusals,
            [.needsForce(.init(name: "toolchain.testExecutableSHA256", was: #""77aa""#, isNow: #""88bb""#))]
        )

        let unreadable = current(configuration: wrapper, provenance: provenance(testCommandVersion: nil))
        XCTAssertEqual(
            check(unreadable, recorded: header(of: unreadable)).refusals,
            [.needsForce(.init(name: "toolchain.testExecutableSHA256", was: nil, isNow: nil))]
        )
    }

    func test_whatTheBuildAndToolchainDontIdentify_isNotCompared() {
        let elsewhere = Provenance(
            swiftMutator: .init(
                version: "2.0.0",
                executablePath: "/opt/homebrew/bin/swift-mutator",
                executableSHA256: Provenance.fixture.swiftMutator.executableSHA256
            ),
            toolchain: Provenance.fixture.toolchain,
            processIdentifier: 4_321,
            host: "studio.local",
            arguments: ["run", "--resume", "results.jsonl"]
        )

        XCTAssertEqual(check(current(provenance: elsewhere)), ResumeCheck.Verdict())
    }

    func test_forceNeverCoversConfigurationOrSelection() {
        let changed = current(
            configuration: MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test", "--parallel"]),
            operators: ["SwapTernary"],
            provenance: provenance(executableSHA256: "b916")
        )

        let verdict = check(changed, forcing: true)

        XCTAssertEqual(
            verdict.refusals,
            [
                .configurationChanged(.init(name: "arguments", was: #"["test"]"#, isNow: #"["test","--parallel"]"#)),
                .selectionChanged(
                    .init(name: "operators", was: #"["RelationalOperatorReplacement"]"#, isNow: #"["SwapTernary"]"#)
                ),
            ]
        )
        XCTAssertEqual(verdict.forced, ["swiftMutator.executableSHA256"])
    }
}
