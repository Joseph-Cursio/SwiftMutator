import Foundation

extension DroppedMutant {
    init(_ schema: MutationSchema, path: String, reason: Reason) {
        self.init(
            path: path,
            mutationOperatorId: schema.mutationOperatorId,
            position: schema.position,
            snapshot: schema.snapshot,
            lines: schema.lines,
            reason: reason
        )
    }
}
