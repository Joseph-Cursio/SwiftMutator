@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

final class BuildConditionsTests: XCTestCase {
    private let macOS = BuildConditions.Platform(
        system: "macOS",
        architectures: ["arm64"],
        modules: .init(present: ["AppKit", "SwiftUI"], absent: ["UIKit"])
    )

    // MARK: Which clauses

    func test_ofAnIfsClauses_onlyTheOneThatHoldsCompiles() {
        let inactive = inactiveCode("""
        #if os(iOS)
        iOS()
        #elseif os(macOS)
        macOS()
        #elseif os(Linux)
        linux()
        #else
        other()
        #endif
        """)

        XCTAssertEqual(inactive, ["iOS()", "linux()", "other()"])
    }

    func test_whenNoConditionHolds_theElseCompiles() {
        let inactive = inactiveCode("""
        #if os(iOS)
        iOS()
        #else
        other()
        #endif
        """)

        XCTAssertEqual(inactive, ["iOS()"])
    }

    func test_undecidedCode_isKept_withTheElseAfterIt() {
        let inactive = inactiveCode("""
        #if canImport(SomePackage)
        package()
        #else
        other()
        #endif
        """)

        XCTAssertEqual(inactive, [])
    }

    // `SwiftIfConfig` gives false for a condition it can't evaluate, and `!` makes that true.
    func test_aNegatedUndecidedCondition_isUndecided() {
        let inactive = inactiveCode("""
        #if !canImport(SomePackage)
        other()
        #else
        package()
        #endif
        """)

        XCTAssertEqual(inactive, [])
    }

    // Whichever clause compiles, it isn't one after a condition that holds.
    func test_afterAnUndecidedClause_aConditionThatHolds_stillRulesOutTheClausesAfterIt() {
        let inactive = inactiveCode("""
        #if canImport(SomePackage)
        package()
        #elseif os(macOS)
        macOS()
        #else
        other()
        #endif
        """)

        XCTAssertEqual(inactive, ["other()"])
    }

    func test_afterAnUndecidedClause_aConditionThatDoesntHold_isInactive_andTheElseIsKept() {
        let inactive = inactiveCode("""
        #if canImport(SomePackage)
        package()
        #elseif os(iOS)
        iOS()
        #else
        other()
        #endif
        """)

        XCTAssertEqual(inactive, ["iOS()"])
    }

    func test_afterAClauseThatHolds_anUndecidedCondition_isInactive() {
        let inactive = inactiveCode("""
        #if os(macOS)
        macOS()
        #elseif canImport(SomePackage)
        package()
        #else
        other()
        #endif
        """)

        XCTAssertEqual(inactive, ["package()", "other()"])
    }

    func test_inAnActiveOrUndecidedClause_aNestedIfIsDecided() {
        let inactive = inactiveCode("""
        #if canImport(SomePackage)
        #if os(iOS)
        iOS()
        #else
        other()
        #endif
        #endif
        """)

        XCTAssertEqual(inactive, ["iOS()"])
    }

    func test_inAnInactiveClause_aNestedIfGivesNoRegionOfItsOwn() {
        let regions = regions(
            in: """
            #if os(iOS)
            #if os(macOS)
            never()
            #endif
            iOS()
            #endif
            """
        )

        XCTAssertEqual(regions.count, 1)
    }

    func test_wholeDeclarations_membersAndPostfixExpressions_areFound() {
        let inactive = inactiveCode("""
        #if os(iOS)
        func f() {}
        #endif
        struct S {
            #if os(iOS)
            var m = 1
            #endif
        }
        let v = view
            #if os(iOS)
            .modifier()
            #endif
        """)

        XCTAssertEqual(inactive, ["func f() {}", "var m = 1", ".modifier()"])
    }

    func test_aFileWithNoIf_hasNoInactiveCode() {
        XCTAssertEqual(inactiveCode("let a = 1"), [])
    }

    // MARK: Custom conditions

    func test_aConditionEveryTargetSets_holds() {
        let conditions = conditions(custom: [["DEBUG"], ["DEBUG", "OTHER"]])

        XCTAssertEqual(holds("DEBUG", in: conditions), true)
    }

    func test_aConditionNoTargetSets_doesntHold() {
        let conditions = conditions(custom: [["DEBUG"]])

        XCTAssertEqual(holds("NOBODY", in: conditions), false)
    }

    func test_aConditionOnlySomeTargetsSet_isUndecided() {
        let conditions = conditions(custom: [["DEBUG"], ["DEBUG", "OTHER"]])

        XCTAssertNil(holds("OTHER", in: conditions))
    }

    func test_aConditionSomethingElseMightSet_isUndecided() {
        var conditions = conditions(custom: [["DEBUG"]])
        conditions.undecidedConditions = ["MENTIONED"]

        XCTAssertNil(holds("MENTIONED", in: conditions))
    }

    // A condition every reported target sets is what the build uses, whatever a build file also says.
    func test_aConditionEveryTargetSets_holdsEvenIfABuildFileMentionsIt() {
        var conditions = conditions(custom: [["DEBUG"]])
        conditions.undecidedConditions = ["DEBUG"]

        XCTAssertEqual(holds("DEBUG", in: conditions), true)
    }

