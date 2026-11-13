import SwiftSyntax

extension ExecutionCounts {
    /// llvm-cov's count for code Swift counts directly.
    func directCount(of node: some SyntaxProtocol) -> Int? {
        let nodeSpan = span(of: node)
        directlyCounted.insert(nodeSpan)
        return reported[nodeSpan]
    }

    func walkFunctionBody(_ body: Syntax, entry: Int) {
        if let block = body.as(CodeBlockSyntax.self) {
            _ = walk(block.statements, from: entry)
        } else if let closure = body.as(ClosureExprSyntax.self) {
            _ = walk(closure.statements, from: entry)
        } else if let accessors = body.as(AccessorBlockSyntax.self),
                  case let .getter(statements) = accessors.accessors {
            _ = walk(statements, from: entry)
        } else {
            _ = walk(expression: body, from: entry)
        }
    }

    /// Walks the statements of a block that starts with `count`, and returns the count at its end.
    func walk(_ statements: CodeBlockItemListSyntax, from count: Int?) -> Int? {
        var count = count
        for item in statements {
            // A statement after a `return` starts a region of its own.
            if let count {
                expectedFrom[location(item.positionAfterSkippingLeadingTrivia)] = count
            }
            count = walk(statement: Syntax(item.item), from: count)
        }
        return count
    }

    func walk(statement: Syntax, from count: Int?) -> Int? {
        if let labeled = statement.as(LabeledStmtSyntax.self) {
            return walk(statement: Syntax(labeled.statement), from: count)
        }
        if let expression = statement.as(ExpressionStmtSyntax.self) {
            return walk(expression: Syntax(expression.expression), from: count)
        }
        if walkIfItLeaves(statement, from: count) {
            return 0
        }
        if let guardStatement = statement.as(GuardStmtSyntax.self) {
            return walk(guardStatement, from: count)
        }
        if let whileStatement = statement.as(WhileStmtSyntax.self) {
            // The condition runs once more than the body each time: its count is its own.
            let reached = walk(conditions: whileStatement.conditions, from: count, ofALoop: true)
            return walk(loopBody: whileStatement.body, of: statement, reached: reached)
        }
        if let forStatement = statement.as(ForStmtSyntax.self) {
            return walk(forStatement, from: count)
        }
        if let repeatStatement = statement.as(RepeatStmtSyntax.self) {
            return walk(repeatStatement, from: count)
        }
        if let doStatement = statement.as(DoStmtSyntax.self) {
            return walk(doStatement, from: count)
        }
        return walk(otherStatement: statement, from: count)
    }

    /// Walks `statement` if it leaves the code after it, as a `return`, `throw`, `break`, `continue` or `fallthrough`
    /// does, and says whether it was one.
    func walkIfItLeaves(_ statement: Syntax, from count: Int?) -> Bool {
        if let returnStatement = statement.as(ReturnStmtSyntax.self) {
            _ = returnStatement.expression.map { walk(expression: Syntax($0), from: count) }
            return true
        }
        if let throwStatement = statement.as(ThrowStmtSyntax.self) {
            _ = walk(expression: Syntax(throwStatement.expression), from: count)
            return true
        }
        if let breakStatement = statement.as(BreakStmtSyntax.self) {
            if let target = target(of: statement, label: breakStatement.label, loopsOnly: false) {
                addJump(to: target, count)
            }
            return true
        }
        if let continueStatement = statement.as(ContinueStmtSyntax.self) {
            if let target = target(of: statement, label: continueStatement.label, loopsOnly: true) {
                addJump(to: target, count)
                continues[target.id] = sum(continues[target.id] ?? 0, count)
            }
            return true
        }
        if statement.is(FallThroughStmtSyntax.self) {
            return true
        }
        return false
    }

    func walk(_ forStatement: ForStmtSyntax, from count: Int?) -> Int? {
        let reached = walk(expression: Syntax(forStatement.sequence), from: count)
        // Swift counts the code after a call in a `where` as the count before the loop less the times the call
        // threw, though the `where` runs for each element: it reads too low, down to 0 or less. It's the count
        // before the loop instead. That's too high when every element the `where` ran for before a throw was
        // the first, which the regions can't tell from one the `where` ran for and left out.
        if let whereClause = forStatement.whereClause, whereClause.condition.mayThrow, let reached {
            let whereSpan = span(of: whereClause)
            for index in regions(startingIn: whereSpan) where regions[index].span.end > whereSpan.end {
                expectedFrom[regions[index].span.start] = reached
            }
        }
        // `for try await` leaves when the sequence throws, and a `where` that throws leaves too, which no region
        // shows.
        let mayLeave = forStatement.tryKeyword != nil || forStatement.whereClause?.condition.mayThrow == true
        return walk(
            loopBody: forStatement.body,
            of: Syntax(forStatement),
            reached: mayLeave && count != 0 ? nil : reached
        )
    }

