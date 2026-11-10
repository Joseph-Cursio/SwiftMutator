import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

extension ReportCommandTests {
    /// The header of shard `index` of `count` of the 3 mutants, which holds `mutantsDiscovered` of them: Alpha.swift:3
    /// and Zeta.swift:9 in shard 1, Zeta.swift:10 in shard 2, by default.
    func shardHeader(
        _ index: Int,
        mutantsDiscovered: Int,
        count: Int = 2,
        mutantsPerShard: [Int] = [2, 1]
    ) -> ResultsHeader {
        ResultsHeader.make(
            mutantsDiscovered: mutantsDiscovered,
            mutantsToTest: mutantsDiscovered,
            project: ProjectTree(
                listedBy: .git,
                files: ["Sources/Zeta.swift": "ab12"],
                excluded: [],
                treeSHA256: "cd34"
            ),
            shard: .make(
                index: index,
                count: count,
                mutantsInAllShards: mutantsPerShard.reduce(0, +),
                mutantsPerShard: mutantsPerShard
            )
        )
    }

    /// Runs `swift-mutator report` with `arguments`.
    func report(_ arguments: String...) async throws {
        try await report(arguments)
    }

    /// Runs `swift-mutator report` with `arguments`.
    func report(_ arguments: [String]) async throws {
        let command = try MuterCommand.parseAsRoot(["report"] + arguments)
        guard let report = command as? Report else {
            XCTFail("Expected the report command, got \(command)")
            return
        }
        try await report.run()
    }

    /// Checks that `expression` throws `expected`, which ArgumentParser shows as `message` on standard error, with exit
    /// status 1, and that nothing else is printed on either.
    func assertRefused<Failure: Error & Equatable>(
        _ expression: @autoclosure () async throws -> Void,
        _ expected: Failure,
        saying message: String? = nil,
        _ context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await AssertThrowsError(try await expression(), context, file: file, line: line) { error in
            XCTAssertEqual(error as? Failure, expected, context, file: file, line: line)
            XCTAssertEqual(MuterCommand.exitCode(for: error), .failure, context, file: file, line: line)
            if let message {
                XCTAssertEqual(MuterCommand.fullMessage(for: error), message, context, file: file, line: line)
            }
        }
        XCTAssertEqual(printer.linesPassed, [], context, file: file, line: line)
        XCTAssertEqual(standardError.linesPassed, [], context, file: file, line: line)
    }

    /// The log folders of a run resumed once, in `<directory>/project_muter_logs`: the first session's, which holds the
    /// results file, starting with `header`, and the resumed session's, which holds only its note naming the file.
    func makeAResumedRunsLogFolders(
        header: ResultsHeader = .make()
    ) throws -> (first: String, resumed: String) {
        let logs = "\(directory)/project_muter_logs"
        let first = "\(logs)/session 1"
        let resumed = "\(logs)/session 2"
        for folder in [first, resumed] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        try write(header, zeta9, alpha3, zeta10, ResultsEnd.make(), to: "\(first)/results.jsonl")
        try writeNote(pointingTo: "\(first)/results.jsonl", session: 2, in: resumed)
        return (first, resumed)
    }

    /// Writes the note the `session`th session of a resumed run leaves in its log folder, `folder`.
    func writeNote(pointingTo path: String, session: Int, in folder: String) throws {
        let note = Data(ResultsFile.note(pointingTo: path, session: session).utf8)
        try note.write(to: URL(fileURLWithPath: "\(folder)/\(ResultsFile.noteFileName)"))
    }

    /// A triage file at `path` with `label` for `zeta9`.
    func writeTriage(to path: String, label: String) throws {
        try """
        mutants:
        - mutant: Sources/Zeta.swift:9:22 RelationalOperatorReplacement
          label: \(label)
        """.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func XCTAssertThrowsErrorAsync(
        _ expression: @autoclosure () async throws -> Void,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected an error", line: line)
        } catch {
            // The error is the expected outcome.
        }
    }

    /// JSONEncoder promises no order of keys, so JSON compares parsed.
    func parsedJSON(_ text: String) throws -> [String: AnyHashable] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: AnyHashable], text)
    }

    func write(_ records: any Encodable..., to path: String) throws {
        try write(records, to: path)
    }

    func write(_ records: [any Encodable], to path: String) throws {
        let data = try records.reduce(into: Data()) { data, record in
            data += try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// The mutant `MutantResult.make` records at `line` of `path`, as the run reported it.
    func mutation(
        _ path: String,
        line: Int,
        _ outcome: TestSuiteOutcome,
        killingTests: MutationTestOutcome.KillingTests? = nil
    ) -> MutationTestOutcome.Mutation {
        MutationTestOutcome.Mutation(
            testSuiteOutcome: outcome,
            mutationPoint: MutationPoint(
                mutationOperatorId: .ror,
                filePath: "/project_mutated/\(path)",
                position: MutationPosition(utf8Offset: 3_361, line: line, column: 22)
            ),
            mutationSnapshot: .make(before: ">", after: "<", description: "changed > to <"),
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/project", isDirectory: true),
            mutatedProjectDirectoryURL: URL(fileURLWithPath: "/project_mutated", isDirectory: true),
            killingTests: killingTests,
            reusedFrom: nil,
            key: MutantKey(path: path, mutationOperatorId: .ror, line: line, column: 22, occurrence: 0),
            durationSeconds: 31.25
        )
    }
}