    // Xcode sets `SWIFT_PACKAGE` for a local package's code, and SwiftPM others for targets with resources.
    func test_aBuildSystemsOwnCondition_isUndecided_unlessEveryTargetSetsIt() {
        XCTAssertNil(holds("SWIFT_PACKAGE", in: conditions(custom: [["DEBUG"]])))
        XCTAssertNil(holds("SWIFT_MODULE_RESOURCE_BUNDLE_AVAILABLE", in: conditions(custom: [["DEBUG"]])))
        XCTAssertEqual(holds("SWIFT_PACKAGE", in: conditions(custom: [["SWIFT_PACKAGE"]])), true)
    }

    func test_withNoTargets_noConditionIsDecided() {
        XCTAssertNil(holds("DEBUG", in: conditions(custom: [])))
    }

    // MARK: Platforms

    func test_theOS_undecidedWithoutAPlatform() {
        var conditions = conditions(custom: [[]])

        XCTAssertEqual(holds("os(macOS)", in: conditions), true)
        XCTAssertEqual(holds("os(OSX)", in: conditions), true)
        XCTAssertEqual(holds("os(iOS)", in: conditions), false)

        conditions.platform = nil
        XCTAssertNil(holds("os(macOS)", in: conditions))
        XCTAssertNil(holds("arch(arm64)", in: conditions))
        XCTAssertNil(holds("targetEnvironment(simulator)", in: conditions))
        XCTAssertNil(holds("canImport(AppKit)", in: conditions))
    }

    func test_visionOS_answersToItsOldNameToo() {
        var conditions = conditions(custom: [[]])
        conditions.platform = .init(system: "visionOS", architectures: ["arm64"])

        XCTAssertEqual(holds("os(visionOS)", in: conditions), true)
        XCTAssertEqual(holds("os(xrOS)", in: conditions), true)
    }

    func test_theEnvironment() {
        var conditions = conditions(custom: [[]])
        XCTAssertEqual(holds("targetEnvironment(simulator)", in: conditions), false)

        conditions.platform = .init(system: "iOS", environment: "simulator", architectures: ["arm64"])
        XCTAssertEqual(holds("targetEnvironment(simulator)", in: conditions), true)
        XCTAssertEqual(holds("targetEnvironment(macCatalyst)", in: conditions), false)

        conditions.platform = .init(system: "iOS", environment: "macCatalyst", architectures: ["arm64"])
        XCTAssertEqual(holds("targetEnvironment(macCatalyst)", in: conditions), true)
        XCTAssertEqual(holds("os(iOS)", in: conditions), true)
        XCTAssertEqual(holds("os(macOS)", in: conditions), false)
    }

    func test_theArchitecture_ofABuildForOne() {
        let conditions = conditions(custom: [[]])

        XCTAssertEqual(holds("arch(arm64)", in: conditions), true)
        XCTAssertEqual(holds("arch(x86_64)", in: conditions), false)
    }

    // A build for two compiles each branch for one of them, though the tests run only one.
    func test_theArchitecture_ofABuildForSeveral_isUndecided_unlessItIsNoneOfThem() {
        var conditions = conditions(custom: [[]])
        conditions.platform = .init(system: "iOS", architectures: ["arm64", "x86_64"])

        XCTAssertNil(holds("arch(arm64)", in: conditions))
        XCTAssertNil(holds("arch(x86_64)", in: conditions))
        XCTAssertEqual(holds("arch(arm)", in: conditions), false)
    }

    func test_theArchitecture_arm64eAlsoAnswersToArm64() {
        var conditions = conditions(custom: [[]])
        conditions.platform = .init(system: "iOS", architectures: ["arm64e"])

        XCTAssertNil(holds("arch(arm64)", in: conditions))
        XCTAssertNil(holds("arch(arm64e)", in: conditions))
    }

    func test_theRuntime_andTheObjectFormat() {
        var conditions = conditions(custom: [[]])
        XCTAssertEqual(holds("_runtime(_ObjC)", in: conditions), true)
        XCTAssertEqual(holds("_runtime(_Native)", in: conditions), false)

        conditions.platform = .init(system: "Linux", architectures: ["arm64"])
        XCTAssertEqual(holds("_runtime(_ObjC)", in: conditions), false)
        XCTAssertEqual(holds("_runtime(_Native)", in: conditions), true)
    }

    // MARK: canImport

    func test_canImport_answersForTheSDKsModules() {
        let conditions = conditions(custom: [[]])

        XCTAssertEqual(holds("canImport(AppKit)", in: conditions), true)
        XCTAssertEqual(holds("canImport(UIKit)", in: conditions), false)
    }

    // It may be a package's, or another target's in the project.
    func test_canImport_isUndecided_forAModuleInNoSDK() {
        XCTAssertNil(holds("canImport(SomePackage)", in: conditions(custom: [[]])))
    }

