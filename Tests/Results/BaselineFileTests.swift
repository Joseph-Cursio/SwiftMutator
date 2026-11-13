import ArgumentParser
@testable import muterCore
import XCTest

/// The baseline file: what it saves, in what order, what it reads back, what it refuses, and the scopes it refuses.
final class BaselineFileTests: MuterTestCase {
    var directory = ""

    let scope = BaselineScope(
        operators: ["SwapTernary", "RelationalOperatorReplacement"],
        skipCoverage: false,
        configuration: .init(
            arguments: ["test"],
            coverageThreshold: 0,
            exclude: ["/Generated/", "!/Stubs/"],
            mutationTestTimeout: 60.5
        )
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory()
    }

    func test_aSavedFile_readsBackTheSame() throws {
        let saved = file([
            BaselineSurvivor(
                mutant: key("Sources/B.swift", 3),
                outcome: .timedOut,
                before: "<",
                after: "<=",
                line: "if count < limit {"
            ),
            BaselineSurvivor(mutant: key("Sources/A.swift", 9), outcome: .notCovered, before: "'a'", after: "\"b\""),
            // Text YAML would read as another type, or as a comment or a mapping, reads back as it was.
            BaselineSurvivor(
                mutant: key("Sources/C.swift", 1),
                outcome: .survived,
                before: "true",
                after: "1",
                line: "let x: [String: Int] = [:] # null ~ - { }"
            ),
        ])

        XCTAssertTrue(saved.save(using: FileManager.default))
        let read = try BaselineFile.load(at: path, using: FileManager.default)

        XCTAssertEqual(read.formatVersion, BaselineFile.formatVersion)
        XCTAssertEqual(read.swiftMutator, "0.1.0")
        XCTAssertEqual(read.score, .init(killed: 812, scored: 1_003))
        XCTAssertEqual(read.scope, scope)
        XCTAssertEqual(read.survivors, saved.sortedSurvivors)
    }

    // By path, line, column, operator and repeat, so a commit's diff shows only what changed; the keys in the order a
    // reader wants them, and numbers as a person writes them.
    func test_aSave_isSorted_andReadsWell() throws {
        let survivors = [
            BaselineSurvivor(mutant: key("Sources/B.swift", 3), outcome: .survived, before: "<", after: "<="),
            BaselineSurvivor(mutant: key("Sources/A.swift", 10), outcome: .survived, before: "<", after: "<="),
            BaselineSurvivor(
                mutant: key("Sources/A.swift", 9, occurrence: 1),
                outcome: .survived,
                before: "<",
                after: "<="
            ),
            BaselineSurvivor(mutant: key("Sources/A.swift", 9), outcome: .survived, before: "<", after: "<="),
        ]

        let text = try file(survivors).yaml()

        XCTAssertTrue(text.hasPrefix(BaselineFile.introduction + "\nformatVersion: 1\nswiftMutator: 0.1.0\n"), text)
        let mutants = text.components(separatedBy: "\n").filter { $0.hasPrefix("- mutant:") }
        XCTAssertEqual(mutants, [
            "- mutant: Sources/A.swift:9:9 RelationalOperatorReplacement",
            "- mutant: Sources/A.swift:9:9 RelationalOperatorReplacement (#2)",
            "- mutant: Sources/A.swift:10:9 RelationalOperatorReplacement",
            "- mutant: Sources/B.swift:3:9 RelationalOperatorReplacement",
        ])
        XCTAssertTrue(text.contains("    mutationTestTimeout: 60.5\n"), text)
        XCTAssertTrue(text.contains("    coverageThreshold: 0\n"), text)
        XCTAssertTrue(text.contains("    exclude:\n    - '!/Stubs/'\n    - /Generated/\n"), text)
        XCTAssertTrue(text.contains("  operators:\n  - RelationalOperatorReplacement\n  - SwapTernary\n"), text)
    }

    // YAML folds a long value over lines by default, which a change to its code would make a diff of several.
    func test_aLongLine_isSavedOnOneLine_andReadsBackTheSame() throws {
        let line = "let decimalExponent = { (s, m) in Int(m) * (s == .minus ? -1 : 1) } <^> floatingPointE *> sign "
            + "<&> UInt.parser"
        let survivor = BaselineSurvivor(
            mutant: key("Sources/A.swift", 9),
            outcome: .survived,
            before: "*",
            after: "/",
            line: line
        )

        XCTAssertTrue(try file([survivor]).yaml().contains("  line: '\(line)'\n"))
        XCTAssertTrue(file([survivor]).save(using: FileManager.default))
        XCTAssertEqual(try BaselineFile.load(at: path, using: FileManager.default).survivors, [survivor])
    }