    /// A statement that is none of the others: a `#if`, a declaration, a `defer` or an expression.
    func walk(otherStatement statement: Syntax, from count: Int?) -> Int? {
        if let ifConfig = statement.as(IfConfigDeclSyntax.self) {
            guard let clause = keptClause(of: ifConfig), let elements = clause.elements else {
                return count
            }
            guard case let .statements(statements) = elements else {
                return nil
            }
            return walk(statements, from: count)
        }
        // A `defer`'s body runs at the end of the scope, and has no regions of its own.
        if statement.is(DeferStmtSyntax.self) || statement.is(FunctionDeclSyntax.self)
            || statement.asProtocol(DeclGroupSyntax.self) != nil {
            return count
        }
        return walk(expression: statement, from: count)
    }

    /// Walks the conditions of an `if`, `guard` or `while`, and returns the count after them. Swift counts the code in
    /// an `if`'s or `guard`'s conditions as the code before it, though a condition after the first runs only when the
    /// ones before it hold. A loop's run once more than its body each time, so the regions in them are left as they
    /// are, and the count after one that may throw is unknown.
    func walk(conditions: ConditionElementListSyntax, from count: Int?, ofALoop: Bool = false) -> Int? {
        guard !ofALoop else {
            for condition in conditions {
                _ = walk(expression: Syntax(condition.condition), from: nil)
            }
            return conditions.mayThrow && count != 0 ? nil : count
        }
        var after = count
        for condition in conditions {
            after = walk(expression: Syntax(condition.condition), from: after)
        }
        return after
    }

    func walk(_ ifExpression: IfExprSyntax, from count: Int?) -> Int? {
        let isElseIf = ifExpression.parent?.is(IfExprSyntax.self) == true
        if case let .expression(condition) = ifExpression.conditions.first?.condition {
            // An `else if`'s condition runs only when the conditions before it don't hold.
            if !isElseIf {
                runWithTheCodeBefore.insert(span(of: condition))
            }
            if let count {
                expectedOver[span(of: condition)] = count
            }
        }
        // An `else if` is in a region Swift doesn't record, so the count before a call in its conditions, and the
        // times the call threw, aren't in llvm-cov's counts.
        let throwsAreUnread = isElseIf && ifExpression.conditions.mayThrow && count != 0
        let reached = walk(conditions: ifExpression.conditions, from: throwsAreUnread ? nil : count)

        let thenCount = directCount(of: ifExpression.body)
        let thenEnd = walk(ifExpression.body.statements, from: thenCount)

        var elseLeftEarly: Int? = 0
        if let elseBody = ifExpression.elseBody {
            var elseCount: Int?
            if let reached, let thenCount {
                elseCount = reached - thenCount
            }
            switch elseBody {
            case let .codeBlock(block):
                if let elseCount {
                    expectedOver[span(of: block)] = elseCount
                }
                elseLeftEarly = difference(elseCount, walk(block.statements, from: elseCount))

            case let .ifExpr(elseIf):
                elseLeftEarly = difference(elseCount, walk(elseIf, from: elseCount))
            }
        }

        guard let reached,
              let thenLeftEarly = difference(thenCount, thenEnd),
              let elseLeftEarly,
              let jumpedTo = jumps(to: ifExpression)
        else {
            return nil
        }
        let after = reached + jumpedTo - thenLeftEarly - elseLeftEarly
        // An `else if` ends where its `if` does, which owns the region there.
        if !isElseIf {
            expectedFrom[location(ifExpression.endPositionBeforeTrailingTrivia)] = after
        }
        return after
    }

    func walk(_ guardStatement: GuardStmtSyntax, from count: Int?) -> Int? {
        let reached = walk(conditions: guardStatement.conditions, from: count)
        let bodyCount = directCount(of: guardStatement.body)
        let bodyEnd = walk(guardStatement.body.statements, from: bodyCount)
        guard let reached, let leftEarly = difference(bodyCount, bodyEnd) else {
            return nil
        }
        let after = reached - leftEarly
        expectedFrom[location(guardStatement.body.endPositionBeforeTrailingTrivia)] = after
        return after
    }

    /// A `while` or `for` loop: the count after it is the count before, plus the jumps to it, less the times its body
    /// was left other than at its end.
    func walk(loopBody body: CodeBlockSyntax, of loop: Syntax, reached: Int?) -> Int? {
        let bodyCount = directCount(of: body)
        let bodyEnd = walk(body.statements, from: bodyCount)
        guard let reached, let leftEarly = difference(bodyCount, bodyEnd), let jumpedTo = jumps(to: loop) else {
            return nil
        }
        let after = reached + jumpedTo - leftEarly
        expectedFrom[location(body.endPositionBeforeTrailingTrivia)] = after
        return after
    }

