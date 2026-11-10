import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

extension ReportCommandTests {
    func test_severalShardsResultsFiles_areMergedIntoTheWholeRunsReport() async throws {
        let first = "\(directory)/first.jsonl"
        let second = "\(directory)/second.jsonl"
        try write(
            shardHeader(1, mutantsDiscovered: 2),
            zeta9,
            alpha3,
            ResultsEnd.make(testDurationSeconds: 60),
            to: first
        )
        try write(shardHeader(2, mutantsDiscovered: 1), zeta10, ResultsEnd.make(), to: second)

        try await report(second, first)

        // The shards' files in shard order; their details are the first shard's.
        let reported = expected(from: [first, second], header: shardHeader(1, mutantsDiscovered: 2))
        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: reported)])
        XCTAssertEqual(standardError.linesPassed, [
            "Report of 3 of 3 mutants, merged from the results files of 2 of 2 shards.",
            "Shard 1 of 2, 2 of its 2 mutants, from \(first): the run finished.",
            "Shard 2 of 2, 1 of its 1 mutant, from \(second): the run finished.",
        ])
    }

    // As a merge of one: a CI job's glob that finds only one shard's file fails as one that finds two of three would.
    func test_oneShardsFile_isReportedAsTheShard_andLacksTheOthers() async throws {
        try write(shardHeader(1, mutantsDiscovered: 2), zeta9, alpha3, ResultsEnd.make(), to: resultsPath)

        await AssertThrowsError(try await report(resultsPath)) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
        }

        XCTAssertEqual(
            printer.linesPassed.first?.contains("Only the mutants in shard 1 of 2 were tested, of 3 discovered"),
            true
        )
        XCTAssertEqual(standardError.linesPassed, [
            "Report of 2 of 2 mutants in shard 1 of 2, from \(resultsPath): the run finished.",
            "No results were given for shard 2 of 2, which holds 1 mutant.",
        ])
    }

    // A small change can leave every other shard empty, and then one file is the whole run.
    func test_oneShardsFile_whoseOthersAreEmpty_isTheWholeRunsReport() async throws {
        try write(
            shardHeader(1, mutantsDiscovered: 3, mutantsPerShard: [3, 0]),
            zeta9,
            alpha3,
            zeta10,
            ResultsEnd.make(),
            to: resultsPath
        )

        try await report(resultsPath, "--merge-ignoring", "*.md")

        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: expected)])
        XCTAssertEqual(standardError.linesPassed.last, "Shard 2 of 2 holds no mutant, so it has no results file.")
    }

    // A CI job that checks the merged report fails, as the missing shard's own job may not have.
    func test_aShardThatHoldsMutantsButIsntGiven_isReported_thenExitsAsAnAbortedRunDoes() async throws {
        let split = [2, 1, 1]
        try write(
            shardHeader(1, mutantsDiscovered: 2, count: 3, mutantsPerShard: split),
            zeta9,
            alpha3,
            ResultsEnd.make(),
            to: "\(directory)/1.jsonl"
        )
        try write(
            shardHeader(3, mutantsDiscovered: 1, count: 3, mutantsPerShard: split),
            zeta10,
            ResultsEnd.make(),
            to: "\(directory)/3.jsonl"
        )

        await AssertThrowsError(try await report("\(directory)/1.jsonl", "\(directory)/3.jsonl")) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
        }
        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(
            standardError.linesPassed.last,
            "No results were given for shard 2 of 3, which holds 1 mutant."
        )
    }

    func test_shardsThatCantBeMerged_areRefused_withExitStatus1() async throws {
        try write(shardHeader(1, mutantsDiscovered: 2), to: "\(directory)/1.jsonl")
        try write(ResultsHeader.make(), to: "\(directory)/whole.jsonl")

        await assertRefused(
            try await report("\(directory)/1.jsonl", "\(directory)/whole.jsonl"),
            MergeRefused(reasons: [.notAShard(path: "\(directory)/whole.jsonl")]),
            saying: """
            Error: SwiftMutator won't merge these results files, so that the report holds only results a whole run \
            would give:
              - '\(directory)/whole.jsonl' isn't the results file of a shard (run --shard), so it can't be merged \
            with others.
            """
        )
    }

    func test_neverWritesOverAnyOfTheShardsFiles() async throws {
        try write(shardHeader(1, mutantsDiscovered: 2), to: "\(directory)/1.jsonl")
        try write(shardHeader(2, mutantsDiscovered: 1), to: "\(directory)/2.jsonl")

        await assertRefused(
            try await report("\(directory)/1.jsonl", "\(directory)/2.jsonl", "-o", "\(directory)/2.jsonl"),
            MuterError.literal(
                reason: "\(directory)/2.jsonl is one of the results files the report is made from: choose another "
                    + "output path"
            )
        )
    }

    // How many files a CI job's glob finds is up to the shards, so a merge's flags are no mistake with one.
    func test_mergeOptions_areAcceptedWithAnyNumberOfFiles() throws {
        for files in [["r.jsonl"], ["1.jsonl", "2.jsonl"]] {
            let arguments = ["report"] + files + ["--force-merge", "--merge-ignoring", "*.md"]
            let command = try MuterCommand.parseAsRoot(arguments)
            let report = try XCTUnwrap(command as? Report)
            XCTAssertTrue(report.forceMerge)
            XCTAssertEqual(report.mergeIgnoring, ["*.md"])
        }
    }
}
