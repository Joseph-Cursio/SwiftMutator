@testable import muterCore
import XCTest

extension PackageSchemeBuildConditionsTests {
    /// Build settings the test command's arguments or environment give, which the manifest doesn't have, and part of
    /// the reason that is a failure.
    private struct UnreadSettings {
        let arguments: [String]
        let environment: [String: String]
        let reason: String

        init(_ arguments: [String], _ environment: [String: String], _ reason: String) {
            self.arguments = arguments
            self.environment = environment
            self.reason = reason
        }
    }

    // A script that runs xcodebuild may give it a configuration, build settings or a destination of its own; another
    // xcodebuild may run any Xcode.
    func test_anExecutableThatIsntAnXcodesXcodebuild_isAFailure() async throws {
        for (executable, reason) in [
            ("/repo/scripts/test.sh", "xcodebuild reported no build settings"),
            ("/opt/tools/bin/xcodebuild", "can't tell which Xcode"),
        ] {
            stubPackage()

            let result = await result(
                arguments: ["-scheme", "P-Package", "-configuration", "Debug", "test"],
                executable: executable
            )

            guard case let .failure(failure) = result else {
                XCTFail("\(executable): \(result)")
                continue
            }
            XCTAssertTrue(failure.reason.contains(reason), failure.reason)
        }
    }

    // xcodebuild opens a project or workspace beside the manifest before the package, and `-project`'s or
    // `-workspace`'s; their settings are missing for another reason.
    func test_withAProjectOrWorkspace_noSettingsIsStillAFailure() async throws {
        stubPackage()
        try write("", to: "App.xcodeproj/project.pbxproj")
        let besideAProject = await result(arguments: ["-scheme", "P-Package", "test"])
        project = try makeTemporaryDirectory()
        try write("// swift-tools-version:6.0", to: "Package.swift")
        let namingOne = await result(arguments: ["-workspace", "W.xcworkspace", "-scheme", "P", "test"])

        for result in [besideAProject, namingOne] {
            XCTAssertEqual(
                result,
                .failure(BuildConditionsUnavailable(reason: "xcodebuild reported no build settings"))
            )
        }
    }

    // What the manifest says may then not be what the build compiles with.
    func test_buildSettingsTheManifestDoesntHave_areAFailure() async throws {
        let cases = [
            UnreadSettings(["-scheme", "P-Package", "OTHER_SWIFT_FLAGS=-DFOO", "test"], [:], "sets build settings"),
            UnreadSettings(
                ["-scheme", "P-Package", "-xcconfig", "/ci/Overrides.xcconfig", "test"],
                [:],
                "an `.xcconfig`"
            ),
            UnreadSettings(
                ["-scheme", "P-Package", "test"],
                ["XCODE_XCCONFIG_FILE": "/ci/Overrides.xcconfig"],
                "an `.xcconfig`"
            ),
            UnreadSettings(["-scheme", "P-Package", "-configuration", "Beta", "test"], [:], "another configuration"),
            UnreadSettings(["-scheme", "P-Package", "test"], [:], "give it with `-configuration`"),
        ] + [
            "OTHER_SWIFT_FLAGS", "OTHER_SWIFT_FLAGS_Debug", "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "SWIFT_VERSION",
            "ARCHS", "SDKROOT",
        ].map { name in
            UnreadSettings(
                ["-scheme", "P-Package", "-configuration", "Debug", "test"],
                [name: "-DFOO"],
                "environment sets \(name)"
            )
        }
        for settings in cases {
            stubPackage()

            let result = await result(arguments: settings.arguments, environment: settings.environment)

            guard case let .failure(failure) = result else {
                XCTFail("\(settings.arguments) \(settings.environment): \(result)")
                continue
            }
            XCTAssertTrue(failure.reason.contains(settings.reason), failure.reason)
        }
    }
}
