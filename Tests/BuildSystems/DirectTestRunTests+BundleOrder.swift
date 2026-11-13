@testable import muterCore
import XCTest

extension DirectTestRunTests {
    func test_bundles_putFirstThoseWithATestFileNamedAfterTheMutatedFile_eachInNameOrder() {
        let direct = makeDirectTestRun(bundles: ["AppTests", "CLITests", "CoreTests", "UITests"], testFiles: [
            "AppTests": ["ContentViewTests"],
            "CLITests": ["CSVFormatterTests", "JSONFormatterTests"],
            "CoreTests": ["CSVFormatterEscapingTests"],
        ])

        XCTAssertEqual(
            direct.bundles(forMutantIn: "/project/Sources/Core/Export/CSVFormatter.swift"),
            ["CLITests", "CoreTests", "AppTests", "UITests"]
        )
        XCTAssertEqual(
            direct.bundles(forMutantIn: "/project/Sources/App/ContentView.swift"),
            ["AppTests", "CLITests", "CoreTests", "UITests"]
        )
        XCTAssertEqual(
            direct.bundles(forMutantIn: "/project/Sources/Core/Unmatched.swift"),
            ["AppTests", "CLITests", "CoreTests", "UITests"]
        )
        XCTAssertEqual(direct.bundles(forMutantIn: nil), ["AppTests", "CLITests", "CoreTests", "UITests"])
    }

    // A run with no mutant on keeps name order, as the check's run did.
    func test_theScript_runsTheBundlesInTheMutantsOrder() {
        let direct = makeDirectTestRun(bundles: ["AppTests", "CoreTests"], testFiles: ["CoreTests": ["SampleTests"]])
        let bundlesRun = { (script: String) in
            script.split(separator: "\n").compactMap { line in
                line.range(of: #"MacOS/[A-Za-z]+'"#, options: .regularExpression).map { line[$0] }
            }
        }

        XCTAssertEqual(
            bundlesRun(direct.script(in: worker, forMutantIn: "/p/Sample.swift")),
            ["MacOS/CoreTests'", "MacOS/AppTests'"]
        )
        XCTAssertEqual(bundlesRun(direct.script(in: worker)), ["MacOS/AppTests'", "MacOS/CoreTests'"])
    }

    func test_isTestFile_takesTheNameThenMoreWordsOrNone_endingTests() {
        XCTAssertTrue(DirectTestRun.isTestFile("CSVFormatterTests", of: "CSVFormatter"))
        XCTAssertTrue(DirectTestRun.isTestFile("CSVFormatterEscapingTests", of: "CSVFormatter"))
        XCTAssertTrue(DirectTestRun.isTestFile("CSVFormatterTest", of: "CSVFormatter"))
        XCTAssertFalse(DirectTestRun.isTestFile("CSVFormatterTests", of: "CSVFormat"))
        XCTAssertFalse(DirectTestRun.isTestFile("CSVFormatter", of: "CSVFormatter"))
        XCTAssertFalse(DirectTestRun.isTestFile("CSVFormatterHelpers", of: "CSVFormatter"))
        XCTAssertFalse(DirectTestRun.isTestFile("JSONFormatterTests", of: "CSVFormatter"))
        XCTAssertFalse(DirectTestRun.isTestFile("Tests", of: ""))
    }
}
