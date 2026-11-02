@testable import muterCore
import XCTest

final class ShardTests: XCTestCase {
    private let mutatedRoot = URL(fileURLWithPath: "/project_mutated")

    func test_parses_kOfN() {
        XCTAssertEqual(Shard("1/2"), Shard(index: 1, count: 2))
        XCTAssertEqual(Shard("2/2"), Shard(index: 2, count: 2))
        XCTAssertEqual(Shard("1/1"), Shard(index: 1, count: 1))
        XCTAssertEqual(Shard("07/10"), Shard(index: 7, count: 10))
        XCTAssertEqual(Shard("1000/1000"), Shard(index: 1000, count: 1000))
        XCTAssertEqual(Shard("3/4")?.description, "3/4")
    }

    func test_refuses_anythingButTwoWholeNumbers_withKFrom1ToN() {
        let refused = [
            "", "2", "/2", "1/", "0/2", "3/2", "1/0", "-1/2", "+1/2", "1/2/3", " 1/2", "1 / 2", "1.0/2", "½/2", "١/٢",
            "1/99999999999999999999", "1/1001",
        ]
        for text in refused {
            XCTAssertNil(Shard(text), text)
        }
    }

    // A change to how a mutant's shard is worked out splits two SwiftMutator builds' shards differently, which
    // `report` refuses to merge only because their builds differ: these pin it.
    func test_aPlacesShard_isFixed() {
        XCTAssertEqual(
            [2, 3, 4, 7].map { Shard.index(ofPlace: key("Sources/Sum.swift", line: 3, column: 4), among: $0) },
            [1, 3, 3, 6]
        )
        XCTAssertEqual(
            [2, 3, 4, 7].map { Shard.index(ofPlace: key("Sources/Sum.swift", line: 3, column: 5), among: $0) },
            [1, 2, 1, 4]
        )
        XCTAssertEqual(
            [2, 3, 4, 7].map {
                Shard.index(
                    ofPlace: key("Sources/Other.swift", line: 10, column: 1, mutationOperatorId: .removeSideEffects),
                    among: $0
                )
            },
            [1, 3, 1, 4]
        )
    }

    // A number's remainders by two counts are any pair whose difference their greatest common divisor divides.
    func test_shardsOverlap_unlessTheirRemaindersCantMeet() {
        func shard(_ text: String) -> Shard? { Shard(text) }
        let pairs: [(String, String, Bool)] = [
            ("1/2", "1/2", true), ("1/2", "2/2", false), ("2/2", "1/4", false), ("2/2", "2/4", true),
            ("2/2", "1/3", true), ("3/4", "2/6", false), ("3/4", "3/6", true), ("1/1", "5/7", true),
        ]
        for (first, second, overlap) in pairs {
            let one = shard(first)
            let other = shard(second)
            XCTAssertEqual(one.flatMap { first in other.map(first.overlaps) }, overlap, "\(first) and \(second)")
            XCTAssertEqual(other.flatMap { second in one.map(second.overlaps) }, overlap, "\(second) and \(first)")
        }
        // Checked against the shards of many places.
        let keys = (1...600).map {
            MutantKey(path: "F\($0 % 9).swift", mutationOperatorId: .ror, line: $0, column: 1, occurrence: 0)
        }
        for one in [Shard(index: 2, count: 2), Shard(index: 3, count: 4), Shard(index: 1, count: 3)] {
            for other in [Shard(index: 1, count: 4), Shard(index: 2, count: 6), Shard(index: 1, count: 6)] {
                let shared = keys.contains { one.holds($0) && other.holds($0) }
                XCTAssertEqual(shared, one.overlaps(other), "\(one), \(other)")
            }
        }
    }

    func test_aPlacesRepeats_areInOneShard() {
        for count in 1...7 {
            let first = Shard.index(ofPlace: key("Sources/Sum.swift", line: 3, column: 5), among: count)
            let repeated = Shard.index(
                ofPlace: key("Sources/Sum.swift", line: 3, column: 5, occurrence: 1),
                among: count
            )
            XCTAssertEqual(first, repeated)
        }
    }

