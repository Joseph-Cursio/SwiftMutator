@testable import muterCore
import XCTest

final class SampleTests: XCTestCase {
    private let mutatedRoot = URL(fileURLWithPath: "/project_mutated")

    // A change to how a place is ranked takes another sample with the same seed, which breaks a trend line: these pin
    // it.
    func test_aPlacesRank_isFixed() {
        XCTAssertEqual(
            [1, 2, 1234].map { Sample.rank(ofPlace: key("Sources/Sum.swift", line: 3, column: 4), seed: $0) },
            [11_193_250_018_876_588_436, 4_200_978_237_720_625_508, 9_794_570_722_480_245_170]
        )
    }

    func test_aPlacesRepeats_shareItsRank() {
        for seed: UInt64 in [0, 1, 99] {
            XCTAssertEqual(
                Sample.rank(ofPlace: key("Sources/Sum.swift", line: 3, column: 5), seed: seed),
                Sample.rank(ofPlace: key("Sources/Sum.swift", line: 3, column: 5, occurrence: 1), seed: seed)
            )
        }
    }

    func test_theSameSeed_takesTheSameSample_whateverTheOrderOfTheFiles() throws {
        let mappings = try manyPlaces()
        let sample = Sample(size: 40, seed: 1234, seedIsChosen: false)

        let first = keys(of: mappings.keepingSample(sample, under: mutatedRoot).mappings)
        let reordered = keys(of: Array(mappings.reversed()).keepingSample(sample, under: mutatedRoot).mappings)

        XCTAssertEqual(first.count, 40)
        XCTAssertEqual(Set(first), Set(reordered))
        let other = keys(of: mappings.keepingSample(Sample(size: 40, seed: 99, seedIsChosen: false), under: mutatedRoot)
            .mappings)
        XCTAssertNotEqual(Set(first), Set(other))
    }

    func test_theSample_keepsTheWholeRunsKeys_andAPlacesRepeatsTogether() throws {
        let mappings = try [
            mapping("/project_mutated/Sources/Sum.swift", places: [(3, 4), (3, 5), (3, 5), (9, 1)]),
            mapping("/project_mutated/Sources/Other.swift", places: [(10, 1), (12, 2)]),
        ]
        let wholeRun = keys(of: mappings)
        let repeated = key("Sources/Sum.swift", line: 3, column: 5)

        for size in 1...6 {
            for seed: UInt64 in 0..<20 {
                let sample = Sample(size: size, seed: seed, seedIsChosen: false)
                let (kept, selection, leftOut) = mappings.keepingSample(sample, under: mutatedRoot)
                let sampled = keys(of: kept)
                XCTAssertTrue(Set(sampled).isSubset(of: Set(wholeRun)), "\(size), seed \(seed)")
                XCTAssertEqual(leftOut, Set(wholeRun).subtracting(sampled), "\(size), seed \(seed)")
                XCTAssertEqual(sampled, wholeRun.filter(Set(sampled).contains), "\(size), seed \(seed): job order")
                let second = key("Sources/Sum.swift", line: 3, column: 5, occurrence: 1)
                XCTAssertEqual(sampled.contains(repeated), sampled.contains(second), "\(size), seed \(seed)")
                // At least `size`, and one more only when the last place taken was the one with a repeat.
                XCTAssertTrue((size...size + 1).contains(sampled.count), "\(size), seed \(seed): \(sampled.count)")
                XCTAssertEqual(selection.mutantsSampled, sampled.count)
                XCTAssertEqual(selection.mutantsSampledFrom, 6)
                XCTAssertTrue(kept.allSatisfy { !$0.isEmpty })
            }
        }
    }

    func test_aSampleOfAtLeastEveryMutant_isTheWholeRun() throws {
        let mappings = try manyPlaces()
        let sample = Sample(size: 500, seed: 3, seedIsChosen: true)
        let (kept, selection, _) = mappings.keepingSample(sample, under: mutatedRoot)

        XCTAssertEqual(keys(of: kept), keys(of: mappings))
        XCTAssertEqual(selection, SampleSelection(size: 500, seed: 3, mutantsSampledFrom: 200, mutantsSampled: 200))
        XCTAssertFalse(selection.isPartial)
        XCTAssertNil(SampleScope(selection, killed: 150, scored: 200, tested: 200, cutShort: false))
    }

    // After a small change most of the sample stays: a trend line moves with the tests, not the sample.
    func test_aSmallChange_keepsMostOfTheSample() throws {
        let before = try manyPlaces()
        let after = try manyPlaces(skipping: Set(stride(from: 0, to: 200, by: 20)))
        let sample = Sample(size: 50, seed: 1234, seedIsChosen: false)

        let kept = Set(keys(of: before.keepingSample(sample, under: mutatedRoot).mappings))
        let keptAfter = Set(keys(of: after.keepingSample(sample, under: mutatedRoot).mappings))

        XCTAssertGreaterThanOrEqual(kept.intersection(keptAfter).count, 40)
    }