    func test_canImport_isUndecided_forASubmoduleOrAVersion() {
        let conditions = conditions(custom: [[]])

        XCTAssertNil(holds("canImport(AppKit.Submodule)", in: conditions))
        XCTAssertNil(holds("canImport(AppKit, _version: 2)", in: conditions))
    }

    func test_canImport_isUndecided_withoutTheSDKsModules() {
        var conditions = conditions(custom: [[]])
        conditions.platform?.modules = nil

        XCTAssertNil(holds("canImport(AppKit)", in: conditions))
        XCTAssertNil(holds("canImport(UIKit)", in: conditions))
    }

    // MARK: What isn't asked

    func test_whatDependsOnTheCompiler_isUndecided() {
        let conditions = conditions(custom: [[]])

        for condition in [
            "swift(>=5.0)", "swift(<1.0)", "compiler(>=5.0)", "_compiler_version(\"5.0\")", "hasFeature(Foo)",
            "hasAttribute(foo)", "_pointerBitWidth(_64)", "_endian(little)", "_hasAtomicBitWidth(_64)",
            "os(macOS) && swift(>=5.0)", "!compiler(>=5.0)",
        ] {
            XCTAssertNil(holds(condition, in: conditions), condition)
        }
    }

    func test_conditionsCombine() {
        let conditions = conditions(custom: [["DEBUG"]])

        XCTAssertEqual(holds("os(macOS) && DEBUG", in: conditions), true)
        XCTAssertEqual(holds("os(iOS) || DEBUG", in: conditions), true)
        XCTAssertEqual(holds("os(iOS) && DEBUG", in: conditions), false)
        XCTAssertEqual(holds("!(os(macOS) && DEBUG)", in: conditions), false)
        XCTAssertNil(holds("DEBUG && canImport(SomePackage)", in: conditions))
        // What the left side settles, an import on the right can't change, and the compiler doesn't try it.
        XCTAssertEqual(holds("os(iOS) && canImport(SomePackage)", in: conditions), false)
        XCTAssertEqual(holds("os(macOS) || canImport(SomePackage)", in: conditions), true)
    }

    // MARK: Files

    func test_aFilesConditions_areThoseOfItsTargets() {
        let project = ProjectBuildConditions(
            everyTarget: conditions(custom: [["DEBUG", "APP"], ["DEBUG", "LIB"]]),
            customConditionsOfFile: ["Sources/App/App.swift": [["DEBUG", "APP"]]]
        )

        XCTAssertEqual(holds("APP", in: project.conditions(ofFile: "Sources/App/App.swift")), true)
        XCTAssertEqual(holds("LIB", in: project.conditions(ofFile: "Sources/App/App.swift")), false)
        // A file no target is known to hold could be in any of them.
        XCTAssertNil(holds("APP", in: project.conditions(ofFile: "Other.swift")))
    }

    func test_aFileInTwoTargets_isDecidedOnlyWhereTheyAgree() {
        let project = ProjectBuildConditions(
            everyTarget: conditions(custom: [["A"], ["A", "B"]]),
            customConditionsOfFile: ["Shared.swift": [["A"], ["A", "B"]]]
        )

        XCTAssertEqual(holds("A", in: project.conditions(ofFile: "Shared.swift")), true)
        XCTAssertNil(holds("B", in: project.conditions(ofFile: "Shared.swift")))
    }

    func test_customConditionsInSwiftFlags() {
        XCTAssertEqual(
            customConditions(inSwiftFlags: ["-O", "-DONE", "-D", "TWO", "-Xfrontend", "-disable-x", "-D"]),
            ["ONE", "TWO"]
        )
    }

    // MARK: Helpers

    private func conditions(custom: [Set<String>]) -> BuildConditions {
        BuildConditions(platform: macOS, customConditions: custom)
    }

    /// Whether `condition` holds, read from whether each clause of an `#if` around it is inactive; nil for undecided.
    private func holds(_ condition: String, in conditions: BuildConditions) -> Bool? {
        let inactive = inactiveCode(
            """
            #if \(condition)
            ifBranch()
            #else
            elseBranch()
            #endif
            """,
            in: conditions
        )
        switch inactive {
        case ["elseBranch()"]: return true
        case ["ifBranch()"]: return false
        case []: return nil
        default:
            XCTFail("Both of \(condition)'s clauses left out: \(inactive)")
            return nil
        }
    }

    private func inactiveCode(_ source: String, in conditions: BuildConditions? = nil) -> [String] {
        let tree = Parser.parse(source: source)
        let conditions = conditions ?? BuildConditions(platform: macOS, customConditions: [["DEBUG"]])
        return conditions.inactiveRegions(in: tree).map { region in
            let bytes = Array(source.utf8)[region.lowerBound.utf8Offset ..< region.upperBound.utf8Offset]
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func regions(in source: String) -> [Range<AbsolutePosition>] {
        let conditions = BuildConditions(platform: macOS, customConditions: [["DEBUG"]])
        return conditions.inactiveRegions(in: Parser.parse(source: source))
    }
}
