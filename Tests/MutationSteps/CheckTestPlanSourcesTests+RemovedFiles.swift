import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

extension CheckTestPlanSourcesTests {
    // A file the plan mutates that was renamed in the project is a change of the project, which `--plan-ignoring` can
    // let through, though the folder holds none of the files the plan mutates: the plan's other files in `Sources`
    // tell its project.
    func test_theOneFileItMutates_renamedInTheProject_isRefusedAsRemoved() async throws {
        let now = recorded.merging(["Sources/Total.swift": "let sum = 1"]) { $1 }
            .filter { $0.key != "Sources/Sum.swift" }
        try write(now, in: project)
        plan(mutating: ["Sources/Sum.swift"])

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? TestPlanRefused,
                TestPlanRefused(
                    path: self.planPath,
                    reason: .sourcesChanged([.init(path: "Sources/Sum.swift", kind: .removed)])
                )
            )
        }

        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: planPath), planIgnoring: ["Sources/Sum.swift"])
        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes, [])
        XCTAssertEqual(said.value.map(\.name), [.testPlanSourcesDiffer, .testPlanChangesWaived])
        XCTAssertEqual(said.value.last?.object as? [String], ["Sources/Sum.swift"])
    }

    // `--mutant` narrows the run to the one file, which was removed, while the plan's other file is still there.
    func test_theFileOfTheMutantToBeTested_removedInTheProject_isRefusedAsRemoved() async throws {
        try write(recorded.filter { $0.key != "Sources/Max.swift" }, in: project)
        plan(mutating: ["Sources/Sum.swift", "Sources/Max.swift"], recorded: recorded, tested: ["Sources/Max.swift"])

        await AssertThrowsError(try await sut.run(with: state)) { error in
            XCTAssertEqual(
                error as? TestPlanRefused,
                TestPlanRefused(
                    path: self.planPath,
                    reason: .sourcesChanged([.init(path: "Sources/Max.swift", kind: .removed)])
                )
            )
        }
    }
}
