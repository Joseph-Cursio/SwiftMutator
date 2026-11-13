@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

extension BuildConditionsTests {
    /// Whether a condition holds where it is read.
    enum Verdict {
        case holds
        case doesntHold
        case undecided
    }

    /// A Mac with an arm64 processor, whose SDK has AppKit and SwiftUI but not UIKit.
    var macOS: BuildConditions.Platform {
        BuildConditions.Platform(
            system: "macOS",
            architectures: ["arm64"],
            modules: .init(present: ["AppKit", "SwiftUI"], absent: ["UIKit"])
        )
    }

    func conditions(custom: [Set<String>]) -> BuildConditions {
        BuildConditions(platform: macOS, customConditions: custom)
    }

    /// Whether `condition` holds, read from whether each clause of an `#if` around it is inactive.
    func holds(_ condition: String, in conditions: BuildConditions) -> Verdict {
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
        case ["elseBranch()"]: return .holds
        case ["ifBranch()"]: return .doesntHold
        case []: return .undecided

        default:
            XCTFail("Both of \(condition)'s clauses left out: \(inactive)")
            return .undecided
        }
    }

    func inactiveCode(_ source: String, in conditions: BuildConditions? = nil) -> [String] {
        let tree = Parser.parse(source: source)
        let givenConditions = conditions ?? BuildConditions(platform: macOS, customConditions: [["DEBUG"]])
        return givenConditions.inactiveRegions(in: tree).map { region in
            let bytes = Array(source.utf8)[region.lowerBound.utf8Offset ..< region.upperBound.utf8Offset]
            return String(lossyUTF8: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func regions(in source: String) -> [Range<AbsolutePosition>] {
        let conditions = BuildConditions(platform: macOS, customConditions: [["DEBUG"]])
        return conditions.inactiveRegions(in: Parser.parse(source: source))
    }
}