    func test_everyPlace_isInExactlyOneShard_andTheyAreRoughlyEven() {
        let keys = (1...400).map { key("Sources/File\($0 % 7).swift", line: $0, column: $0 % 13) }
        let shards = (1...4).map { Shard(index: $0, count: 4) }

        for key in keys {
            XCTAssertEqual(shards.filter { $0.holds(key) }.count, 1, "\(key)")
        }
        for shard in shards {
            XCTAssertEqual(Double(keys.filter(shard.holds).count), 100, accuracy: 30, "shard \(shard)")
        }
    }

    func test_keepingOnly_keepsTheShardsMutants_withTheWholeRunsKeys() throws {
        let mappings = try [
            mapping("/project_mutated/Sources/Sum.swift", places: [(3, 4), (3, 5), (3, 5), (9, 1)]),
            mapping("/project_mutated/Sources/Other.swift", places: [(10, 1), (12, 2)]),
        ]
        let wholeRun = MutantKey.keys(for: mappings.flatMap(\.mutationSchemata), under: mutatedRoot)

        for count in 1...4 {
            var tested: [MutantKey] = []
            for shard in (1...count).map({ Shard(index: $0, count: count) }) {
                let kept = mappings.keepingOnly(shard, under: mutatedRoot).mappings
                let keys = MutantKey.keys(for: kept.flatMap(\.mutationSchemata), under: mutatedRoot)
                XCTAssertEqual(keys, wholeRun.filter(shard.holds), "shard \(shard)")
                XCTAssertTrue(kept.allSatisfy { !$0.isEmpty })
                tested += keys
            }
            XCTAssertEqual(Set(tested), Set(wholeRun), "\(count) shards")
            XCTAssertEqual(tested.count, wholeRun.count, "\(count) shards")
            // The repeat at 3:5 is in a shard with its first occurrence, and keeps its number.
            XCTAssertTrue(tested.contains(key("Sources/Sum.swift", line: 3, column: 5, occurrence: 1)))
        }
    }

    func test_keepingOnly_recordsEveryShardsMutants() throws {
        let mappings = try [
            mapping("/project_mutated/Sources/Sum.swift", places: [(3, 4), (3, 5), (3, 5), (9, 1)]),
            mapping("/project_mutated/Sources/Other.swift", places: [(10, 1), (12, 2)]),
        ]

        let first = mappings.keepingOnly(Shard(index: 1, count: 2), under: mutatedRoot).selection
        let second = mappings.keepingOnly(Shard(index: 2, count: 2), under: mutatedRoot).selection
        let reordered = Array(mappings.reversed()).keepingOnly(Shard(index: 1, count: 2), under: mutatedRoot).selection
        let fewer = Array(mappings.prefix(1)).keepingOnly(Shard(index: 1, count: 2), under: mutatedRoot).selection

        XCTAssertEqual(first.index, 1)
        XCTAssertEqual(second.index, 2)
        XCTAssertEqual([first.count, second.count], [2, 2])
        XCTAssertEqual([first.mutantsInAllShards, second.mutantsInAllShards], [6, 6])
        XCTAssertEqual(first.allKeysSHA256, second.allKeysSHA256)
        XCTAssertEqual(first.allKeysSHA256, reordered.allKeysSHA256)
        XCTAssertNotEqual(first.allKeysSHA256, fewer.allKeysSHA256)
        XCTAssertEqual(fewer.mutantsInAllShards, 4)
        // Sum.swift 3:4, both repeats at 3:5, and Other.swift 10:1 and 12:2 are in shard 1; Sum.swift 9:1 in shard 2.
        XCTAssertEqual(first.mutantsPerShard, [5, 1])
        XCTAssertEqual(second.mutantsPerShard, [5, 1])
    }

    func test_aKeysLine_separatesItsFields() {
        XCTAssertEqual(
            ShardSelection.keyLine(key("Sources/Sum.swift", line: 3, column: 5, occurrence: 1)),
            "Sources/Sum.swift\0RelationalOperatorReplacement\03\05\01\0\n"
        )
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
