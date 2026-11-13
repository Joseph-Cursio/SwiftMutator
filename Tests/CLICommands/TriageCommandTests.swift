import ArgumentParser
@testable import muterCore
import XCTest

/// `swift-mutator triage`: parsed as the command line gives it, then run on results files in a temporary folder.
final class TriageCommandTests: MuterTestCase {
    private var directory = ""
    var resultsPath: String { "\(directory)/results.jsonl" }
    var triagePath: String { "\(directory)/\(TriageFile.fileName)" }
    private let survivor = "Sources/Zeta.swift:9:22 RelationalOperatorReplacement"
    /// Line 9 of Zeta.swift, with `MutantResult.make`'s `>` at its column, 22.
    private let source = Data((String(repeating: "\n", count: 8) + String(repeating: " ", count: 19) + "a > b\n").utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory()
    }

    override func setUp() {
        super.setUp()
        current.fileManager = FileManager.default
        current.readSourceFile = { [source] _ in source }
    }

    /// A run in `directory` where line 9 of Zeta.swift survived and line 3 of Alpha.swift was killed.
    private func writeResults() throws {
        let records: [any Encodable] = [
            ResultsHeader.make(projectPath: directory, mutantsDiscovered: 2),
            MutantResult.make(path: "Sources/Zeta.swift", line: 9, outcome: .passed),
            MutantResult.make(path: "Sources/Alpha.swift", line: 3, outcome: .failed),
            ResultsEnd.make(),
        ]
        let data = try records.reduce(into: Data()) { data, record in
            data += try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
        }
        try data.write(to: URL(fileURLWithPath: resultsPath))
    }

    func triage(_ arguments: String...) throws {
        let command = try MuterCommand.parseAsRoot(["triage"] + arguments)
        guard let triage = command as? Triage else {
            XCTFail("Expected triage, got \(command)")
            return
        }
        try triage.run()
    }

    var saved: [TriageEntry]? {
        get throws { try TriageFile.load(at: triagePath, using: FileManager.default)?.entries }
    }

