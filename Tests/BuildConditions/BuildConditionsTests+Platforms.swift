@testable import muterCore
import XCTest

extension BuildConditionsTests {
    func test_theOS_undecidedWithoutAPlatform() {
        var conditions = conditions(custom: [[]])

        XCTAssertEqual(holds("os(macOS)", in: conditions), .holds)
        XCTAssertEqual(holds("os(OSX)", in: conditions), .holds)
        XCTAssertEqual(holds("os(iOS)", in: conditions), .doesntHold)

        conditions.platform = nil
        XCTAssertEqual(holds("os(macOS)", in: conditions), .undecided)
        XCTAssertEqual(holds("arch(arm64)", in: conditions), .undecided)
        XCTAssertEqual(holds("targetEnvironment(simulator)", in: conditions), .undecided)
        XCTAssertEqual(holds("canImport(AppKit)", in: conditions), .undecided)
    }

    func test_visionOS_answersToItsOldNameToo() {
        var conditions = conditions(custom: [[]])
        conditions.platform = .init(system: "visionOS", architectures: ["arm64"])

        XCTAssertEqual(holds("os(visionOS)", in: conditions), .holds)
        XCTAssertEqual(holds("os(xrOS)", in: conditions), .holds)
    }

    func test_theEnvironment() {
        var conditions = conditions(custom: [[]])
        XCTAssertEqual(holds("targetEnvironment(simulator)", in: conditions), .doesntHold)

        conditions.platform = .init(system: "iOS", environment: "simulator", architectures: ["arm64"])
        XCTAssertEqual(holds("targetEnvironment(simulator)", in: conditions), .holds)
        XCTAssertEqual(holds("targetEnvironment(macCatalyst)", in: conditions), .doesntHold)

        conditions.platform = .init(system: "iOS", environment: "macCatalyst", architectures: ["arm64"])
        XCTAssertEqual(holds("targetEnvironment(macCatalyst)", in: conditions), .holds)
        XCTAssertEqual(holds("os(iOS)", in: conditions), .holds)
        XCTAssertEqual(holds("os(macOS)", in: conditions), .doesntHold)
    }

    func test_theArchitecture_ofABuildForOne() {
        let conditions = conditions(custom: [[]])

        XCTAssertEqual(holds("arch(arm64)", in: conditions), .holds)
        XCTAssertEqual(holds("arch(x86_64)", in: conditions), .doesntHold)
    }

    // A build for two compiles each branch for one of them, though the tests run only one.
    func test_theArchitecture_ofABuildForSeveral_isUndecided_unlessItIsNoneOfThem() {
        var conditions = conditions(custom: [[]])
        conditions.platform = .init(system: "iOS", architectures: ["arm64", "x86_64"])

        XCTAssertEqual(holds("arch(arm64)", in: conditions), .undecided)
        XCTAssertEqual(holds("arch(x86_64)", in: conditions), .undecided)
        XCTAssertEqual(holds("arch(arm)", in: conditions), .doesntHold)
    }

    // As for a package's scheme, whose settings xcodebuild doesn't report: the platform is known, but not its
    // architectures.
    func test_unknownArchitectures_leaveArchPointerWidthAndByteOrderUndecided() {
        var conditions = conditions(custom: [[]])
        conditions.platform = .init(system: "iOS", environment: "simulator", architectures: nil)

        XCTAssertEqual(holds("os(iOS) && targetEnvironment(simulator)", in: conditions), .holds)
        XCTAssertEqual(holds("arch(arm64)", in: conditions), .undecided)
        XCTAssertEqual(holds("arch(arm)", in: conditions), .undecided)
        XCTAssertEqual(holds("_pointerBitWidth(_64)", in: conditions), .undecided)
        XCTAssertEqual(holds("_endian(little)", in: conditions), .undecided)
    }

    func test_theArchitecture_arm64eAlsoAnswersToArm64() {
        var conditions = conditions(custom: [[]])
        conditions.platform = .init(system: "iOS", architectures: ["arm64e"])

        XCTAssertEqual(holds("arch(arm64)", in: conditions), .undecided)
        XCTAssertEqual(holds("arch(arm64e)", in: conditions), .undecided)
    }

    func test_theRuntime_andTheObjectFormat() {
        var conditions = conditions(custom: [[]])
        XCTAssertEqual(holds("_runtime(_ObjC)", in: conditions), .holds)
        XCTAssertEqual(holds("_runtime(_Native)", in: conditions), .doesntHold)

        conditions.platform = .init(system: "Linux", architectures: ["arm64"])
        XCTAssertEqual(holds("_runtime(_ObjC)", in: conditions), .doesntHold)
        XCTAssertEqual(holds("_runtime(_Native)", in: conditions), .holds)
    }

    func test_canImport_answersForTheSDKsModules() {
        let conditions = conditions(custom: [[]])

        XCTAssertEqual(holds("canImport(AppKit)", in: conditions), .holds)
        XCTAssertEqual(holds("canImport(UIKit)", in: conditions), .doesntHold)
    }

    // It may be a package's, or another target's in the project.
    func test_canImport_isUndecided_forAModuleInNoSDK() {
        XCTAssertEqual(holds("canImport(SomePackage)", in: conditions(custom: [[]])), .undecided)
    }

    func test_canImport_isUndecided_forASubmoduleOrAVersion() {
        let conditions = conditions(custom: [[]])

        XCTAssertEqual(holds("canImport(AppKit.Submodule)", in: conditions), .undecided)
        XCTAssertEqual(holds("canImport(AppKit, _version: 2)", in: conditions), .undecided)
    }

    func test_canImport_isUndecided_withoutTheSDKsModules() {
        var conditions = conditions(custom: [[]])
        conditions.platform?.modules = nil

        XCTAssertEqual(holds("canImport(AppKit)", in: conditions), .undecided)
        XCTAssertEqual(holds("canImport(UIKit)", in: conditions), .undecided)
    }
}