    // A shell leaves `~` alone in quotes; missing folders are made, as for a report.
    func test_aSave_expandsATilde_andMakesItsFolders() throws {
        let nested = "\(directory)/out/ci/\(BaselineFile.fileName)"
        XCTAssertTrue(file([], at: nested).save(using: FileManager.default))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested))

        XCTAssertEqual(URL.expandingTilde("~/b.yml"), NSHomeDirectory() + "/b.yml")
    }

    func test_aMinimalFile_reads() throws {
        let read = try load(minimal)

        XCTAssertEqual(read.survivors, [])
        XCTAssertNil(read.scope.configuration.mutationTestTimeout)
        XCTAssertNil(read.scope.configuration.buildSystem)
    }

    func test_noFile_isRefused_sayingHowToWriteOne() {
        XCTAssertThrowsError(try BaselineFile.load(at: path, using: FileManager.default)) { error in
            XCTAssertEqual(
                "\(error)",
                "SwiftMutator won't compare the survivors with the baseline file \(Logger.shellQuoted(path)):\n"
                    + "  - There is no baseline file there. Write one with --write-baseline."
            )
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .baselineRefused)
        }
    }

    func test_textThatIsntUTF8_isRefused() throws {
        try Data([0xFF, 0xFE, 0x00]).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try BaselineFile.load(at: path, using: FileManager.default)) { error in
            XCTAssertTrue("\(error)".contains("It isn't UTF-8."), "\(error)")
        }
    }

    func test_anUnknownKey_atAnyDepth_isRefused() {
        assertRefused(minimal + "\ncolour: red", saying: "colour isn't a key of the file: give formatVersion")
        assertRefused(
            minimal.replacingOccurrences(of: "  scored: 2", with: "  scored: 2\n  score: 3"),
            saying: "score isn't a key of score: give killed, scored."
        )
        assertRefused(
            minimal.replacingOccurrences(of: "  skipCoverage: false", with: "  skipCoverage: false\n  shard: 1/2"),
            saying: "shard isn't a key of scope"
        )
        assertRefused(
            minimal.replacingOccurrences(of: "    excludeCalls: []", with: "    excludeCalls: []\n    executable: x"),
            saying: "executable isn't a key of scope.configuration"
        )
        assertRefused(
            minimal.replacingOccurrences(
                of: "survivors: []",
                with: "survivors:\n- mutant: A.swift:1:2 SwapTernary\n  outcome: survived\n  before: a\n  after: b\n"
                    + "  label: x"
            ),
            saying: "label isn't a key of a survivor's entry"
        )
    }

    func test_aNewerFormat_isRefused() {
        assertRefused(
            minimal.replacingOccurrences(of: "formatVersion: 1", with: "formatVersion: 2\nsomethingNew: true"),
            saying: "Its format is version 2, newer than this SwiftMutator reads (1)."
        )
    }

    func test_aMissingKey_orAWrongValue_isRefused() {
        assertRefused(
            minimal.replacingOccurrences(of: "swiftMutator: 0.1.0\n", with: ""),
            saying: "It isn't a baseline file SwiftMutator can read"
        )
        assertRefused("- a\n- b\n", saying: "It isn't a baseline file SwiftMutator can read")
        let entry = "survivors:\n- mutant: %@\n  outcome: %@\n  before: a\n  after: b\n"
        assertRefused(
            minimal.replacingOccurrences(
                of: "survivors: []",
                with: String(format: entry, "A.swift:1", "survived")
            ),
            saying: "A.swift:1 isn't a whole mutant key"
        )
        assertRefused(
            minimal.replacingOccurrences(
                of: "survivors: []",
                with: String(format: entry, "A.swift:1:2 SwapTernary", "lived")
            ),
            saying: "has the outcome lived: give survived, timedOut or notCovered."
        )
        assertRefused(
            minimal.replacingOccurrences(
                of: "survivors: []",
                with: String(format: entry, "A.swift:1:2 SwapTernary", "survived")
                    + String(format: entry, "A.swift:1:2 SwapTernary", "survived")
                        .replacingOccurrences(of: "survivors:\n", with: "")
            ),
            saying: "A.swift:1:2 SwapTernary is listed more than once."
        )
    }

    // A hand edit can leave counts no run gives, whose score `--max-score-drop` would compare as if a run gave it.
    func test_aScoreNoRunGives_isRefused() {
        let counted = { (killed: Int, scored: Int) in
            self.minimal.replacingOccurrences(
                of: "  killed: 1\n  scored: 2",
                with: "  killed: \(killed)\n  scored: \(scored)"
            )
        }
        for (killed, scored) in [(900, 800), (-1, 2), (1, -5), (-3, -5)] {
            assertRefused(
                counted(killed, scored),
                saying: "Its score counts killed \(killed) of \(scored) scored: give scored from 0 up, and killed "
                    + "from 0 to scored."
            )
        }
        XCTAssertNoThrow(try load(counted(0, 0)))
        XCTAssertNoThrow(try load(counted(2, 2)))
    }
}
