import SwiftSyntax

extension ExecutionCounts {
    /// Walks the expressions in `node` in order, and returns the count after them.
    func walk(expression node: Syntax, from count: Int?) -> Int? {
        // A closure's capture list runs where the closure is made, as code of the function that makes it, unless that's
        // a function of its own whose whole body the closure is, which llvm-cov's counts are left for.
        if let capture = node.as(ClosureExprSyntax.self)?.signature?.capture, !madeElsewhere.contains(span(of: node)) {
            return walk(expression: Syntax(capture), from: count)
        }
        if node.is(ClosureExprSyntax.self) || node.is(FunctionDeclSyntax.self) || node.is(AccessorBlockSyntax.self)
            || node.asProtocol(DeclGroupSyntax.self) != nil
            || node.id != walking && functionBodies.contains(node.id) {
            return count
        }
        guard expressionDepth < Self.deepestExpression else {
            return nil
        }
        expressionDepth += 1
        defer {
            expressionDepth -= 1
        }
        if let ifExpression = node.as(IfExprSyntax.self) {
            return walk(ifExpression, from: count)
        }
        if let switchExpression = node.as(SwitchExprSyntax.self) {
            return walk(switchExpression, from: count)
        }
        if let tryExpression = node.as(TryExprSyntax.self) {
            return walk(tryExpression, from: count)
        }
        if let terms = node.as(ExprListSyntax.self) {
            return walk(sequence: Array(terms), from: count)
        }
        var count = count
        for child in node.children(viewMode: .sourceAccurate) {
            count = walk(expression: child, from: count)
        }
        return count
    }

    /// After each call in a `try` that can throw, Swift starts a region whose count is the one before, less the times
    /// the call threw. That difference is in llvm-cov's own counts, which a builder's wrong ones don't change, since
    /// both sides are wrong by the same amount. A count shown as the largest one, a negative one, loses it.
    ///
    /// A `try` that starts a sequence covers the terms after it, `rest`, as well.
    func walk(_ tryExpression: TryExprSyntax, from count: Int?, before rest: [ExprSyntax] = []) -> Int? {
        let start = location(tryExpression.positionAfterSkippingLeadingTrivia)
        let end = location(rest.last?.endPositionBeforeTrailingTrivia ?? tryExpression.endPositionBeforeTrailingTrivia)
        let inside = regions(startingIn: Span(start: start, end: end))
        // The code in it runs as often as the `try` when only its last call can throw, so that no region after a call
        // starts inside it. Otherwise the regions inside it keep llvm-cov's counts.
        let onlyItsLastCallThrows = inside.allSatisfy { regions[$0].span.start == end || regions[$0].span.end < end }
        let insideCount = onlyItsLastCallThrows || count == 0 ? count : nil
        _ = walk(expression: Syntax(tryExpression.expression), from: insideCount)
        _ = walk(sequence: rest, from: insideCount)
        // `try?` ends what the calls in it throw. A `try!` call that threw would stop the tests, but it starts a region
        // all the same.
        guard tryExpression.questionOrExclamationMark?.text != "?" else {
            return count
        }
        // One that never ran never threw.
        var after = count
        for index in inside where regions[index].span.end > end {
            let region = regions[index]
            if count != 0 {
                if let parent = region.parent,
                   regions[parent].executionCount <= Int.max / 2,
                   region.executionCount <= Int.max / 2 {
                    after = difference(after, regions[parent].executionCount - region.executionCount)
                } else {
                    after = nil
                }
            }
            if let after {
                expectedFrom[region.span.start] = after
            }
        }
        return after
    }

    /// The regions that start inside `span`, after its first character, other than functions' bodies, in order.
    func regions(startingIn span: Span) -> [Int] {
        var found: [Int] = []
        var index = lastRegion(startingAtOrBefore: span.start).map { $0 + 1 } ?? 0
        while index < regions.count, regions[index].span.start <= span.end {
            if !regions[index].isFixed {
                found.append(index)
            }
            index += 1
        }
        return found
    }

