@testable import muterCore
import XCTest

/// The triage file: what it reads, what it refuses, and what it writes back.
final class TriageFileTests: MuterTestCase {
    private var directory = ""
    private var path: String { "\(directory)/\(TriageFile.fileName)" }
    private let key = MutantKey(path: "Sources/A.swift", mutationOperatorId: .ror, line: 3, column: 9, occurrence: 0)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory()
    }

    private func load(_ text: String) throws -> TriageFile? {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return try TriageFile.load(at: path, using: FileManager.default)
    }

    private func assertRefused(_ text: String, saying words: String, line: UInt = #line) {
        XCTAssertThrowsError(try load(text), line: line) { error in
            XCTAssertTrue("\(error)".contains(words), "\(error)", line: line)
            XCTAssertTrue("\(error)".contains(path), "names the file: \(error)", line: line)
        }
    }

    func test_noFile_isNoTriage() throws {
        XCTAssertNil(try TriageFile.load(at: path, using: FileManager.default))
    }

    func test_aFileWithNothingInIt_hasNoEntries() throws {
        for text in ["", "\n", "# nothing yet\n", "mutants: []\n", "mutants:\n"] {
            XCTAssertEqual(try load(text)?.entries, [], text)
        }
    }

    func test_readsAWholeEntry() throws {
        let file = try load(
            """
            mutants:
            - mutant: Sources/A.swift:3:9 RelationalOperatorReplacement
              label: out-of-scope
              note: generated code
              before: '=='
              after: '!='
              line: '   if a == b {   '
            """
        )

        XCTAssertEqual(file?.entries, [
            TriageEntry(
                mutant: key,
                label: .outOfScope,
                note: "generated code",
                before: "==",
                after: "!=",
                line: "if a == b {"
            ),
        ])
    }

    func test_anEntryWrittenByHand_needsOnlyItsMutantAndLabel() throws {
        let file = try load(
            """
            mutants:
            - mutant: Sources/A.swift:3:9 RelationalOperatorReplacement (#2)
              label: equivalent
            """
        )

        XCTAssertEqual(file?.entries.first?.mutant.occurrence, 1)
        XCTAssertEqual(file?.entries.first?.label, .equivalent)
        XCTAssertNil(file?.entries.first?.line)
    }

    func test_anUnknownLabel_isRefused_withTheOnesThereAre() {
        assertRefused(
            "mutants:\n- mutant: Sources/A.swift:3:9 RelationalOperatorReplacement\n  label: wontfix\n",
            saying: "the label wontfix: give missing-test, equivalent, out-of-scope or tool-limitation"
        )
    }

    func test_aMutantThatIsntAWholeKey_isRefused() {
        for mutant in ["Sources/A.swift:3", "Sources/A.swift:3:9", "Sources/A.swift:3 RelationalOperatorReplacement"] {
            assertRefused(
                "mutants:\n- mutant: \(mutant)\n  label: equivalent\n",
                saying: "\(mutant) isn't a whole mutant key"
            )
        }
    }

    func test_twoLabelsForOneMutant_areRefused() {
        assertRefused(
            """
            mutants:
            - mutant: Sources/A.swift:3:9 RelationalOperatorReplacement
              label: equivalent
            - mutant: Sources/A.swift:3:9 RelationalOperatorReplacement
              label: missing-test
            """,
            saying: "has more than one label"
        )
    }

    func test_brokenYAML_isRefused() {
        assertRefused("mutants: [", saying: "Could not read")
        assertRefused("mutants:\n- mutant: Sources/A.swift:3:9 SwapTernary\n", saying: "Could not read")
    }

    // Saving over them would lose them unsaid.
    func test_aKeyItDoesntKnow_isRefused() {
        assertRefused(
            "mutant:\n- mutant: Sources/A.swift:3:9 RelationalOperatorReplacement\n  label: equivalent\n",
            saying: "mutant isn't a key of this file"
        )
        assertRefused(
            "mutants:\n- mutant: Sources/A.swift:3:9 RelationalOperatorReplacement\n  label: equivalent\n  not: why\n",
            saying: "not isn't a key of a mutant's entry"
        )
    }

    func test_aFileThatIsntUTF8_isRefused() throws {
        let bytes = Data("mutants: []\n# caf".utf8) + Data([0xE9])
        try bytes.write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try TriageFile.load(at: path, using: FileManager.default)) { error in
            XCTAssertTrue("\(error)".contains("isn't UTF-8"), "\(error)")
        }
    }

    func test_aFileThatCantBeOpened_isRefused_notTakenForNone() throws {
        try "mutants: []\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        addTeardownBlock { [path] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        }

        XCTAssertThrowsError(try TriageFile.load(at: path, using: FileManager.default))
    }

    func test_savingThroughASymbolicLink_keepsTheLink_andWritesTheFileItPointsTo() throws {
        let target = "\(directory)/shared.yml"
        try "mutants: []\n".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

        var file = try XCTUnwrap(try TriageFile.load(at: path, using: FileManager.default))
        file.entries = [TriageEntry(mutant: key, label: .equivalent)]
        try file.save(using: FileManager.default)

        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: path))
        XCTAssertTrue(try String(contentsOfFile: target, encoding: .utf8).contains("equivalent"))
    }

    func test_savesInOrder_andReadsBackWhatItSaved() throws {
        let second = TriageEntry(
            mutant: MutantKey(path: "Sources/A.swift", mutationOperatorId: .ror, line: 10, column: 1, occurrence: 0),
            label: .toolLimitation,
            note: "quotes: \"x\", a colon, # and\nanother line",
            before: "a ? \"b\" : 'c'",
            after: "- not a list",
            line: "let x = [\"{\": 1] // #"
        )
        let first = TriageEntry(mutant: key, label: .missingTest)
        let last = TriageEntry(
            mutant: MutantKey(path: "Sources/B c.swift", mutationOperatorId: .ror, line: 1, column: 1, occurrence: 2),
            label: .equivalent
        )

        try TriageFile(path: path, entries: [last, second, first]).save(using: FileManager.default)

        let read = try TriageFile.load(at: path, using: FileManager.default)
        XCTAssertEqual(read?.entries, [first, second, last], "by line as a number: 3 comes before 10")
    }

    func test_aFileThatCantBeSaved_isSaid() {
        let file = TriageFile(path: "\(directory)/no such folder/\(TriageFile.fileName)", entries: [])

        XCTAssertThrowsError(try file.save(using: FileManager.default))
    }
}