    /// Swift doesn't count a `break` or `continue` to a `repeat` loop as reaching the code after it, which then reads
    /// too low, down to 0 or less. It's counted here.
    func walk(_ repeatStatement: RepeatStmtSyntax, from count: Int?) -> Int? {
        let bodyCount = directCount(of: repeatStatement.body)
        let bodyEnd = walk(repeatStatement.body.statements, from: bodyCount)
        // Its condition runs each time the body reaches its end or a `continue` to it. Swift counts it from the body,
        // less the `break`s to it and the `return`s in it, but not the calls in it that threw, nor the `break`s and
        // `continue`s to an outer statement, so it reads too high when one did.
        let condition = span(of: repeatStatement.condition)
        runApart.append((condition, location(repeatStatement.body.endPositionBeforeTrailingTrivia)))
        let conditionCount = sum(bodyEnd, continues[repeatStatement.id] ?? 0)
        if let conditionCount {
            expectedOver[condition] = conditionCount
        } else if !repeatStatement.body.mayThrow {
            countedApart.insert(condition)
        }
        // The region after a call in it that may throw holds the code after the loop too, which runs only when the
        // condition fails, so the regions in such a condition are left as they are.
        let mayThrow = repeatStatement.condition.mayThrow
        _ = walk(expression: Syntax(repeatStatement.condition), from: mayThrow ? nil : conditionCount)
        guard let count, let leftEarly = difference(bodyCount, bodyEnd),
              let jumpedTo = jumps(to: repeatStatement)
        else {
            return nil
        }
        let after = count - leftEarly + jumpedTo
        expectedFrom[location(repeatStatement.body.endPositionBeforeTrailingTrivia)] = after
        return after != 0 && mayThrow ? nil : after
    }

    func walk(_ switchExpression: SwitchExprSyntax, from count: Int?) -> Int? {
        runWithTheCodeBefore.insert(span(of: switchExpression.subject))
        if let count {
            expectedOver[span(of: switchExpression.subject)] = count
        }
        _ = walk(expression: Syntax(switchExpression.subject), from: count)

        // The count after a `switch` is the count at the end of each `case`, plus the `break`s out of them. What its
        // subject threw is in the region after the call there, which holds the cases.
        let after = sum(walk(cases: switchExpression.cases), jumps(to: switchExpression))
        if let after {
            expectedFrom[location(switchExpression.endPositionBeforeTrailingTrivia)] = after
        }
        return after
    }

    /// The counts at the ends of `cases`, added up, including those in the `#if` clause the build kept.
    func walk(cases: SwitchCaseListSyntax) -> Int? {
        var total: Int? = 0
        for element in cases {
            switch element {
            case let .switchCase(switchCase):
                total = sum(total, walk(switchCase))

            case let .ifConfigDecl(ifConfig):
                guard let clause = keptClause(of: ifConfig), let elements = clause.elements else {
                    continue
                }
                guard case let .switchCases(nested) = elements else {
                    total = nil
                    continue
                }
                total = sum(total, walk(cases: nested))
            }
        }
        return total
    }

    /// Swift counts the code after a call in a `case` pattern or `where` as the case's count less the times the call
    /// threw, though a throw comes before the case is entered: it reads too low, down to 0 or less. It's the case's
    /// count, the times its body ran.
    func walk(_ switchCase: SwitchCaseSyntax) -> Int? {
        let caseCount = directCount(of: switchCase)
        if case let .case(label) = switchCase.label {
            runApart.append((span(of: label), location(switchCase.positionAfterSkippingLeadingTrivia)))
        }
        if case let .case(label) = switchCase.label, label.caseItems.mayThrow, let caseCount {
            let caseEnd = span(of: switchCase).end
            for index in regions(startingIn: span(of: label)) where regions[index].span.end >= caseEnd {
                expectedFrom[regions[index].span.start] = caseCount
            }
        }
        let end = walk(switchCase.statements, from: caseCount)
        // A call that ends a case starts no region after it, which would be empty, so what it threw can't be read.
        if let last = switchCase.statements.last, last.mayThrow, caseCount != 0 {
            return nil
        }
        return end
    }

    func walk(_ doStatement: DoStmtSyntax, from count: Int?) -> Int? {
        runWithTheCodeBefore.insert(span(of: doStatement.body))
        if let count {
            expectedOver[span(of: doStatement.body)] = count
        }
        // Swift allows no `try` in a `catch` pattern that could throw out of it.
        var after = walk(doStatement.body.statements, from: count)
        for catchClause in doStatement.catchClauses {
            after = sum(after, walk(catchClause.body.statements, from: directCount(of: catchClause.body)))
        }
        after = sum(after, jumps(to: doStatement))
        if let after {
            expectedFrom[location(doStatement.endPositionBeforeTrailingTrivia)] = after
        }
        return after
    }

    /// The clause the build kept: llvm-cov marks the whole of each other one as skipped, and only the directive of
    /// this one. `nil` when the build kept none.
    func keptClause(of ifConfig: IfConfigDeclSyntax) -> IfConfigClauseSyntax? {
        ifConfig.clauses.first { clause in
            let clauseSpan = span(of: clause)
            return !skipped.contains { $0.contains(clauseSpan) }
        }
    }
}
