@testable import muterCore
import TestingExtensions
import XCTest

extension LoadResumeStateTests {
    // A plan run's last session recorded the copy as it tested it, rewritten and perhaps fixed by hand, which differs
    // from the project. FingerprintProjectTree compares the copy once it is locked, and CheckTestPlanSources has
    // checked the project against the plan, so nothing here lists or hashes the project.
    func test_aTestPlanRun_doesNotCompareTheProjectWithTheRecordedCopy() async throws {
        let copy = state.mutatedProjectDirectoryURL.path
        try write(["README.md": "readme", "Sources/Sum.swift": "func sum() { if __SWIFTMUTATOR_ACTIVE {} }"], in: copy)
        let copyTree = await ProjectTree.fingerprint(
            listingIn: URL(fileURLWithPath: copy),
            hashingIn: URL(fileURLWithPath: copy),
            excluding: []
        ) { _ in nil }
        let projectTree = await projectTree()
        XCTAssertNotEqual(copyTree.files, projectTree.files, "the copy differs from the project")
        try writeResults(
            ResultsHeader.make(project: copyTree, usingTestPlan: true, testPlan: planRecord(sha256: "91a")),
            ResultsEnd.make()
        )
        resumePlan(sha256: "91a")

        let changes = try await sut.run(with: state)

        guard case .resumeStateLoaded? = changes.first, changes.count == 1 else {
            XCTFail("Expected the resume to be loaded, got \(changes)")
            return
        }
        XCTAssertEqual(listed.value, [], "the project was listed")
    }

    // `run` can't resume a run of a plan, whose header records the plan's copy, rewritten: that alone refuses it. The
    // project isn't compared with the copy, which would name every rewritten file as changed, with --resume-ignoring
    // flags that can't let the run through.
    func test_aRunWithoutAPlan_resumingATestPlanRun_isRefusedForThatAlone() async throws {
        let copy = state.mutatedProjectDirectoryURL.path
        try write(["README.md": "readme", "Sources/Sum.swift": "func sum() { if __SWIFTMUTATOR_ACTIVE {} }"], in: copy)
        let copyTree = await ProjectTree.fingerprint(
            listingIn: URL(fileURLWithPath: copy),
            hashingIn: URL(fileURLWithPath: copy),
            excluding: []
        ) { _ in nil }
        try writeResults(
            ResultsHeader.make(project: copyTree, usingTestPlan: true, testPlan: planRecord(sha256: "91a")),
            ResultsEnd.make()
        )

        await assertRefused(
            ResumeRefused(path: resultsPath, reasons: [.testPlanRun(recordedUsedOne: true)], beforeTheCopy: true)
        )
        XCTAssertEqual(listed.value, [], "the project was listed")
    }

    func test_aTestPlanRun_withAnotherPlan_isRefusedBeforeTheCopy() async throws {
        try await writeResults(
            ResultsHeader.make(project: projectTree(), usingTestPlan: true, testPlan: planRecord(sha256: "91a")),
            ResultsEnd.make()
        )
        resumePlan(sha256: "b07")

        await assertRefused(
            ResumeRefused(
                path: resultsPath,
                reasons: [.testPlanChanged(.init(name: "testPlan.sha256", was: #""91a""#, isNow: #""b07""#))],
                beforeTheCopy: true
            )
        )
    }
}
