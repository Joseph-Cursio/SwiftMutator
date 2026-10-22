@testable import muterCore
import XCTest

final class ExcludeGlobTests: XCTestCase {
    func test_starStaysWithinOneFolder() {
        let glob = ExcludeGlob("Sources/*.swift")

        XCTAssertTrue(glob.matches("Sources/A.swift"))
        XCTAssertFalse(glob.matches("Sources/Sub/A.swift"))
    }

    func test_doubleStarStandsForAnyNumberOfFolders_noneIncluded() {
        let glob = ExcludeGlob("Sources/**/*.swift")

        XCTAssertTrue(glob.matches("Sources/A.swift"))
        XCTAssertTrue(glob.matches("Sources/Sub/A.swift"))
        XCTAssertTrue(glob.matches("Sources/Sub/Deep/A.swift"))
        XCTAssertFalse(glob.matches("Other/A.swift"))
    }

    // Pathos treated `**` as `*` when a lone `*` came before it.
    func test_doubleStarAfterAStar() {
        let glob = ExcludeGlob("Modules/*/Sources/**/*.swift")

        XCTAssertTrue(glob.matches("Modules/M1/Sources/a.swift"))
        XCTAssertTrue(glob.matches("Modules/M1/Sources/Sub/Deep/c.swift"))
        XCTAssertFalse(glob.matches("Modules/M1/Other/Sources/a.swift"))
    }

    func test_leadingDoubleStarMatchesAtTheTopToo() {
        let glob = ExcludeGlob("**/Generated/*.swift")

        XCTAssertTrue(glob.matches("Generated/A.swift"))
        XCTAssertTrue(glob.matches("A/B/Generated/A.swift"))
        XCTAssertFalse(glob.matches("A/NotGenerated/A.swift"))
    }

    func test_startsAtTheProjectFolder_withOrWithoutALeadingSlash() {
        for pattern in ["Sources/*.swift", "/Sources/*.swift", "./Sources/*.swift"] {
            XCTAssertTrue(ExcludeGlob(pattern).matches("Sources/A.swift"), pattern)
            XCTAssertFalse(ExcludeGlob(pattern).matches("App/Sources/A.swift"), pattern)
        }
    }

    func test_questionMarkAndCharacterSets() {
        XCTAssertTrue(ExcludeGlob("Sources/A?.swift").matches("Sources/AB.swift"))
        XCTAssertFalse(ExcludeGlob("Sources/A?.swift").matches("Sources/A/.swift"))
        XCTAssertTrue(ExcludeGlob("Sources/[AB]*.swift").matches("Sources/Beta.swift"))
        XCTAssertFalse(ExcludeGlob("Sources/[AB]*.swift").matches("Sources/Charlie.swift"))
        XCTAssertTrue(ExcludeGlob("Sources/[!AB]*.swift").matches("Sources/Charlie.swift"))
        XCTAssertFalse(ExcludeGlob("Sources/[!AB]*.swift").matches("Sources/Alpha.swift"))
        XCTAssertFalse(ExcludeGlob("Sources[!AB]*.swift").matches("Sources/Charlie.swift"))
    }

    func test_aBracketWithNoClosingOneMatchesItself() {
        XCTAssertTrue(ExcludeGlob("Sources/[old*.swift").matches("Sources/[old A.swift"))
        XCTAssertFalse(ExcludeGlob("Sources/[old*.swift").matches("Sources/o.swift"))
    }

    func test_otherCharactersMatchThemselves() {
        let glob = ExcludeGlob("Sources/C++ (old)/*.swift")

        XCTAssertTrue(glob.matches("Sources/C++ (old)/A.swift"))
        XCTAssertFalse(glob.matches("Sources/CC+ (old)/A.swift"))
        XCTAssertFalse(ExcludeGlob("*.swift").matches("Aswift"))
    }

    // Finder and Xcode name files in decomposed form; an editor types the configuration in composed form.
    func test_comparesComposedAndDecomposedAccentsAsEqual() {
        let composed = "**/R\u{E9}sum\u{E9}.swift"
        let decomposed = "Sources/Re\u{301}sume\u{301}.swift"

        XCTAssertTrue(ExcludeGlob(composed).matches(decomposed))
    }
}
