@testable import muterCore
import XCTest

extension XcodeBuildConditionsTests {
    func test_theSDKsModules() async throws {
        let platforms = project + "/Developer/Platforms"
        let macOS = try makeSDK(in: platforms, named: "MacOSX", frameworks: ["AppKit", "SwiftUI"])
        _ = try makeSDK(in: platforms, named: "iPhoneOS", frameworks: ["UIKit", "SwiftUI"])
        settings(test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64", "SDKROOT": macOS]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertEqual(conditions.platform?.modules?.present, ["AppKit", "SwiftUI", "Swift"])
        XCTAssertEqual(conditions.platform?.modules?.absent, ["UIKit"])
    }

    // A framework with no `Modules` folder can't be imported.
    func test_aFrameworkWithoutModules_isNotAModule() throws {
        let platforms = project + "/Developer/Platforms"
        let sdk = try makeSDK(in: platforms, named: "MacOSX", frameworks: ["AppKit"])
        try FileManager.default.createDirectory(
            atPath: sdk + "/System/Library/Frameworks/HeadersOnly.framework/Headers",
            withIntermediateDirectories: true
        )

        let modules = try XCTUnwrap(BuildConditions.SDKModules(sdk: sdk, fileManager: FileManager.default))

        XCTAssertFalse(modules.present.contains("HeadersOnly"))
    }

    func test_MacCatalyst_leavesCanImportUndecided() async throws {
        let sdk = try makeSDK(in: project + "/Developer/Platforms", named: "MacOSX", frameworks: ["AppKit"])
        settings(
            test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64", "SDKROOT": sdk, "IS_MACCATALYST": "YES"]],
            build: []
        )

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNotNil(conditions.platform)
        XCTAssertNil(conditions.platform?.modules)
    }

    // So nothing reads as absent because the SDK couldn't be read.
    func test_anSDKThatListsNothing_givesNoModules() async throws {
        settings(test: [["PLATFORM_NAME": "macosx", "ARCHS": "arm64", "SDKROOT": project + "/nothing"]], build: [])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNotNil(conditions.platform)
        XCTAssertNil(conditions.platform?.modules)
    }
}