    // 500 of 2,497 mutants, 76% killed: the issue's own estimate, without Agresti–Coull's 2 and 2, was ±3.4 points.
    func test_theMargin_isTheIntervalsHalfWidth_narrowedForTheSampledPopulation() {
        XCTAssertEqual(
            SampleScope.marginOfError(killed: 380, scored: 500, sampled: 500, from: 2497),
            3.33,
            accuracy: 0.02
        )
        // A larger sample of the same population narrows it.
        XCTAssertLessThan(
            SampleScope.marginOfError(killed: 760, scored: 1000, sampled: 1000, from: 2497),
            SampleScope.marginOfError(killed: 380, scored: 500, sampled: 500, from: 2497)
        )
        // Every mutant tested: no sampling error.
        XCTAssertEqual(SampleScope.marginOfError(killed: 380, scored: 500, sampled: 500, from: 500), 0)
        // All killed, or none, still has a margin.
        XCTAssertGreaterThan(SampleScope.marginOfError(killed: 50, scored: 50, sampled: 50, from: 1000), 0)
        XCTAssertGreaterThan(SampleScope.marginOfError(killed: 0, scored: 50, sampled: 50, from: 1000), 0)
    }

    func test_aPartialSample_saysWhatItTested_andTheMargin() throws {
        let selection = SampleSelection(size: 500, seed: 1234, mutantsSampledFrom: 2497, mutantsSampled: 500)
        let scope = try XCTUnwrap(SampleScope(selection, killed: 380, scored: 500, tested: 500, cutShort: false))

        XCTAssertEqual(
            scope.sentence,
            "Only a sample of 500 of the 2497 mutants discovered was tested (seed 1234): a whole run's score is within "
                + "3.3 points of this one, at 95% confidence."
        )
        XCTAssertEqual(scope.mutantsTested, 500)
    }

    // A run stopped early has the first files' results, no random part of the sample: no margin.
    func test_aSampleWithoutEveryResult_givesNoMargin() throws {
        let selection = SampleSelection(size: 500, seed: 1234, mutantsSampledFrom: 2497, mutantsSampled: 500)
        let stopped = try XCTUnwrap(SampleScope(selection, killed: 76, scored: 100, tested: 100, cutShort: true))

        XCTAssertNil(stopped.marginOfError)
        XCTAssertNil(stopped.margin)
        XCTAssertEqual(
            stopped.sentence,
            "Only a sample of 500 of the 2497 mutants discovered was tested (seed 1234), and 100 of them have a "
                + "result, so no margin is given: the others have none yet, so these are the first ones tested, not a "
                + "random part of the sample."
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(stopped)) as? [String: Any]
        )
        XCTAssertNil(json["marginOfError"])
        XCTAssertEqual(json["mutantsTested"] as? Int, 100)
    }

    private func keys(of mappings: [SchemataMutationMapping]) -> [MutantKey] {
        MutantKey.keys(for: mappings.flatMap(\.mutationSchemata), under: mutatedRoot)
    }

    /// 200 places, one mutant each, in 10 files; `skipping` leaves out those places, by their number.
    private func manyPlaces(skipping: Set<Int> = []) throws -> [SchemataMutationMapping] {
        try (0..<10).map { file in
            let places = (0..<20).map { file * 20 + $0 }
                .filter { !skipping.contains($0) }
                .map { (line: $0 + 1, column: 1) }
            return try mapping("/project_mutated/Sources/File\(file).swift", places: places)
        }
    }

    private func key(
        _ path: String,
        line: Int,
        column: Int,
        mutationOperatorId: MutationOperator.Id = .ror,
        occurrence: Int = 0
    ) -> MutantKey {
        MutantKey(
            path: path,
            mutationOperatorId: mutationOperatorId,
            line: line,
            column: column,
            occurrence: occurrence
        )
    }

    /// A file's mapping with a `==` mutant at each of `places`, in their order, each in a code block of its own line.
    private func mapping(_ filePath: String, places: [(line: Int, column: Int)]) throws -> SchemataMutationMapping {
        var mapping = SchemataMutationMapping(filePath: filePath)
        for (index, place) in places.enumerated() {
            let block = try sourceCode("let value\(index) = a == b").statements
            try mapping.add(
                block,
                MutationSchema.make(
                    filePath: filePath,
                    syntaxMutation: "let value\(index) = a != b",
                    position: MutationPosition(utf8Offset: index * 100, line: place.line, column: place.column)
                )
            )
        }
        return mapping
    }
}
