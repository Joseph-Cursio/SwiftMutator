@testable import muterCore
import XCTest

extension BuildConditionsTests {
    func test_aFilesConditions_areThoseOfItsTargets() {
        let project = ProjectBuildConditions(
            everyTarget: conditions(custom: [["DEBUG", "APP"], ["DEBUG", "LIB"]]),
            customConditionsOfFile: ["Sources/App/App.swift": [["DEBUG", "APP"]]]
        )

        XCTAssertEqual(holds("APP", in: project.conditions(ofFile: "Sources/App/App.swift")), .holds)
        XCTAssertEqual(holds("LIB", in: project.conditions(ofFile: "Sources/App/App.swift")), .doesntHold)
        // A file no target is known to hold could be in any of them.
        XCTAssertEqual(holds("APP", in: project.conditions(ofFile: "Other.swift")), .undecided)
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

        XCTAssertEqual(holds("RELEASE_ONLY", in: project.conditions(ofFile: "App.swift")), .doesntHold)
        XCTAssertEqual(holds("ANY_OTHER", in: project.conditions(ofFile: "App.swift")), .doesntHold)
        XCTAssertEqual(holds("RELEASE_ONLY", in: project.conditions(ofFile: "Lib.swift")), .undecided)
        XCTAssertEqual(holds("ANY_OTHER", in: project.conditions(ofFile: "Lib.swift")), .undecided)
        // Without targets of its own, a file has every target's conditions, and their undecided names.
        XCTAssertEqual(holds("RELEASE_ONLY", in: project.conditions(ofFile: "Other.swift")), .undecided)
    }

    func test_aFileInTwoTargets_isDecidedOnlyWhereTheyAgree() {
        let project = ProjectBuildConditions(
            everyTarget: conditions(custom: [["A"], ["A", "B"]]),
            customConditionsOfFile: ["Shared.swift": [["A"], ["A", "B"]]]
        )

        XCTAssertEqual(holds("A", in: project.conditions(ofFile: "Shared.swift")), .holds)
        XCTAssertEqual(holds("B", in: project.conditions(ofFile: "Shared.swift")), .undecided)
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

        XCTAssertEqual(holds("FOO", in: conditions), .undecided)
    }
}
