import Foundation

struct MutationTestLog {
    let mutationPoint: MutationPoint?
    let testLog: String
    let timePerBuildTestCycle: TimeInterval?
    let remainingMutationPointsCount: Int?
}

extension MutationTestLog {
    /// The name of the file the run's log folder keeps the log of `mutationPoint`'s run in, or the baseline's.
    static func keptFileName(for mutationPoint: MutationPoint?) -> String {
        guard let mutationPoint else {
            return "baseline run.log"
        }

        return "\(mutationPoint.mutationOperatorId.rawValue) @ \(mutationPoint.fileName)-\(mutationPoint.position.line)-\(mutationPoint.position.column).log"
    }
}
