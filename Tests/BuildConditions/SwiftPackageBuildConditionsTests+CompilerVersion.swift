@testable import muterCore
import SwiftIfConfig
import XCTest

extension SwiftPackageBuildConditionsTests {
    func test_theCompilersVersion_isWhatTheSameSwiftSays() async throws {
        describingWithVersion()

        let conditions = try await conditions()

        XCTAssertEqual(conditions.everyTarget.compiler, VersionTuple(6, 2, 1))
        XCTAssertEqual(process.commandsRun.last, [swift, "--version"])
    }

    // A toolchain, a toolset or a Swift SDK the command picks, or `SWIFT_EXEC`, may build with another compiler.
    func test_theCompilersVersion_isUnknown_whenAnotherCompilerMayBuild() async throws {
        let cases: [(arguments: [String], environment: [String: String])] = [
            (["test", "--toolchain", "/other.xctoolchain"], [:]),
            (["test", "--toolset=toolset.json"], [:]),
            (["test", "--swift-sdk", "wasm32-unknown-wasi"], [:]),
            (["test"], ["SWIFT_EXEC": "/my/swiftc"]),
        ]
        for (arguments, environment) in cases {
            describingWithVersion()

            let conditions = try await conditions(arguments: arguments, environment: environment)

            XCTAssertNil(conditions.everyTarget.compiler, "\(arguments) \(environment)")
            XCTAssertFalse(process.commandsRun.contains([swift, "--version"]), "\(arguments) \(environment)")
        }
    }

    func test_theCompilersVersion_isUnknown_whenItCantBeRead() async throws {
        describing(settings: "[]")

        let conditions = try await conditions()

        XCTAssertNil(conditions.everyTarget.compiler)
    }
}
