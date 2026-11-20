import SwiftSyntax

/// Replaces a nil-coalescing term, `a ?? b`, with its fallback, `b`, so the code always takes the value on the right.
/// A test that never sees the left side nil, or never sees it not nil, can't tell the two apart. Each `??` of a chain
/// gets its own mutant: `a ?? b ?? c` becomes `b ?? c` and `a ?? c`. The term comes from the standard operators'
/// precedence (`NilCoalescing`), so a sequence the standard table can't fold gets none.
enum ReplaceNilCoalescingOperator {
    final class Visitor: MuterVisitor {
        /// Whether the file declares a `??` of its own, as an overload on a binding or a query type, which any `??` in
        /// it may be, and whose fallback needn't be what the overload gives. Worked out once, from the whole file.
        private var declaresACoalescingOperator = false
        private var hasLookedForACoalescingOperator = false

        convenience init(
            sourceCodeInfo: SourceCodeInfo,
            configuration: MuterConfiguration? = nil,
            coverage: FileCoverage = .empty
        ) {
            self.init(
                sourceCodeInfo: sourceCodeInfo,
                mutationOperatorId: .replaceNilCoalescing,
                coverage: coverage,
                configuration: configuration
            )
        }

        override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            // First, as this reads a `muter:disable` comment that comes before this operator.
            let next = super.visit(node)
            guard node.operator.text == "??",
                  !declaresACoalescingOperator(in: node.root),
                  let coalescing = NilCoalescing(withOperator: node)
            else {
                return next
            }

            add(
                mutation: coalescing.mutated(),
                with: coalescing.sequence,
                // Where the term starts, so each `??` of a chain has a place, and so a switch, of its own.
                at: startLocation(for: coalescing.first, afterLeadingTrivia: true),
                snapshot: MutationOperator.Snapshot(
                    before: coalescing.before,
                    after: coalescing.after,
                    description: "replaced the coalescing with its fallback"
                ),
                // Coverage goes by the operator, which ran whenever the term did, as a later link's ran whenever the
                // link before it fell back: the fallback's own region didn't run when the left side was never nil,
                // which is the survivor this operator is for. `--changed-lines` goes by the whole sequence.
                changing: node,
                spanning: coalescing.sequence
            )
            return next
        }

        private func declaresACoalescingOperator(in root: Syntax) -> Bool {
            if !hasLookedForACoalescingOperator {
                declaresACoalescingOperator = NilCoalescing.isDeclared(in: root)
                hasLookedForACoalescingOperator = true
            }
            return declaresACoalescingOperator
        }
    }
}
