@testable import muterCore
import TestingExtensions
import XCTest

extension LoadResumeStateTests {
    // Against the longest limit of every session, not only the last's: a result of a session with a longer one may
    // need it.
    func test_aLongerTimeLimit_goesAhead_onlyIfNoSessionHadALongerOne() async throws {
        let timed = { (seconds: Double) in
            MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: seconds)
        }
        try await writeResults(
            ResultsHeader.make(project: projectTree(), timeoutSeconds: 120),
            ResultsEnd.make(reason: .interrupted),
            ResultsHeader.make(session: 2, project: projectTree(), timeoutSeconds: 96.5),
            ResultsEnd.make()
        )
        resume(resultsPath)
        state.muterConfiguration = timed(100)

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.configurationChanged(.init(name: "mutationTestTimeout", was: nil, isNow: "100"))],
                beforeTheCopy: true
            )
        )

        state.muterConfiguration = timed(120)
        let changes = try await sut.run(with: state)
        state.apply(changes)

        XCTAssertEqual(
            try XCTUnwrap(state.resumeState).notices,
            [
                "mutationTestTimeout was not set and is 120 now, no shorter than any session's limit: the timeouts "
                    + "under a shorter one are tested again.",
            ]
        )
    }

    // A result that --reuse kept was tested under the earlier run's limit, which the file doesn't record.
    func test_aLongerTimeLimit_isRefused_forAFileThatHoldsAReusedResult() async throws {
        let tree = await projectTree()
        let reused = MutantResult.make(
            path: "Sources/Sum.swift",
            fileSHA256: tree.files["Sources/Sum.swift"],
            reusedFrom: ReusedFrom(resultsFile: "/earlier/results.jsonl", session: 1, despiteChanges: false)
        )
        try writeResults(ResultsHeader.make(project: tree, timeoutSeconds: 20), reused, ResultsEnd.make())
        resume(resultsPath)
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            testSuiteTimeOut: 120
        )

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.timeLimitUnknown(.init(name: "mutationTestTimeout", was: nil, isNow: "120"))],
                beforeTheCopy: true
            )
        )
    }
}
