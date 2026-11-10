@testable import muterCore
import SwiftIfConfig
import XCTest

extension XcodeBuildConditionsTests {
    /// An SDK's `PLATFORM_NAME`, and the OS and target environment it builds for.
    private struct SDKPlatform {
        let name: String
        let system: String
        let environment: String?

        init(_ name: String, _ system: String, _ environment: String?) {
            self.name = name
            self.system = system
            self.environment = environment
        }
    }

    func test_eachPlatform() async throws {
        for platform in [
            SDKPlatform("macosx", "macOS", nil),
            SDKPlatform("iphoneos", "iOS", nil),
            SDKPlatform("iphonesimulator", "iOS", "simulator"),
            SDKPlatform("appletvos", "tvOS", nil),
            SDKPlatform("appletvsimulator", "tvOS", "simulator"),
            SDKPlatform("watchos", "watchOS", nil),
            SDKPlatform("watchsimulator", "watchOS", "simulator"),
            SDKPlatform("xros", "visionOS", nil),
            SDKPlatform("xrsimulator", "visionOS", "simulator"),
            SDKPlatform("driverkit", "DriverKit", nil),
        ] {
            settings(test: [["PLATFORM_NAME": platform.name, "ARCHS": "arm64"]], build: [])

            let conditions = try await conditions(arguments: ["test"])

            XCTAssertEqual(conditions.platform?.system, platform.system, platform.name)
            XCTAssertEqual(conditions.platform?.environment, platform.environment, platform.name)
        }
    }

    func test_MacCatalyst_isIOSInItsEnvironment() async throws {
        settings(test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64", "IS_MACCATALYST": "YES"]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertEqual(conditions.platform?.system, "iOS")
        XCTAssertEqual(conditions.platform?.environment, "macCatalyst")
    }

    func test_aPlatformItDoesntKnow_isNoPlatform() async throws {
        settings(test: [["PLATFORM_NAME": "newos", "ARCHS": "arm64"]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNil(conditions.platform)
    }

    func test_targetsForDifferentPlatforms_areNoPlatform() async throws {
        settings(
            test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64"], ["PLATFORM_NAME": "iphoneos", "ARCHS": "arm64"]],
            build: []
        )

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNil(conditions.platform)
    }

    // The settings report one, whichever they can be.
    func test_severalDestinations_areNoPlatform() async throws {
        settings(test: [["PLATFORM_NAME": "iphonesimulator", "ARCHS": "arm64"]], build: [])

        let conditions = try await conditions(arguments: ["-destination", "a", "-destination", "b", "test"])

        XCTAssertNil(conditions.platform)
    }

    func test_noArchitectures_areNoPlatform() async throws {
        settings(test: [["PLATFORM_NAME": "macosx"]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNil(conditions.platform)
    }

    func test_aBuildForSeveralArchitectures_keepsThemAll() async throws {
        settings(test: [["PLATFORM_NAME": "iphonesimulator", "ARCHS": "arm64 x86_64"]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertEqual(conditions.platform?.architectures, ["arm64", "x86_64"])
    }
}
