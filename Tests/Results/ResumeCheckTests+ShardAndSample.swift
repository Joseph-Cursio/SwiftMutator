@testable import muterCore
import XCTest

extension ResumeCheckTests {
    // MARK: - --shard

    func test_theSameShard_resumes() {
        let shard = Shard(index: 1, count: 2)

        XCTAssertEqual(check(current(shard: shard), recorded: header(of: current(shard: shard))), ResumeCheck.Verdict())
    }

    func test_anotherShard_orAShardGivenOnOneSideOnly_refuses() {
        let first = Shard(index: 1, count: 2)

        let difference = ResumeCheck.Difference(name: "shard", was: #""1/2""#, isNow: #""2/2""#)
        XCTAssertEqual(
            check(current(shard: Shard(index: 2, count: 2)), recorded: header(of: current(shard: first))).refusals,
            [.selectionChanged(difference)]
        )
        XCTAssertEqual(
            "\(ResumeRefusal.selectionChanged(difference))",
            #"shard was "1/2" and is "2/2" now. A change to which mutants are tested needs a new run."#
        )
        XCTAssertEqual(
            check(current(shard: Shard(index: 1, count: 3)), recorded: header(of: current(shard: first))).refusals,
            [.selectionChanged(.init(name: "shard", was: #""1/2""#, isNow: #""1/3""#))]
        )
        XCTAssertEqual(
            check(current(), recorded: header(of: current(shard: first))).refusals,
            [.selectionChanged(.init(name: "shard", was: #""1/2""#, isNow: nil))]
        )
        XCTAssertEqual(
            check(current(shard: first)).refusals,
            [.selectionChanged(.init(name: "shard", was: nil, isNow: #""1/2""#))]
        )
    }

    // Shards differ in their shard by definition, and in nothing else a resume compares.
    func test_aMerge_comparesWhatAResumeDoes_butTheShard() {
        let first = header(of: current(shard: Shard(index: 1, count: 2)))
        let moved = ChangeSelection.make(mergeBase: "fee1000000000000000000000000000000000000")

        XCTAssertEqual(check(current(shard: Shard(index: 2, count: 2)), recorded: first, for: .merge).refusals, [])
        XCTAssertEqual(
            check(current(operators: ["SwapTernary"], since: moved), recorded: first, for: .merge).refusals.count,
            2
        )
        XCTAssertEqual(ResumeCheck.Current(header: first), current(shard: Shard(index: 1, count: 2)))
    }

    // A reuse keeps a result only for a mutant this shard holds, which holds whatever else is tested.
    func test_aReuse_doesntCompareTheShard_eitherWay() {
        let first = Shard(index: 1, count: 2)

        XCTAssertEqual(check(current(shard: first), for: .reuse).refusals, [])
        XCTAssertEqual(check(current(), recorded: header(of: current(shard: first)), for: .reuse).refusals, [])
        XCTAssertEqual(
            check(
                current(shard: Shard(index: 2, count: 3)),
                recorded: header(of: current(shard: first)),
                for: .reuse
            ).refusals,
            []
        )
    }

    // MARK: - --sample

    func test_theSameSample_resumes_whetherOrNotSwiftMutatorChoseItsSeed() {
        let sample = Sample(size: 500, seed: 1_234, seedIsChosen: true)
        let given = Sample(size: 500, seed: 1_234, seedIsChosen: false)

        XCTAssertEqual(
            check(current(sample: given), recorded: header(of: current(sample: sample))),
            ResumeCheck.Verdict()
        )
    }

    func test_anotherSizeOrSeed_orASampleOnOneSideOnly_refuses() {
        let recorded = header(of: current(sample: Sample(size: 500, seed: 1_234, seedIsChosen: false)))

        let difference = ResumeCheck.Difference(name: "sample", was: #""500, seed 1234""#, isNow: #""500, seed 99""#)
        XCTAssertEqual(
            check(current(sample: Sample(size: 500, seed: 99, seedIsChosen: true)), recorded: recorded).refusals,
            [.selectionChanged(difference)]
        )
        XCTAssertEqual(
            "\(ResumeRefusal.selectionChanged(difference))",
            #"sample was "500, seed 1234" and is "500, seed 99" now. "#
                + "A change to which mutants are tested needs a new run."
        )
        XCTAssertEqual(
            check(current(sample: Sample(size: 600, seed: 1_234, seedIsChosen: false)), recorded: recorded).refusals,
            [.selectionChanged(.init(name: "sample", was: #""500, seed 1234""#, isNow: #""600, seed 1234""#))]
        )
        XCTAssertEqual(
            check(current(), recorded: recorded).refusals,
            [.selectionChanged(.init(name: "sample", was: #""500, seed 1234""#, isNow: nil))]
        )
        XCTAssertEqual(
            check(current(sample: Sample(size: 500, seed: 1_234, seedIsChosen: false))).refusals,
            [.selectionChanged(.init(name: "sample", was: nil, isNow: #""500, seed 1234""#))]
        )
    }

    // The shards of a sampled split share its sample: shards of different samples aren't one split.
    func test_aMerge_comparesTheSample() {
        let sample = Sample(size: 500, seed: 1_234, seedIsChosen: false)
        let first = header(of: current(shard: Shard(index: 1, count: 2), sample: sample))

        XCTAssertEqual(
            check(current(shard: Shard(index: 2, count: 2), sample: sample), recorded: first, for: .merge).refusals,
            []
        )
        XCTAssertEqual(
            check(
                current(shard: Shard(index: 2, count: 2), sample: Sample(size: 500, seed: 7, seedIsChosen: false)),
                recorded: first,
                for: .merge
            ).refusals,
            [.selectionChanged(.init(name: "sample", was: #""500, seed 1234""#, isNow: #""500, seed 7""#))]
        )
        XCTAssertEqual(ResumeCheck.Current(header: first), current(shard: Shard(index: 1, count: 2), sample: sample))
    }

    // A reuse keeps a result only for a mutant this sample holds, which holds whatever else is tested.
    func test_aReuse_doesntCompareTheSample_eitherWay() {
        let sample = Sample(size: 500, seed: 1_234, seedIsChosen: false)

        XCTAssertEqual(check(current(sample: sample), for: .reuse).refusals, [])
        XCTAssertEqual(check(current(), recorded: header(of: current(sample: sample)), for: .reuse).refusals, [])
        XCTAssertEqual(
            check(
                current(sample: Sample(size: 40, seed: 9, seedIsChosen: true)),
                recorded: header(of: current(sample: sample)),
                for: .reuse
            ).refusals,
            []
        )
    }
}
