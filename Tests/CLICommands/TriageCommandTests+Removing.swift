import ArgumentParser
@testable import muterCore
import XCTest

extension TriageCommandTests {
    func test_removing_withResults_takesThePlaceTheyShow() async throws {
        try writeShiftedResults()
        try writeShiftedLabels()

        try await triage(zeta(line: 4).description, "--remove", "--results", resultsPath)

        XCTAssertEqual(try saved?.map(\.note), ["second"], "line 4 shows the first label, whose key is line 3")
        XCTAssertEqual(
            printer.linesPassed.last?.contains("equivalent, a > b, first"),
            true,
            "\(printer.linesPassed)"
        )
    }

    func test_removing_withResults_takesALabelThatMatchesNoMutantInThem() async throws {
        try writeShiftedResults()
        try TriageFile(path: triagePath, entries: [TriageEntry(mutant: zeta(line: 90), label: .equivalent)])
            .save(using: FileManager.default)

        try await triage("Zeta.swift:90", "--remove", "--results", resultsPath)

        XCTAssertEqual(try saved, [])
    }

    func test_removing_withResults_refusesAnUnlabelledMutant_ThoughAMovedLabelHasItsKey() async throws {
        try writeShiftedResults()
        try TriageFile(path: triagePath, entries: [
            TriageEntry(mutant: zeta(line: 4), label: .outOfScope, before: ">", after: "<", line: "c > d"),
        ]).save(using: FileManager.default)

        await assertRefused(
            try await triage(zeta(line: 4).description, "--remove", "--results", resultsPath),
            saying: "has no label for"
        )
        XCTAssertEqual(try saved?.count, 1)
    }

    func test_removes_aLabelThatMatchesNoMutantNow() async throws {
        let kept = MutantKey(path: "Sources/B.swift", mutationOperatorId: .ror, line: 2, column: 2, occurrence: 0)
        let gone = MutantKey(path: "Sources/A.swift", mutationOperatorId: .ror, line: 2, column: 2, occurrence: 0)
        try TriageFile(path: triagePath, entries: [
            TriageEntry(mutant: kept, label: .equivalent),
            TriageEntry(mutant: gone, label: .equivalent),
        ]).save(using: FileManager.default)

        try await triage("A.swift:2", "--remove", "--file", triagePath)

        XCTAssertEqual(try saved?.map(\.mutant), [kept])
    }

    func test_removing_whatsNotThere_isSaid() async throws {
        await assertRefused(
            try await triage("A.swift:2", "--remove", "--file", triagePath),
            saying: "There is no triage file"
        )

        try TriageFile(path: triagePath, entries: []).save(using: FileManager.default)
        await assertRefused(
            try await triage("A.swift:2", "--remove", "--file", triagePath),
            saying: "has no label for A.swift:2"
        )
    }

    func test_removing_aReferenceThatNamesSeveral_removesNone() async throws {
        let first = MutantKey(path: "Sources/A.swift", mutationOperatorId: .ror, line: 2, column: 2, occurrence: 0)
        let second = MutantKey(path: "Sources/A.swift", mutationOperatorId: .ror, line: 2, column: 8, occurrence: 0)
        try TriageFile(path: triagePath, entries: [
            TriageEntry(mutant: first, label: .equivalent),
            TriageEntry(mutant: second, label: .equivalent),
        ]).save(using: FileManager.default)

        await assertRefused(try await triage("A.swift:2", "--remove", "--file", triagePath), saying: "names 2")
        XCTAssertEqual(try saved?.count, 2)
    }
}
