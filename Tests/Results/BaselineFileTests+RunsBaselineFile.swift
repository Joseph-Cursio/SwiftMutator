@testable import muterCore
import XCTest

extension BaselineFileTests {
    // The score's counts, as `ScoreGate` takes them, and every mutant the tests didn't kill.
    func test_aRunsBaselineFile_holdsItsSurvivors_andItsScoresCounts() {
        let outcome = MutationTestOutcome(mutations: [
            .make(testSuiteOutcome: .passed, key: key("A.swift", 1)),
            .make(testSuiteOutcome: .timeout, key: key("A.swift", 2)),
            .make(testSuiteOutcome: .noCoverage, key: key("A.swift", 3)),
            .make(testSuiteOutcome: .failed, key: key("A.swift", 4)),
            .make(testSuiteOutcome: .buildError, key: key("A.swift", 5)),
        ])

        let made = BaselineFile(of: outcome, scope: scope, version: "9.9", path: "b.yml") { _ in nil }

        XCTAssertEqual(made.survivors.map(\.outcome), [.survived, .timedOut, .notCovered])
        XCTAssertEqual(made.survivors.map(\.mutant.line), [1, 2, 3])
        XCTAssertEqual(made.score, .init(killed: 1, scored: 4))
        XCTAssertEqual(made.swiftMutator, "9.9")
        XCTAssertEqual(made.path, "b.yml")
    }

    // Only a whole run's results make one, and a run that leaves some mutants out says why.
    func test_resultsThatLeaveMutantsOut_makeNoBaselineFile() {
        var whole = MutationTestOutcome(mutations: [.make(testSuiteOutcome: .passed, key: key("A.swift", 1))])
        whole.baselineScope = scope
        let target = "\(directory)/b.yml"

        XCTAssertEqual(
            BaselineFileSaving.save(whole, to: target, version: "0.1.0", using: FileManager.default),
            .saved(path: target)
        )

        var since = whole
        since = MutationTestOutcome(mutations: whole.mutations, since: .make())
        since.baselineScope = scope
        var files = whole
        files.filesToMutate = ["Sources/A.swift"]
        let cases: [(MutationTestOutcome, String)] = [
            (MutationTestOutcome(mutations: whole.mutations, mutant: "A.swift:1:9 SwapTernary"), "(--mutant)"),
            (
                MutationTestOutcome(
                    mutations: whole.mutations,
                    shards: ShardScope(indices: [1], count: 2, mutantsInAllShards: 4)
                ),
                "the results are only shard 1 of 2's"
            ),
            (since, "the code --since chose"),
            (files, "--files-to-mutate"),
            (MutationTestOutcome(mutations: whole.mutations, sampleIsCutShort: true), "didn't test every mutant"),
        ]
        for (outcome, words) in cases {
            let saving = BaselineFileSaving.save(outcome, to: target, version: "0.1.0", using: FileManager.default)
            guard case let .leftOut(_, reason) = saving else {
                XCTFail("\(saving)")
                return
            }
            XCTAssertTrue(reason.contains(words), reason)
            XCTAssertTrue(saving.plainLine.hasSuffix("and a baseline file holds a whole run's survivors."))
        }
        let stopped = BaselineFileSaving.save(
            whole, to: target, version: "0.1.0", unless: "the run didn't finish", using: FileManager.default
        )
        XCTAssertEqual(
            stopped.plainLine,
            "No baseline file was saved to \(target): the run didn't finish, and a baseline file holds a whole run's "
                + "survivors."
        )
    }

    // Compile recovery takes every mutant out of the build and the run finishes, but it tested none: its file would
    // record no survivor, and every survivor of a later run would be new.
    func test_aRunWhoseEveryMutantWasABuildError_makesNoBaselineFile() {
        var outcome = MutationTestOutcome(mutations: [
            .make(testSuiteOutcome: .buildError, key: key("A.swift", 1)),
            .make(testSuiteOutcome: .buildError, key: key("A.swift", 2)),
        ])
        outcome.baselineScope = scope
        let target = "\(directory)/b.yml"

        let saving = BaselineFileSaving.save(outcome, to: target, version: "0.1.0", using: FileManager.default)

        XCTAssertEqual(
            saving,
            .leftOut(path: target, because: "every mutant was a build error, so none was tested")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))

        let killed = MutationTestOutcome.Mutation.make(testSuiteOutcome: .failed, key: key("A.swift", 3))
        outcome = MutationTestOutcome(mutations: outcome.mutations + [killed])
        outcome.baselineScope = scope
        XCTAssertEqual(
            BaselineFileSaving.save(outcome, to: target, version: "0.1.0", using: FileManager.default),
            .saved(path: target)
        )
    }
}
