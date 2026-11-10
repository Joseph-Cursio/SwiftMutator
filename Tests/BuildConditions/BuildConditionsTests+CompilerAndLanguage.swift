@testable import muterCore
import SwiftIfConfig
import XCTest

extension BuildConditionsTests {
    func test_whatDependsOnTheCompiler_isUndecided_withoutItsVersionOrThePlatform() {
        var conditions = conditions(custom: [[]])
        conditions.platform = nil

        for condition in [
            "swift(>=5.0)", "swift(<1.0)", "compiler(>=5.0)", "_compiler_version(\"5.0\")", "hasFeature(Foo)",
            "hasAttribute(foo)", "_pointerBitWidth(_64)", "_endian(little)", "_hasAtomicBitWidth(_64)",
            "os(macOS) && swift(>=5.0)", "!compiler(>=5.0)",
        ] {
            XCTAssertEqual(holds(condition, in: conditions), .undecided, condition)
        }
    }

    // `compiler(…)` compares with the version `swift --version` prints, to its patch: 6.4.2 is not 6.4.2.1.
    func test_theCompilersVersion_whenKnown() {
        var conditions = conditions(custom: [["DEBUG"]])
        conditions.compiler = VersionTuple(6, 4, 2)

        XCTAssertEqual(holds("compiler(>=6.0)", in: conditions), .holds)
        XCTAssertEqual(holds("compiler(>=6.4.2)", in: conditions), .holds)
        XCTAssertEqual(holds("compiler(>=6.4.3)", in: conditions), .doesntHold)
        XCTAssertEqual(holds("compiler(>=6.4.2.1)", in: conditions), .doesntHold)
        XCTAssertEqual(holds("compiler(<6)", in: conditions), .doesntHold)
        XCTAssertEqual(holds("!compiler(>=7)", in: conditions), .holds)
        XCTAssertEqual(holds("DEBUG && compiler(>=6.0)", in: conditions), .holds)
        // The language mode, and the old build numbers, are still not looked up.
        XCTAssertEqual(holds("swift(>=5.0)", in: conditions), .undecided)
        XCTAssertEqual(holds("compiler(>=6.0) && swift(>=6.0)", in: conditions), .undecided)
        XCTAssertEqual(holds("_compiler_version(\"5.0\")", in: conditions), .undecided)
        XCTAssertEqual(holds("`swift`(>=5.0)", in: conditions), .undecided)
    }

    // `$AsyncAwait` asks for a compiler feature, as `hasFeature(AsyncAwait)` does; taken for a condition no target
    // sets, it would drop the mutants of a branch the compiler builds.
    func test_theLanguageVersion_whenKnown() {
        var conditions = conditions(custom: [[]])
        conditions.compiler = VersionTuple(6, 4, 2)
        conditions.language = VersionTuple(5, 10)

        XCTAssertEqual(holds("swift(>=5.9)", in: conditions), .holds)
        XCTAssertEqual(holds("swift(>=5.10)", in: conditions), .holds)
        XCTAssertEqual(holds("swift(>=5.10.1)", in: conditions), .doesntHold)
        XCTAssertEqual(holds("swift(>=6.0)", in: conditions), .doesntHold)
        XCTAssertEqual(holds("swift(<6) && compiler(>=6)", in: conditions), .holds)
        XCTAssertEqual(holds("`swift`(>=6.0)", in: conditions), .doesntHold)
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

        XCTAssertEqual(holds("$AsyncAwait", in: conditions), .undecided)
        XCTAssertEqual(holds("compiler(>=5.5) && $AsyncAwait", in: conditions), .undecided)
        XCTAssertEqual(holds("_endian(little) && $Lifetimes", in: conditions), .undecided)
    }

    func test_thePointerWidthAndByteOrder_ofA64BitBuild() {
        var conditions = conditions(custom: [[]])

        for architectures: Set in [["arm64"], ["arm64", "x86_64"], ["arm64e"], ["aarch64"]] {
            conditions.platform = .init(system: "macOS", architectures: architectures)
            XCTAssertEqual(holds("_pointerBitWidth(_64)", in: conditions), .holds, "\(architectures)")
            XCTAssertEqual(holds("_pointerBitWidth(_32)", in: conditions), .doesntHold, "\(architectures)")
            XCTAssertEqual(holds("_endian(little)", in: conditions), .holds, "\(architectures)")
            XCTAssertEqual(holds("_endian(big)", in: conditions), .doesntHold, "\(architectures)")
        }
        XCTAssertEqual(holds("_hasAtomicBitWidth(_64)", in: conditions), .undecided)
    }

    // A 32-bit build's macros are built for the 64-bit host in the same build, so its pointer width is left alone.
    func test_thePointerWidth_ofA32BitBuild_isUndecided_andAnUnknownArchitecturesByteOrder() {
        var conditions = conditions(custom: [[]])

        conditions.platform = .init(system: "watchOS", architectures: ["arm64_32", "arm64"])
        XCTAssertEqual(holds("_pointerBitWidth(_64)", in: conditions), .undecided)
        XCTAssertEqual(holds("_pointerBitWidth(_32)", in: conditions), .undecided)
        XCTAssertEqual(holds("_endian(little)", in: conditions), .holds)

        conditions.platform = .init(system: "Linux", architectures: ["s390x"])
        XCTAssertEqual(holds("_pointerBitWidth(_64)", in: conditions), .undecided)
        XCTAssertEqual(holds("_endian(big)", in: conditions), .undecided)
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

        XCTAssertEqual(holds("os(macOS) && DEBUG", in: conditions), .holds)
        XCTAssertEqual(holds("os(iOS) || DEBUG", in: conditions), .holds)
        XCTAssertEqual(holds("os(iOS) && DEBUG", in: conditions), .doesntHold)
        XCTAssertEqual(holds("!(os(macOS) && DEBUG)", in: conditions), .doesntHold)
        XCTAssertEqual(holds("DEBUG && canImport(SomePackage)", in: conditions), .undecided)
        // What the left side settles, an import on the right can't change, and the compiler doesn't try it.
        XCTAssertEqual(holds("os(iOS) && canImport(SomePackage)", in: conditions), .doesntHold)
        XCTAssertEqual(holds("os(macOS) || canImport(SomePackage)", in: conditions), .holds)
    }
}