    /// An unfolded sequence of terms. The right-hand side of `&&`, `||` or `??` is a closure of its own, with a region
    /// of its own, and is left to its own walk, along with the terms after it up to the next ternary or assignment, a
    /// little more than it. So are those after an operator a project declared, which may take a closure too, or bind
    /// more loosely than a ternary. A ternary's condition is every term before it, and its second branch the terms
    /// after it, up to an assignment.
    func walk(sequence terms: [ExprSyntax], from count: Int?) -> Int? {
        var count = count
        var inShortCircuit = false
        // A ternary after an operator a project declared may be its right-hand side.
        var afterDeclaredOperator = false
        var index = terms.startIndex
        while index < terms.endIndex {
            let term = terms[index]
            if let tryExpression = term.as(TryExprSyntax.self), index + 1 < terms.endIndex {
                // Swift allows a `try` only first or after an assignment, and it covers the rest.
                return walk(tryExpression, from: count, before: Array(terms[(index + 1)...]))
            }
            if let ternary = term.as(UnresolvedTernaryExprSyntax.self) {
                (count, index) = walk(
                    ternary,
                    at: index,
                    in: terms,
                    from: count,
                    afterDeclaredOperator: afterDeclaredOperator
                )
                inShortCircuit = false
                continue
            }
            if term.isAssignment {
                inShortCircuit = false
                afterDeclaredOperator = false
            } else if let binaryOperator = term.as(BinaryOperatorExprSyntax.self),
                      ["&&", "||", "??"].contains(binaryOperator.operator.text) || term.isDeclaredOperator {
                inShortCircuit = true
                afterDeclaredOperator = afterDeclaredOperator || term.isDeclaredOperator
            } else if inShortCircuit {
                // A `try` in it throws through the operator.
                if term.mayThrow, count != 0 {
                    count = nil
                }
            } else {
                count = walk(expression: Syntax(term), from: count)
            }
            index += 1
        }
        return count
    }

    /// The ternary at `index` in `terms`, whose condition is every term before it, and whose second branch is the terms
    /// after it up to an assignment. Returns the count after it and the index of the term after its second branch.
    func walk(
        _ ternary: UnresolvedTernaryExprSyntax,
        at index: Int,
        in terms: [ExprSyntax],
        from count: Int?,
        afterDeclaredOperator: Bool
    ) -> (count: Int?, next: Int) {
        var count = count
        let reached = afterDeclaredOperator ? nil : count
        let thenCount = directCount(of: ternary.thenExpression)
        let thenEnd = walk(expression: Syntax(ternary.thenExpression), from: thenCount)

        let elseTerms = Array(terms[(index + 1)...].prefix { !$0.isAssignment })
        var elseCount: Int?
        if let reached, let thenCount {
            elseCount = reached - thenCount
        }
        if let first = elseTerms.first, let last = elseTerms.last, let elseCount {
            expectedOver[Span(
                start: location(first.positionAfterSkippingLeadingTrivia),
                end: location(last.endPositionBeforeTrailingTrivia)
            )] = elseCount
        }
        // A long chain of ternaries is left as llvm-cov counts it, rather than walked a call deeper for each.
        var elseEnd: Int?
        if ternaryDepth < Self.deepestTernary {
            ternaryDepth += 1
            elseEnd = walk(sequence: elseTerms, from: elseCount)
            ternaryDepth -= 1
        }
        let next = index + 1 + elseTerms.count
        // Swift takes what each branch threw from the count after it, in a region that starts where the branch
        // ends. One the walk can't work out keeps llvm-cov's count, not the one the branch's walk left there.
        if reached != 0, ternary.thenExpression.mayThrow || elseTerms.mayThrow {
            let afterThen = difference(reached, difference(thenCount, thenEnd))
            count = difference(afterThen, difference(elseCount, elseEnd))
            if ternary.thenExpression.mayThrow {
                expectedFrom[location(ternary.thenExpression.endPositionBeforeTrailingTrivia)] = afterThen
            }
            if elseTerms.mayThrow, let last = elseTerms.last {
                expectedFrom[location(last.endPositionBeforeTrailingTrivia)] = count
            }
        } else if !afterDeclaredOperator {
            count = reached
        }
        return (count, next)
    }

    /// The statement a `break` or `continue` goes to: the one with its label, or else the innermost loop, or
    /// `switch` for a `break`.
    func target(of jump: Syntax, label: TokenSyntax?, loopsOnly: Bool) -> Syntax? {
        var ancestor = jump.parent
        while let current = ancestor {
            if current.is(ClosureExprSyntax.self) || current.is(FunctionDeclSyntax.self) {
                return nil
            }
            if let label {
                if let labeled = current.as(LabeledStmtSyntax.self), labeled.label.text == label.text {
                    // A labeled `if` or `switch` is an expression in a statement.
                    return labeled.statement.as(ExpressionStmtSyntax.self).map { Syntax($0.expression) }
                        ?? Syntax(labeled.statement)
                }
            } else if current.is(ForStmtSyntax.self) || current.is(WhileStmtSyntax.self)
                || current.is(RepeatStmtSyntax.self) || !loopsOnly && current.is(SwitchExprSyntax.self) {
                return current
            }
            ancestor = current.parent
        }
        return nil
    }

    func addJump(to target: Syntax, _ count: Int?) {
        let previous = jumps[target.id] ?? 0
        jumps[target.id] = sum(previous, count)
    }

    /// `nil` when a jump to `statement` had an unknown count.
    func jumps(to statement: some SyntaxProtocol) -> Int? {
        jumps[Syntax(statement).id] ?? 0
    }

    func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else {
            return nil
        }
        return lhs + rhs
    }

    func difference(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else {
            return nil
        }
        return lhs - rhs
    }
}
