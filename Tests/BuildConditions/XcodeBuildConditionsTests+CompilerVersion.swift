@testable import muterCore
import SwiftIfConfig
import XCTest

extension XcodeBuildConditionsTests {
    func test_theCompilersVersion_isWhatTheToolchainsSwiftcSays() async throws {
        let toolchain = [
            "TOOLCHAIN_DIR": "/Xcode/Default.xctoolchain", "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault",
        ]
        settingsAndVersion(test: [macOSTarget.merging(toolchain) { first, _ in first }])

        let conditions = try await conditions(arguments: ["-scheme", "App", "test"])

        XCTAssertEqual(conditions.compiler, VersionTuple(6, 4, 2))
        XCTAssertEqual(process.commandsRun.last, ["/Xcode/Default.xctoolchain/usr/bin/swiftc", "--version"])
    }

    // `TOOLCHAIN_DIR` may not follow `-toolchain`, and `SWIFT_EXEC` or another toolchain builds with another compiler.
    func test_theCompilersVersion_isUnknown_whenAnotherCompilerMayBuild() async throws {
        let toolchain = [
            "TOOLCHAIN_DIR": "/Xcode/Default.xctoolchain", "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault",
        ]
        let cases: [(settings: [String: String], arguments: [String])] = [
            (toolchain, ["-toolchain", "swift", "test"]),
            (toolchain.merging(["SWIFT_EXEC": "/my/swiftc"]) { _, new in new }, ["test"]),
            (toolchain.merging(["TOOLCHAINS": "org.swift.64202601"]) { _, new in new }, ["test"]),
            (toolchain.filter { $0.key != "TOOLCHAINS" }, ["test"]),
            (toolchain.filter { $0.key != "TOOLCHAIN_DIR" }, ["test"]),
        ]
        for (settings, arguments) in cases {
            settingsAndVersion(test: [macOSTarget.merging(settings) { first, _ in first }])

            let conditions = try await conditions(arguments: arguments)

            XCTAssertNil(conditions.compiler, "\(settings) \(arguments)")
            XCTAssertFalse(process.commandsRun.contains { $0.last == "--version" }, "\(settings) \(arguments)")
        }
    }

    // A target xcodebuild doesn't report, such as the framework the tests test, may set its own.
    func test_theCompilersVersion_isUnknown_whenABuildFileNamesToolchainsOrSwiftExec() async throws {
        let target = macOSTarget.merging([
            "TOOLCHAIN_DIR": "/Xcode/Default.xctoolchain", "TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault",
        ]) { first, _ in first }
        for setting in ["TOOLCHAINS = org.swift.633202606251a;", "SWIFT_EXEC = /my/swiftc;"] {
            try write(setting, to: "Framework.xcconfig")
            settingsAndVersion(test: [target])

            let conditions = try await conditions(arguments: ["test"])

            XCTAssertNil(conditions.compiler, setting)
        }
    }

    // Or set it in a build file SwiftMutator didn't read.
    func test_theCompilersVersion_isUnknown_whenABuildFileItDidntReadMaySetIt() async throws {
        try write(projectFile(basedOn: "Base.xcconfig", inGroupAt: "../Shared"), to: "App.xcodeproj/project.pbxproj")
        settingsAndVersion(test: [withXcodesToolchain([:])])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNil(conditions.compiler)
        XCTAssertFalse(process.commandsRun.contains { $0.last == "--version" })
    }

    func test_theCompilersVersion_isUnknown_whenTheTargetsToolchainsDiffer() async throws {
        let shared = macOSTarget.merging(["TOOLCHAINS": "com.apple.dt.toolchain.XcodeDefault"]) { first, _ in first }
        settingsAndVersion(test: [
            shared.merging(["TOOLCHAIN_DIR": "/one"]) { first, _ in first },
            shared.merging(["TOOLCHAIN_DIR": "/two"]) { first, _ in first },
        ])

        let conditions = try await conditions(arguments: ["test"])

        XCTAssertNil(conditions.compiler)
    }
}
