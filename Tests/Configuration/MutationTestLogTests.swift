@testable import muterCore
import XCTest

final class MutationTestLogTests: XCTestCase {
    func test_keptFileName_namesTheOperatorFilePlaceAndPathHash() {
        let key = MutantKey(
            path: "Packages/Core/Sources/Core/RuleRegistry.swift",
            mutationOperatorId: .removeSideEffects,
            line: 118,
            column: 9,
            occurrence: 0
        )

        XCTAssertEqual(
            MutationTestLog.keptFileName(for: key),
            "RemoveSideEffects @ RuleRegistry.swift-118-9 222edb6566ca746c.log"
        )
    }

    // Two executable targets' `main.swift`, or a file copied into two targets, with a mutant at the same place.
    func test_keptFileName_ofSameNamedFiles_differ() {
        let app = key(path: "Sources/App/Check.swift")
        let tool = key(path: "Sources/Tool/Check.swift")

        XCTAssertEqual(
            MutationTestLog.keptFileName(for: app),
            "RelationalOperatorReplacement @ Check.swift-3-5 24bcdd71ccc09bff.log"
        )
        XCTAssertEqual(
            MutationTestLog.keptFileName(for: tool),
            "RelationalOperatorReplacement @ Check.swift-3-5 d7fac045dd38392a.log"
        )
    }

    // APFS ignores case by default, so names differing in case alone would share a file.
    func test_keptFileName_ofPathsDifferingInCaseAlone_differInMoreThanCase() {
        let upper = MutationTestLog.keptFileName(for: key(path: "Sources/Check.swift"))
        let lower = MutationTestLog.keptFileName(for: key(path: "Sources/check.swift"))

        XCTAssertNotEqual(upper.lowercased(), lower.lowercased())
    }

    func test_keptFileName_ofARepeat_numbersIt_asItsKeysDescriptionDoes() {
        let first = key(path: "Sources/Sum.swift", occurrence: 0)
        let second = key(path: "Sources/Sum.swift", occurrence: 1)
        let third = key(path: "Sources/Sum.swift", occurrence: 2)

        XCTAssertEqual(
            MutationTestLog.keptFileName(for: first),
            "RelationalOperatorReplacement @ Sum.swift-3-5 670192af8b34c2a4.log"
        )
        XCTAssertEqual(
            MutationTestLog.keptFileName(for: second),
            "RelationalOperatorReplacement @ Sum.swift-3-5 670192af8b34c2a4 (#2).log"
        )
        XCTAssertEqual(
            MutationTestLog.keptFileName(for: third),
            "RelationalOperatorReplacement @ Sum.swift-3-5 670192af8b34c2a4 (#3).log"
        )
        XCTAssertTrue(second.description.hasSuffix("(#2)"), second.description)
    }

    // A file outside the mutated project keeps its absolute path as its key's: the name still holds only the file's.
    func test_keptFileName_ofAFileOutsideTheProject_namesTheFileAlone() {
        let name = MutationTestLog.keptFileName(for: key(path: "/elsewhere/Shared/Sum.swift"))

        XCTAssertTrue(name.hasPrefix("RelationalOperatorReplacement @ Sum.swift-3-5 "), name)
        XCTAssertFalse(name.contains("/"), name)
    }

    func test_aLogIsTheBaselinesUnlessNamed() {
        XCTAssertEqual(MutationTestLog.make().keptFileName, "baseline run.log")
    }

    private func key(path: String, occurrence: Int = 0) -> MutantKey {
        MutantKey(path: path, mutationOperatorId: .ror, line: 3, column: 5, occurrence: occurrence)
    }
}
