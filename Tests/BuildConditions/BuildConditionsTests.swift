@testable import muterCore
import SwiftIfConfig
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

        XCTAssertTrue(try XCTUnwrap(holds("DEBUG", in: conditions)))
    }

    func test_aConditionNoTargetSets_doesntHold() {
        let conditions = conditions(custom: [["DEBUG"]])

        XCTAssertFalse(try XCTUnwrap(holds("NOBODY", in: conditions)))
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

        XCTAssertTrue(try XCTUnwrap(holds("DEBUG", in: conditions)))
    }

    // Xcode sets `SWIFT_PACKAGE` for a local package's code, and SwiftPM others for targets with resources.
    func test_aBuildSystemsOwnCondition_isUndecided_unlessEveryTargetSetsIt() {
        XCTAssertNil(holds("SWIFT_PACKAGE", in: conditions(custom: [["DEBUG"]])))
        XCTAssertNil(holds("SWIFT_MODULE_RESOURCE_BUNDLE_AVAILABLE", in: conditions(custom: [["DEBUG"]])))
        XCTAssertTrue(try XCTUnwrap(holds("SWIFT_PACKAGE", in: conditions(custom: [["SWIFT_PACKAGE"]]))))
    }

    func test_withNoTargets_noConditionIsDecided() {
        XCTAssertNil(holds("DEBUG", in: conditions(custom: [])))
    }

    // MARK: Platforms

    func test_theOS_undecidedWithoutAPlatform() {
        var conditions = conditions(custom: [[]])

        XCTAssertTrue(try XCTUnwrap(holds("os(macOS)", in: conditions)))
        XCTAssertTrue(try XCTUnwrap(holds("os(OSX)", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("os(iOS)", in: conditions)))

        conditions.platform = nil
        XCTAssertNil(holds("os(macOS)", in: conditions))
        XCTAssertNil(holds("arch(arm64)", in: conditions))
        XCTAssertNil(holds("targetEnvironment(simulator)", in: conditions))
        XCTAssertNil(holds("canImport(AppKit)", in: conditions))
    }

    func test_visionOS_answersToItsOldNameToo() {
        var conditions = conditions(custom: [[]])
        conditions.platform = .init(system: "visionOS", architectures: ["arm64"])

        XCTAssertTrue(try XCTUnwrap(holds("os(visionOS)", in: conditions)))
        XCTAssertTrue(try XCTUnwrap(holds("os(xrOS)", in: conditions)))
    }

    func test_theEnvironment() {
        var conditions = conditions(custom: [[]])
        XCTAssertFalse(try XCTUnwrap(holds("targetEnvironment(simulator)", in: conditions)))

        conditions.platform = .init(system: "iOS", environment: "simulator", architectures: ["arm64"])
        XCTAssertTrue(try XCTUnwrap(holds("targetEnvironment(simulator)", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("targetEnvironment(macCatalyst)", in: conditions)))

        conditions.platform = .init(system: "iOS", environment: "macCatalyst", architectures: ["arm64"])
        XCTAssertTrue(try XCTUnwrap(holds("targetEnvironment(macCatalyst)", in: conditions)))
        XCTAssertTrue(try XCTUnwrap(holds("os(iOS)", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("os(macOS)", in: conditions)))
    }

    func test_theArchitecture_ofABuildForOne() {
        let conditions = conditions(custom: [[]])

        XCTAssertTrue(try XCTUnwrap(holds("arch(arm64)", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("arch(x86_64)", in: conditions)))
    }

    // A build for two compiles each branch for one of them, though the tests run only one.
    func test_theArchitecture_ofABuildForSeveral_isUndecided_unlessItIsNoneOfThem() {
        var conditions = conditions(custom: [[]])
        conditions.platform = .init(system: "iOS", architectures: ["arm64", "x86_64"])

        XCTAssertNil(holds("arch(arm64)", in: conditions))
        XCTAssertNil(holds("arch(x86_64)", in: conditions))
        XCTAssertFalse(try XCTUnwrap(holds("arch(arm)", in: conditions)))
    }

    // As for a package's scheme, whose settings xcodebuild doesn't report: the platform is known, but not its
    // architectures.
    func test_unknownArchitectures_leaveArchPointerWidthAndByteOrderUndecided() {
        var conditions = conditions(custom: [[]])
        conditions.platform = .init(system: "iOS", environment: "simulator", architectures: nil)

        XCTAssertTrue(try XCTUnwrap(holds("os(iOS) && targetEnvironment(simulator)", in: conditions)))
        XCTAssertNil(holds("arch(arm64)", in: conditions))
        XCTAssertNil(holds("arch(arm)", in: conditions))
        XCTAssertNil(holds("_pointerBitWidth(_64)", in: conditions))
        XCTAssertNil(holds("_endian(little)", in: conditions))
    }

    func test_theArchitecture_arm64eAlsoAnswersToArm64() {
        var conditions = conditions(custom: [[]])
        conditions.platform = .init(system: "iOS", architectures: ["arm64e"])

        XCTAssertNil(holds("arch(arm64)", in: conditions))
        XCTAssertNil(holds("arch(arm64e)", in: conditions))
    }

    func test_theRuntime_andTheObjectFormat() {
        var conditions = conditions(custom: [[]])
        XCTAssertTrue(try XCTUnwrap(holds("_runtime(_ObjC)", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("_runtime(_Native)", in: conditions)))

        conditions.platform = .init(system: "Linux", architectures: ["arm64"])
        XCTAssertFalse(try XCTUnwrap(holds("_runtime(_ObjC)", in: conditions)))
        XCTAssertTrue(try XCTUnwrap(holds("_runtime(_Native)", in: conditions)))
    }

    // MARK: canImport

    func test_canImport_answersForTheSDKsModules() {
        let conditions = conditions(custom: [[]])

        XCTAssertTrue(try XCTUnwrap(holds("canImport(AppKit)", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("canImport(UIKit)", in: conditions)))
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

    func test_whatDependsOnTheCompiler_isUndecided_withoutItsVersionOrThePlatform() {
        var conditions = conditions(custom: [[]])
        conditions.platform = nil

        for condition in [
            "swift(>=5.0)", "swift(<1.0)", "compiler(>=5.0)", "_compiler_version(\"5.0\")", "hasFeature(Foo)",
            "hasAttribute(foo)", "_pointerBitWidth(_64)", "_endian(little)", "_hasAtomicBitWidth(_64)",
            "os(macOS) && swift(>=5.0)", "!compiler(>=5.0)",
        ] {
            XCTAssertNil(holds(condition, in: conditions), condition)
        }
    }

    // `compiler(…)` compares with the version `swift --version` prints, to its patch: 6.4.2 is not 6.4.2.1.
    func test_theCompilersVersion_whenKnown() {
        var conditions = conditions(custom: [["DEBUG"]])
        conditions.compiler = VersionTuple(6, 4, 2)

        XCTAssertTrue(try XCTUnwrap(holds("compiler(>=6.0)", in: conditions)))
        XCTAssertTrue(try XCTUnwrap(holds("compiler(>=6.4.2)", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("compiler(>=6.4.3)", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("compiler(>=6.4.2.1)", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("compiler(<6)", in: conditions)))
        XCTAssertTrue(try XCTUnwrap(holds("!compiler(>=7)", in: conditions)))
        XCTAssertTrue(try XCTUnwrap(holds("DEBUG && compiler(>=6.0)", in: conditions)))
        // The language mode, and the old build numbers, are still not looked up.
        XCTAssertNil(holds("swift(>=5.0)", in: conditions))
        XCTAssertNil(holds("compiler(>=6.0) && swift(>=6.0)", in: conditions))
        XCTAssertNil(holds("_compiler_version(\"5.0\")", in: conditions))
        XCTAssertNil(holds("`swift`(>=5.0)", in: conditions))
    }

    // `$AsyncAwait` asks for a compiler feature, as `hasFeature(AsyncAwait)` does; taken for a condition no target
    // sets, it would drop the mutants of a branch the compiler builds.
    func test_theLanguageVersion_whenKnown() {
        var conditions = conditions(custom: [[]])
        conditions.compiler = VersionTuple(6, 4, 2)
        conditions.language = VersionTuple(5, 10)

        XCTAssertTrue(try XCTUnwrap(holds("swift(>=5.9)", in: conditions)))
        XCTAssertTrue(try XCTUnwrap(holds("swift(>=5.10)", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("swift(>=5.10.1)", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("swift(>=6.0)", in: conditions)))
        XCTAssertTrue(try XCTUnwrap(holds("swift(<6) && compiler(>=6)", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("`swift`(>=6.0)", in: conditions)))
    }

    // As probed with Swift 6.4.2: `-swift-version 4` compares as 4.1.50, and 6 as the compiler's own version.
    func test_eachLanguageModesVersion_withASwift6Compiler() {
        let compiler = VersionTuple(6, 4, 2)

        XCTAssertEqual(LanguageMode.swift4.languageVersion(compiler: compiler), VersionTuple(4, 1, 50))
        XCTAssertEqual(LanguageMode.swift4dot2.languageVersion(compiler: compiler), VersionTuple(4, 2))
        XCTAssertEqual(LanguageMode.swift5.languageVersion(compiler: compiler), VersionTuple(5, 10))
        XCTAssertEqual(LanguageMode.swift6.languageVersion(compiler: compiler), compiler)
        // Another compiler may set others.
        XCTAssertNil(LanguageMode.swift5.languageVersion(compiler: VersionTuple(5, 10)))
        XCTAssertNil(LanguageMode.swift5.languageVersion(compiler: VersionTuple(7, 0)))
        XCTAssertNil(LanguageMode.swift5.languageVersion(compiler: nil))
    }

    func test_theLanguageVersion_ofSeveralTargets_onlyIfTheyAllShareAMode() {
        let compiler = VersionTuple(6, 4, 2)

        XCTAssertEqual(LanguageMode.languageVersion(of: [.swift5, .swift5], compiler: compiler), VersionTuple(5, 10))
        XCTAssertNil(LanguageMode.languageVersion(of: [.swift5, .swift6], compiler: compiler))
        XCTAssertNil(LanguageMode.languageVersion(of: [.swift5, nil], compiler: compiler))
        XCTAssertNil(LanguageMode.languageVersion(of: [], compiler: compiler))
    }

    func test_aLanguageMode_asWritten() {
        XCTAssertEqual(LanguageMode("4"), .swift4)
        XCTAssertEqual(LanguageMode("4.0"), .swift4)
        XCTAssertEqual(LanguageMode("4.2"), .swift4dot2)
        XCTAssertEqual(LanguageMode("5.0"), .swift5)
        XCTAssertEqual(LanguageMode("\"6\""), .swift6)
        XCTAssertNil(LanguageMode("6.2"))
        XCTAssertNil(LanguageMode("$(inherited)"))
        XCTAssertNil(LanguageMode("7"))
    }

    func test_aDollarFeatureCheck_isUndecided() {
        var conditions = conditions(custom: [["SWIFT_PACKAGE"]])
        conditions.compiler = VersionTuple(6, 4, 2)

        XCTAssertNil(holds("$AsyncAwait", in: conditions))
        XCTAssertNil(holds("compiler(>=5.5) && $AsyncAwait", in: conditions))
        XCTAssertNil(holds("_endian(little) && $Lifetimes", in: conditions))
    }

    func test_thePointerWidthAndByteOrder_ofA64BitBuild() {
        var conditions = conditions(custom: [[]])

        for architectures: Set in [["arm64"], ["arm64", "x86_64"], ["arm64e"], ["aarch64"]] {
            conditions.platform = .init(system: "macOS", architectures: architectures)
            XCTAssertTrue(try XCTUnwrap(holds("_pointerBitWidth(_64)", in: conditions)), "\(architectures)")
            XCTAssertFalse(try XCTUnwrap(holds("_pointerBitWidth(_32)", in: conditions)), "\(architectures)")
            XCTAssertTrue(try XCTUnwrap(holds("_endian(little)", in: conditions)), "\(architectures)")
            XCTAssertFalse(try XCTUnwrap(holds("_endian(big)", in: conditions)), "\(architectures)")
        }
        XCTAssertNil(holds("_hasAtomicBitWidth(_64)", in: conditions))
    }

    // A 32-bit build's macros are built for the 64-bit host in the same build, so its pointer width is left alone.
    func test_thePointerWidth_ofA32BitBuild_isUndecided_andAnUnknownArchitecturesByteOrder() {
        var conditions = conditions(custom: [[]])

        conditions.platform = .init(system: "watchOS", architectures: ["arm64_32", "arm64"])
        XCTAssertNil(holds("_pointerBitWidth(_64)", in: conditions))
        XCTAssertNil(holds("_pointerBitWidth(_32)", in: conditions))
        XCTAssertTrue(try XCTUnwrap(holds("_endian(little)", in: conditions)))

        conditions.platform = .init(system: "Linux", architectures: ["s390x"])
        XCTAssertNil(holds("_pointerBitWidth(_64)", in: conditions))
        XCTAssertNil(holds("_endian(big)", in: conditions))
    }

    func test_theCompilersVersion_inWhatItPrints() {
        XCTAssertEqual(
            compilerVersion(inVersionOutput: """
            swift-driver version: 1.168.6 Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)
            Target: arm64-apple-macosx27.3.0
            """),
            VersionTuple(6, 4, 2)
        )
        XCTAssertEqual(
            compilerVersion(inVersionOutput: "Swift version 6.2 (swift-6.2-RELEASE)\nTarget: aarch64-unknown-linux"),
            VersionTuple(6, 2)
        )
        XCTAssertNil(compilerVersion(inVersionOutput: "Swift version 6.3-dev (LLVM abc, Swift def)"))
        XCTAssertNil(compilerVersion(inVersionOutput: "Swift version  (unknown)"))
        XCTAssertNil(compilerVersion(inVersionOutput: "error: unknown option --version"))
    }

    func test_conditionsCombine() {
        let conditions = conditions(custom: [["DEBUG"]])

        XCTAssertTrue(try XCTUnwrap(holds("os(macOS) && DEBUG", in: conditions)))
        XCTAssertTrue(try XCTUnwrap(holds("os(iOS) || DEBUG", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("os(iOS) && DEBUG", in: conditions)))
        XCTAssertFalse(try XCTUnwrap(holds("!(os(macOS) && DEBUG)", in: conditions)))
        XCTAssertNil(holds("DEBUG && canImport(SomePackage)", in: conditions))
        // What the left side settles, an import on the right can't change, and the compiler doesn't try it.
        XCTAssertFalse(try XCTUnwrap(holds("os(iOS) && canImport(SomePackage)", in: conditions)))
        XCTAssertTrue(try XCTUnwrap(holds("os(macOS) || canImport(SomePackage)", in: conditions)))
    }

    // MARK: Files

    func test_aFilesConditions_areThoseOfItsTargets() {
        let project = ProjectBuildConditions(
            everyTarget: conditions(custom: [["DEBUG", "APP"], ["DEBUG", "LIB"]]),
            customConditionsOfFile: ["Sources/App/App.swift": [["DEBUG", "APP"]]]
        )

        XCTAssertTrue(try XCTUnwrap(holds("APP", in: project.conditions(ofFile: "Sources/App/App.swift"))))
        XCTAssertFalse(try XCTUnwrap(holds("LIB", in: project.conditions(ofFile: "Sources/App/App.swift"))))
        // A file no target is known to hold could be in any of them.
        XCTAssertNil(holds("APP", in: project.conditions(ofFile: "Other.swift")))
    }

    // A name a build file has is undecided for any file, but not for one whose targets' conditions are all it has.
    func test_aFileWithAllItsConditions_hasNoOthersUndecided() {
        var everyTarget = conditions(custom: [["DEBUG", "APP"]])
        everyTarget.undecidedConditions = ["RELEASE_ONLY"]
        everyTarget.anyConditionMayBeSetElsewhere = true
        let project = ProjectBuildConditions(
            everyTarget: everyTarget,
            customConditionsOfFile: ["App.swift": [["DEBUG", "APP"]], "Lib.swift": [["DEBUG"]]],
            filesWithAllTheirConditions: ["App.swift", "Other.swift"]
        )

        XCTAssertFalse(try XCTUnwrap(holds("RELEASE_ONLY", in: project.conditions(ofFile: "App.swift"))))
        XCTAssertFalse(try XCTUnwrap(holds("ANY_OTHER", in: project.conditions(ofFile: "App.swift"))))
        XCTAssertNil(holds("RELEASE_ONLY", in: project.conditions(ofFile: "Lib.swift")))
        XCTAssertNil(holds("ANY_OTHER", in: project.conditions(ofFile: "Lib.swift")))
        // Without targets of its own, a file has every target's conditions, and their undecided names.
        XCTAssertNil(holds("RELEASE_ONLY", in: project.conditions(ofFile: "Other.swift")))
    }

    func test_aFileInTwoTargets_isDecidedOnlyWhereTheyAgree() {
        let project = ProjectBuildConditions(
            everyTarget: conditions(custom: [["A"], ["A", "B"]]),
            customConditionsOfFile: ["Shared.swift": [["A"], ["A", "B"]]]
        )

        XCTAssertTrue(try XCTUnwrap(holds("A", in: project.conditions(ofFile: "Shared.swift"))))
        XCTAssertNil(holds("B", in: project.conditions(ofFile: "Shared.swift")))
    }

    func test_customConditionsInSwiftFlags() {
        XCTAssertEqual(
            customConditions(inSwiftFlags: ["-O", "-DONE", "-D", "TWO", "-Xfrontend", "-disable-x", "-D"]),
            ["ONE", "TWO"]
        )
    }

    // A flag passed on to clang, LLVM or the linker defines nothing for an `#if`: taken for a condition, it would
    // decide `#if FOO` true and drop the real mutants of its `#else`. The frontend's `-D` is the driver's.
    func test_customConditionsInSwiftFlags_leaveOutFlagsForOtherTools() {
        XCTAssertEqual(
            customConditions(inSwiftFlags: [
                "-Xcc", "-DCLANG", "-Xllvm", "-DLLVM", "-Xlinker", "-DLINKER", "-Xclang-linker", "-DCLANG_LINKER",
                "-Xcc", "-D", "-Xcc", "MACRO", "-Xfrontend", "-DFRONTEND", "-DSWIFT",
            ]),
            ["FRONTEND", "SWIFT"]
        )
    }

    // The frontend reads the flags `-Xfrontend` passes it in turn, as the driver reads its own.
    func test_customConditionsInSwiftFlags_readFrontendFlagsInTurn() {
        XCTAssertEqual(customConditions(inSwiftFlags: ["-Xfrontend", "-D", "-Xfrontend", "SPLIT"]), ["SPLIT"])
        XCTAssertEqual(customConditions(inSwiftFlags: ["-Xfrontend", "-Xcc", "-Xfrontend", "-DCLANG"]), [])
        XCTAssertEqual(customConditions(inSwiftFlags: ["-Xcc", "-Xfrontend", "-DSWIFT"]), ["SWIFT"])
        XCTAssertEqual(customConditions(inSwiftFlags: ["-D", "A", "-Xfrontend"]), ["A"])
    }

    func test_aConditionOnlyClangGets_staysUnset_soItsElseKeepsItsMutants() {
        let set = customConditions(inSwiftFlags: ["-Xcc", "-DFOO"])
        let conditions = BuildConditions(platform: macOS, customConditions: [set], undecidedConditions: ["FOO"])

        XCTAssertNil(holds("FOO", in: conditions))
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
        let givenConditions = conditions ?? BuildConditions(platform: macOS, customConditions: [["DEBUG"]])
        return givenConditions.inactiveRegions(in: tree).map { region in
            let bytes = Array(source.utf8)[region.lowerBound.utf8Offset ..< region.upperBound.utf8Offset]
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func regions(in source: String) -> [Range<AbsolutePosition>] {
        let conditions = BuildConditions(platform: macOS, customConditions: [["DEBUG"]])
        return conditions.inactiveRegions(in: Parser.parse(source: source))
    }
}
