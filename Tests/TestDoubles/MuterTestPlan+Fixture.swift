import Foundation
@testable import muterCore

extension MuterTestPlan {
    static func make(
        mutatedProjectPath: String = "/path/to/project_mutated",
        projectCoverage: Int = 0,
        scope: TestPlanScope? = TestPlanScope(operators: .allOperators, filesToMutate: []),
        sources: ProjectTree? = nil,
        mutatedFiles: [String: String]? = nil,
        linkedFiles: [String: String]? = nil,
        mappings: [SchemataMutationMapping] = [],
        mutantsNotCovered: [UncoveredMutant]? = nil
    ) -> MuterTestPlan {
        MuterTestPlan(
            mutatedProjectURL: URL(fileURLWithPath: mutatedProjectPath),
            projectCoverage: projectCoverage < 0 ? .null : Coverage(percent: projectCoverage),
            scope: scope,
            sources: sources,
            mutatedFiles: mutatedFiles,
            linkedFiles: linkedFiles,
            mappings: mappings,
            mutantsNotCovered: mutantsNotCovered
        )
    }

    /// The plan as `CreateMuterTestPlan` writes it into `projectRoot`, in `TestPlanCoding.formatVersion`.
    func toData(under projectRoot: URL) -> Data {
        Data(((try? TestPlanCoding.encode(self, under: projectRoot)) ?? "").utf8)
    }

    /// The plan as a SwiftMutator from before format versions wrote it, in format 0: on one line, with absolute paths,
    /// and a coverage of -1 when it wasn't gathered.
    var legacyData: Data {
        let file = LegacyTestPlanFile(
            mutatedProjectPath: mutatedProjectURL.path,
            projectCoverage: projectCoverage.percent,
            mappings: mappings
        )
        return (try? JSONEncoder().encode(file)) ?? Data()
    }
}

extension MutationTestLog {
    static func make(
        mutationPoint: MutationPoint? = nil,
        testLog: String = "",
        timePerBuildTestCycle: TimeInterval? = nil,
        remainingMutationPointsCount: Int? = nil,
        workers: Int = 1,
        testRunSeconds: TimeInterval? = nil,
        keptFileName: String = MutationTestLog.baselineFileName
    ) -> MutationTestLog {
        MutationTestLog(
            mutationPoint: mutationPoint,
            testLog: testLog,
            timePerBuildTestCycle: timePerBuildTestCycle,
            remainingMutationPointsCount: remainingMutationPointsCount,
            workers: workers,
            testRunSeconds: testRunSeconds,
            keptFileName: keptFileName
        )
    }
}
