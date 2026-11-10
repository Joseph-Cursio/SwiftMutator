import Foundation

extension TestPlanRecord {
    init(_ plan: LoadedTestPlan) {
        self.init(
            path: plan.path,
            sha256: plan.sha256,
            formatVersion: plan.formatVersion,
            swiftMutatorVersion: plan.swiftMutatorVersion
        )
    }
}