    func test_parsing_needsALabelAndResults_orRemove() {
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["triage"]))
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["triage", survivor]))
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["triage", survivor, "--label", "equivalent"]))
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["triage", survivor, "--results", "r", "--label", "nope"]))
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["triage", "not a mutant", "--remove"]))
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["triage", survivor, "--remove", "--label", "equivalent"]))
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["triage", survivor, "--remove", "--note", "why"]))
        XCTAssertNoThrow(try MuterCommand.parseAsRoot(["triage", survivor, "--remove"]))
        XCTAssertNoThrow(try MuterCommand.parseAsRoot(["triage", survivor, "--remove", "--results", "r"]))
        XCTAssertNoThrow(try MuterCommand.parseAsRoot(["triage", survivor, "--results", "r", "--label", "equivalent"]))
    }

    func test_labelsASurvivor_inTheProjectsFile_withWhatItChanges() throws {
        try writeResults()

        try triage("Zeta.swift:9", "--results", resultsPath, "--label", "equivalent", "--note", "  why  ")

        let entry = try XCTUnwrap(try saved?.first)
        XCTAssertEqual(entry.mutant.description, survivor)
        XCTAssertEqual(entry.label, .equivalent)
        XCTAssertEqual(entry.note, "why")
        XCTAssertEqual(entry.line, "a > b")
        XCTAssertEqual(entry.before, ">")
        XCTAssertEqual(entry.after, "<")
        XCTAssertEqual(printer.linesPassed, ["\(survivor): equivalent, in \(triagePath)"])
    }

    func test_takesAFolderOfTheRun_andAFileItsTold() throws {
        try writeResults()
        let other = "\(directory)/elsewhere.yml"

        try triage(survivor, "--results", directory, "--label", "missing-test", "--file", other)

        XCTAssertEqual(try TriageFile.load(at: other, using: FileManager.default)?.entries.first?.label, .missingTest)
        XCTAssertNil(try saved)
    }

    func test_aProjectThatsGone_usesTheCurrentFolder() throws {
        let records: [any Encodable] = [
            ResultsHeader.make(projectPath: "/no/such/project"),
            MutantResult.make(path: "Sources/Zeta.swift", line: 9, outcome: .passed),
        ]
        let data = try records.reduce(into: Data()) { data, record in
            data += try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
        }
        try data.write(to: URL(fileURLWithPath: resultsPath))
        let before = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(directory)
        defer { FileManager.default.changeCurrentDirectoryPath(before) }

        try triage(survivor, "--results", resultsPath, "--label", "equivalent")

        XCTAssertEqual(try saved?.count, 1)
    }

    func test_labellingAgain_replacesTheLabel() throws {
        try writeResults()

        try triage(survivor, "--results", resultsPath, "--label", "equivalent", "--note", "first")
        try triage(survivor, "--results", resultsPath, "--label", "missing-test")

        XCTAssertEqual(try saved?.map(\.label), [.missingTest])
        XCTAssertNil(try saved?.first?.note)
    }

    func test_labellingCodeThatMoved_replacesTheLabelItFollowed() throws {
        try writeResults()
        let earlier = MutantKey(
            path: "Sources/Zeta.swift", mutationOperatorId: .ror, line: 2, column: 22, occurrence: 0
        )
        try TriageFile(path: triagePath, entries: [
            TriageEntry(mutant: earlier, label: .equivalent, before: ">", after: "<", line: "a > b"),
        ]).save(using: FileManager.default)

        try triage(survivor, "--results", resultsPath, "--label", "out-of-scope")

        XCTAssertEqual(try saved?.map(\.mutant.description), [survivor])
        XCTAssertEqual(try saved?.map(\.label), [.outOfScope])
    }

    /// `first` and `second` at the places they were before a line was added above each, and results where they're
    /// at lines 4 and 5, with the `>` of each at `MutantResult.make`'s column.
    func writeShiftedResults(mutantsDiscovered: Int = 2, onlyLine4: Bool = false) throws {
        let pad = String(repeating: " ", count: 19)
        let text = "\n\n\n\(pad)a > b\n\(pad)c > d\n"
        current.readSourceFile = { _ in Data(text.utf8) }
        var records: [any Encodable] = [
            ResultsHeader.make(projectPath: directory, mutantsDiscovered: mutantsDiscovered),
            MutantResult.make(path: "Sources/Zeta.swift", line: 4, outcome: .passed),
        ]
        if !onlyLine4 {
            records.append(MutantResult.make(path: "Sources/Zeta.swift", line: 5, outcome: .passed))
        }
        let data = try records.reduce(into: Data()) { data, record in
            data += try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
        }
        try data.write(to: URL(fileURLWithPath: resultsPath))
    }

    func zeta(line: Int) -> MutantKey {
        MutantKey(path: "Sources/Zeta.swift", mutationOperatorId: .ror, line: line, column: 22, occurrence: 0)
    }

    /// Labels whose code moved down a line, so that the second's key is the place the first is now at.
    func writeShiftedLabels() throws {
        try TriageFile(path: triagePath, entries: [
            TriageEntry(
                mutant: zeta(line: 3), label: .equivalent, note: "first", before: ">", after: "<", line: "a > b"
            ),
            TriageEntry(
                mutant: zeta(line: 4), label: .outOfScope, note: "second", before: ">", after: "<", line: "c > d"
            ),
        ]).save(using: FileManager.default)
    }

    func test_labellingAPlace_leavesTheLabelWhoseOldKeyIsThatPlace_andSavesItWhereItIsNow() throws {
        try writeShiftedResults()
        try writeShiftedLabels()

        try triage(zeta(line: 4).description, "--results", resultsPath, "--label", "missing-test")

        let entries = try XCTUnwrap(try saved)
        XCTAssertEqual(entries.map(\.mutant.line), [4, 5])
        XCTAssertEqual(entries.map(\.label), [.missingTest, .outOfScope])
        XCTAssertEqual(entries.map(\.note), [nil, "second"])
        XCTAssertTrue(printer.linesPassed.contains { $0.contains("saved at its new place") }, "\(printer.linesPassed)")
    }

    func test_aLabelThatMatchesNothing_whosePlaceIsTaken_isDroppedAndNamed() throws {
        try writeShiftedResults()
        try TriageFile(path: triagePath, entries: [
            TriageEntry(mutant: zeta(line: 4), label: .outOfScope, before: ">", after: "<", line: "gone > now"),
            TriageEntry(mutant: zeta(line: 90), label: .equivalent, before: ">", after: "<", line: "gone > too"),
        ]).save(using: FileManager.default)

        try triage(zeta(line: 4).description, "--results", resultsPath, "--label", "missing-test")

        XCTAssertEqual(try saved?.map(\.mutant.line), [4, 90], "line 90's matches nothing, and is kept")
        XCTAssertEqual(try saved?.map(\.label), [.missingTest, .equivalent])
        XCTAssertTrue(printer.linesPassed.contains { $0.contains("Dropped the label of \(zeta(line: 4))") })
    }

    // Only line 4 of 2 was tested. Line 2's label isn't line 4's, though their lines are the same.
    func test_labellingFromResultsThatLeaveOutMutants_keepsATwinsLabel() throws {
        try writeShiftedResults(mutantsDiscovered: 3, onlyLine4: true)
        try TriageFile(path: triagePath, entries: [
            TriageEntry(mutant: zeta(line: 2), label: .equivalent, before: ">", after: "<", line: "a > b"),
        ]).save(using: FileManager.default)

        try triage(zeta(line: 4).description, "--results", resultsPath, "--label", "missing-test")

        XCTAssertEqual(try saved?.map(\.mutant.line), [2, 4])
    }

    func test_aPathInTheCopy_namesTheMutant_asItDoesForDashDashMutant() throws {
        let copy = "\(directory)_mutated"
        let records: [any Encodable] = [
            ResultsHeader.make(projectPath: directory, mutatedProjectPath: copy),
            MutantResult.make(path: "Sources/Zeta.swift", line: 9, outcome: .passed),
        ]
        let data = try records.reduce(into: Data()) { data, record in
            data += try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
        }
        try data.write(to: URL(fileURLWithPath: resultsPath))

        try triage("\(copy)/\(survivor)", "--results", resultsPath, "--label", "equivalent")

        XCTAssertEqual(try saved?.map(\.mutant.description), [survivor])
    }

    func test_otherLabels_areKept() throws {
        try writeResults()
        let other = MutantKey(path: "Sources/Old.swift", mutationOperatorId: .ror, line: 2, column: 2, occurrence: 0)
        try TriageFile(path: triagePath, entries: [TriageEntry(mutant: other, label: .equivalent)])
            .save(using: FileManager.default)

        try triage(survivor, "--results", resultsPath, "--label", "missing-test")

        XCTAssertEqual(try saved?.count, 2)
    }

    func test_aFileWhoseLineCantBeRead_isLabelled_andSaysItWontFollow() throws {
        try writeResults()
        current.readSourceFile = { _ in nil }

        try triage(survivor, "--results", resultsPath, "--label", "equivalent")

        XCTAssertNil(try saved?.first?.line)
        XCTAssertEqual(try saved?.first?.before, ">")
        XCTAssertEqual(
            printer.linesPassed.last?.contains("it won't follow the code"),
            true,
            "\(printer.linesPassed)"
        )
    }

    func test_aMutantThatDidntSurvive_takesNoLabel() async throws {
        try writeResults()

        await assertRefused(
            try triage("Alpha.swift:3", "--results", resultsPath, "--label", "equivalent"),
            saying: "didn't survive this run (killed)"
        )
        XCTAssertNil(try saved)
    }

    func test_aMutantThatsntThere_takesNoLabel() async throws {
        try writeResults()

        await assertRefused(
            try triage("Zeta.swift:99", "--results", resultsPath, "--label", "equivalent"),
            saying: "These results have no mutant at Zeta.swift:99."
        )
    }

    func test_aReferenceThatNamesSeveral_listsThem() async throws {
        let records: [any Encodable] = [
            ResultsHeader.make(projectPath: directory),
            MutantResult.make(path: "Sources/Zeta.swift", line: 9, outcome: .passed),
            MutantResult.make(path: "Other/Zeta.swift", line: 9, outcome: .passed),
        ]
        let data = try records.reduce(into: Data()) { data, record in
            data += try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
        }
        try data.write(to: URL(fileURLWithPath: resultsPath))

        await assertRefused(
            try triage("Zeta.swift:9", "--results", resultsPath, "--label", "equivalent"),
            saying: "Other/Zeta.swift:9:22 RelationalOperatorReplacement"
        )
    }

    func test_aBrokenFile_isLeftAlone() async throws {
        try writeResults()
        try "mutants: [".write(toFile: triagePath, atomically: true, encoding: .utf8)

        await assertRefused(
            try triage(survivor, "--results", resultsPath, "--label", "equivalent"),
            saying: "Could not read"
        )
        XCTAssertEqual(try String(contentsOfFile: triagePath, encoding: .utf8), "mutants: [")
    }

    func assertRefused(
        _ expression: @autoclosure () async throws -> Void,
        saying words: String,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected a refusal", line: line)
        } catch {
            XCTAssertTrue("\(error)".contains(words), "\(error)", line: line)
        }
    }
}
