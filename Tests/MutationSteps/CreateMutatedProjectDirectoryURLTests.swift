@testable import muterCore
import XCTest

final class CreateMutatedProjectDirectoryURLTests: MuterTestCase {
    private var state = MutationTestState()

    private let sut = CreateMutatedProjectDirectoryURL()

    func test_whenItsAbleToCreateATempDirectory() async throws {
        state.projectDirectoryURL = URL(string: "/tmp/some/projectName")!

        let result = try await sut.run(with: state)

        XCTAssertEqual(
            result,
            [.tempDirectoryUrlCreated(URL(fileURLWithPath: "/tmp/some/projectName_mutated.noindex"))]
        )
    }

    // A run of one mutant copies into a folder of its own, under a lock of its own, so it never removes a test plan's
    // copy, which may have been fixed by hand.
    func test_aRunOfOneMutant_namesACopyOfItsOwn() async throws {
        state.projectDirectoryURL = URL(fileURLWithPath: "/tmp/some/projectName")
        state.runOptions = .make(mutant: try MutantReference.parse("Bar.swift:12:9"))

        let result = try await sut.run(with: state)

        XCTAssertEqual(
            result,
            [.tempDirectoryUrlCreated(URL(fileURLWithPath: "/tmp/some/projectName_mutant.noindex"))]
        )
    }

    func test_mutateWithoutRunning_andAWholeRun_keepTheMutatedCopy() async throws {
        state.projectDirectoryURL = URL(fileURLWithPath: "/tmp/some/projectName")

        for options in [Run.Options.make(createTestPlan: true), .make()] {
            state.runOptions = options

            let result = try await sut.run(with: state)

            XCTAssertEqual(
                result,
                [.tempDirectoryUrlCreated(URL(fileURLWithPath: "/tmp/some/projectName_mutated.noindex"))]
            )
        }
    }
}
