import SwiftSyntax

/// How many times the tests ran each part of a file: llvm-cov's regions, with the counts Swift gets wrong worked out
/// again.
///
/// Swift counts some code directly: a function's or closure's body, the right-hand side of `&&`, an `if`'s
/// then-block, a `guard`'s `else`, a loop's body, a `case`, a `catch`, a ternary's first branch, and the times a call
/// threw. Every other region's count is an expression over those. The count after an `if`, for one, is the count before
/// it, less each branch's count, plus the count at each branch's end, which a `return` makes 0. In a result builder
/// Swift reads the count at a branch's end from an earlier block, so the code after an `if` that was never true can get
/// a count of 0 though it ran, the regions after it inherit that, and an `else` after it can get a count though it
/// never ran.
///
/// So the expressions are worked out again here, by walking the syntax as Swift's coverage does (`SILProfiler.cpp`),
/// with the direct counts from llvm-cov's regions. Elsewhere that gives llvm-cov's own counts, with four deliberate
/// exceptions where Swift's are wrong in any code: after a `repeat` loop left by `break` or `continue`, in a `repeat`
/// loop's condition when its body threw or jumped to an outer statement, after a call in a `case` pattern that threw,
/// and after a call in a `for` loop's `where`. A count that depends on something the walk doesn't follow keeps
/// llvm-cov's.
final class ExecutionCounts {
    struct Point: Hashable, Comparable {
        let line: Int
        let column: Int

        static func < (lhs: Point, rhs: Point) -> Bool {
            (lhs.line, lhs.column) < (rhs.line, rhs.column)
        }
    }

    private struct Span: Hashable {
        let start: Point
        let end: Point

        init(start: Point, end: Point) {
            self.start = start
            self.end = end
        }

        init(_ region: Region) {
            start = Point(line: region.lineStart, column: region.columnStart)
            end = Point(line: region.lineEnd, column: region.columnEnd)
        }

        /// llvm-cov's regions end before their end column.
        func contains(_ other: Span) -> Bool {
            start <= other.start && other.end <= end
        }
    }

    private struct CountedRegion {
        let span: Span
        var count: Int
        /// llvm-cov's count.
        let reportedCount: Int
        /// A function's whole body: never worked out again.
        let isFixed: Bool
        /// Whether it has a closure literal's span and holds the closure, made in it: a region of the function that
        /// makes the closure, or the body of an implicit closure that does.
        let makesAClosure: Bool
        /// The innermost earlier region that holds this one.
        var parent: Int?
        /// The bodies of the closures it starts in, in their capture lists, as after a call there: it holds code of
        /// the function that makes each closure, if any, but not the closure's code.
        var crossedBodies: [Int] = []
        /// For a closure's body, where its capture list ends: the capture list runs where the closure is made, so the
        /// body's region holds only the code after it.
        var captureEnd: Point?
        /// For a closure's body, the regions that start in its capture list and end after it, which hold code after it.
        var crossings: [Int] = []
        /// Whether it holds code that Swift counts directly and that ran, which it ran to reach: code of its own
        /// function, or of a closure made in it.
        var holdsCodeThatRan = false
        /// Code in it that runs apart from the rest of it and holds such code that ran, as a `case`'s label, which
        /// ran though the case's body may not have.
        var codeThatRanApart: [Span] = []
        /// Whether llvm-cov's counts that the walk can't work out say nothing in it: it, or a region that holds it, of
        /// its own function or of the one that makes it, reads 0 or is worked out as 0, as code that never ran does,
        /// or a builder's stale count. Code that Swift counts directly ran by its own count, but a builder's counts
        /// after it are as stale.
        var countsInItSayNothing = false
        /// Whether the walk worked its count out.
        var wasWorkedOut = false
        var ran = true

        init(span: Span, count: Int, isFixed: Bool, makesAClosure: Bool = false) {
            self.span = span
            self.count = count
            reportedCount = count
            self.isFixed = isFixed
            self.makesAClosure = makesAClosure
        }
    }

    private let location: (AbsolutePosition) -> Point
    /// Sorted by start, and by end from the last, so a region's parent comes before it.
    private var regions: [CountedRegion] = []
    /// llvm-cov's count for each region inside a function, which the walk reads for the code Swift counts directly.
    private var reported: [Span: Int] = [:]
    /// The code of the `#if` clauses the build left out, and the directives of the one it kept.
    private var skipped: [Span] = []

    /// What the walk works out, for the regions over a whole node and the regions that start at a point.
    private var expectedOver: [Span: Int] = [:]
    private var expectedFrom: [Point: Int] = [:]
    /// The times `break` and `continue` jumped to each statement, `nil` once one of them is unknown, and the times
    /// `continue` did.
    private var jumps: [SyntaxIdentifier: Int?] = [:]
    private var continues: [SyntaxIdentifier: Int?] = [:]
    /// The nodes whose code functions of their own count, and the one being walked.
    private var functionBodies: Set<SyntaxIdentifier> = []
    private var walking: SyntaxIdentifier?
    /// The functions' bodies that run only once the code around them has: closures, written or implicit.
    private var madeWhereWritten: Set<Span> = []
    /// The closure literals that are the whole body of a function that makes them, which runs their capture lists.
    private var madeElsewhere: Set<Span> = []
    /// Code that runs apart from the code around it, and where the regions that hold both start: a `case`'s pattern
    /// and `where`, tried for each value, which its region holds with its body, and a `repeat` loop's condition, which
    /// the region after its body holds with the code after the loop.
    private var runApart: [(code: Span, holdersStart: Point)] = []
    /// The other regions whose counts Swift keeps directly, which a builder doesn't get wrong.
    private var directlyCounted: Set<Span> = []
    /// The regions that run each time the code before them does: an `if`'s condition, a `switch`'s subject, a `do`.
    private var runWithTheCodeBefore: Set<Span> = []
    /// The regions that Swift counts apart from the code around them, though not directly: a `repeat` loop's
    /// condition, from the loop's body, when the walk can't work it out and nothing in the body throws.
    private var countedApart: Set<Span> = []
    /// How many ternaries the walk is in the second branch of, each a call deeper, up to a depth well within a
    /// discovery thread's stack.
    private var ternaryDepth = 0
    private static let deepestTernary = 50
    /// How many expressions the walk is in, each a call deeper, up to a depth well within a discovery thread's stack.
    /// Code deeper than that keeps llvm-cov's counts.
    private var expressionDepth = 0
    private static let deepestExpression = 200

    init(
        coverage: FileCoverage,
        source: SourceFileSyntax,
        location: @escaping (AbsolutePosition) -> Point
    ) {
        self.location = location

        var bodyRecords: [Span: [(count: Int, starts: [Point])]] = [:]
        for function in coverage.functions {
            var code: [Region] = []
            for region in function {
                if region.kind == .skipped {
                    skipped.append(Span(region))
                } else {
                    code.append(region)
                }
            }
            guard let body = code.first else {
                continue
            }
            bodyRecords[Span(body), default: []].append((body.executionCount, code.dropFirst().map { Span($0).start }))
            for region in code.dropFirst() {
                let span = Span(region)
                reported[span] = max(reported[span] ?? 0, region.executionCount)
            }
        }

        let bodies = FunctionBodyFinder.bodies(in: source, spans: Set(bodyRecords.keys), span: span(of:))
        let closureBodies = Set(bodies.filter { $0.node.is(ClosureExprSyntax.self) }.map(\.span))
        // A closure, written or implicit, runs only once the code that makes it has.
        madeWhereWritten = Set(bodies.filter { Self.isMadeWhereItIsWritten($0.node) }.map(\.span))
        var captureEnds: [Span: Point] = [:]
        for body in bodies {
            if let capture = body.node.as(ClosureExprSyntax.self)?.signature?.capture {
                captureEnds[body.span] = location(capture.endPositionBeforeTrailingTrivia)
            }
        }
        // Other records that share a span, such as a property wrapper's backing initializer and its init accessor, are
        // two functions with the same code, which ran if either ran it.
        var bodyCounts: [Span: Int] = [:]
        var all: [CountedRegion] = []
        for (span, records) in bodyRecords {
            guard closureBodies.contains(span) else {
                bodyCounts[span] = records.map(\.count).max() ?? 0
                continue
            }
            // A closure literal can be the whole of a region of the function that makes it, such as a ternary's
            // branch, or the whole body of a function that makes it, as `??`'s right-hand side or a property's
            // initializer is. That region holds the closure's capture list, and the closure's own region the code in
            // its body. A struct's memberwise init can leave its property's initializer at 0, though it made the
            // closure, which then ran if it was called.
            let counts = Self.closureCounts(records, captureEnd: captureEnds[span])
            bodyCounts[span] = counts.called
            if let count = reported[span] {
                all.append(CountedRegion(span: span, count: count, isFixed: false, makesAClosure: true))
            } else if let made = counts.made {
                let count = max(made, counts.called)
                all.append(CountedRegion(span: span, count: count, isFixed: true, makesAClosure: true))
                madeElsewhere.insert(span)
            }
        }

        all += reported.compactMap { span, count in
            bodyCounts[span] == nil ? CountedRegion(span: span, count: count, isFixed: false) : nil
        }
        all += bodyCounts.map { CountedRegion(span: $0.key, count: $0.value, isFixed: true) }
        regions = all.sorted { lhs, rhs in
            lhs.span == rhs.span
                ? lhs.makesAClosure && !rhs.makesAClosure
                : (lhs.span.start, rhs.span.end) < (rhs.span.start, lhs.span.end)
        }
        for index in regions.indices where regions[index].isFixed && !regions[index].makesAClosure {
            guard let captureEnd = captureEnds[regions[index].span] else {
                continue
            }
            regions[index].captureEnd = captureEnd
            var inCaptureList = index + 1
            while inCaptureList < regions.count, regions[inCaptureList].span.start < captureEnd {
                regions[inCaptureList].crossedBodies.append(index)
                if regions[inCaptureList].span.end > regions[index].span.end {
                    regions[index].crossings.append(inCaptureList)
                }
                inCaptureList += 1
            }
        }
        for index in regions.indices {
            let span = regions[index].span
            var candidate = index > 0 ? index - 1 : nil
            while let current = candidate, !holds(span, current) {
                candidate = next(after: current, lookingFor: span)
            }
            regions[index].parent = candidate
        }

        functionBodies = Set(bodies.map(\.node.id))
        for body in bodies {
            walking = body.node.id
            walkFunctionBody(body.node, entry: bodyCounts[body.span] ?? 0)
        }
        walking = nil

        for index in regions.indices
        where isDirectlyCounted(regions[index]) && (1...Int.max / 2).contains(regions[index].count) {
            let apart = runApart.filter { $0.code.contains(regions[index].span) }
            var ancestor = regions[index].parent
            while let current = ancestor, !regions[current].holdsCodeThatRan {
                let span = regions[current].span
                if let code = apart.first(where: { $0.holdersStart <= span.start && span.start <= $0.code.end
                    && span.end > $0.code.end
                })?.code {
                    regions[current].codeThatRanApart.append(code)
                } else {
                    regions[current].holdsCodeThatRan = true
                }
                // A function's body, or a local type's, can run though the code that declares it never did.
                guard !regions[current].isFixed || madeWhereWritten.contains(regions[current].span) else {
                    break
                }
                ancestor = regions[current].parent
            }
        }
        for index in regions.indices {
            let span = regions[index].span
            if !regions[index].isFixed, let count = expectedOver[span] ?? expectedFrom[span.start] {
                regions[index].count = count
                regions[index].wasWorkedOut = true
            }
            let region = regions[index]
            let parentsCountsSayNothing = region.parent.map { regions[$0].countsInItSayNothing } ?? false
            if region.isFixed {
                regions[index].countsInItSayNothing = region.count == 0
                    || madeWhereWritten.contains(span) && parentsCountsSayNothing
            } else if directlyCounted.contains(span) || countedApart.contains(span) {
                regions[index].countsInItSayNothing = region.count == 0 || parentsCountsSayNothing
            } else {
                regions[index].countsInItSayNothing = region.reportedCount == 0
                    || region.wasWorkedOut && region.count == 0 || parentsCountsSayNothing
            }
        }
        // A count shown as the largest one, a negative one, counts as run: tests that run at once can lose updates to
        // the count it's worked out from. Below a 0, as llvm-cov reads for code that never ran, but also for the code
        // after a builder's `if` that was never true, a count the walk couldn't work out says nothing: it can be worked
        // out from a stale count, too low or too high. Such code ran only if code in it that Swift counts directly did,
        // or, for the code that runs each time the code before it does, if that code ran.
        for index in regions.indices {
            let region = regions[index]
            let isOwnCount = region.isFixed || region.wasWorkedOut || directlyCounted.contains(region.span)
                || countedApart.contains(region.span)
            let saysNothing = !isOwnCount && isInRegionWhoseCountsSayNothing(index)
            if region.holdsCodeThatRan || !saysNothing && (1...Int.max / 2).contains(region.count) {
                regions[index].ran = true
            } else if saysNothing, runWithTheCodeBefore.contains(region.span), let parent = region.parent {
                regions[index].ran = regions[parent].ran
            } else {
                regions[index].ran = region.count != 0 && !isInRegionWhoseCountsSayNothing(index)
            }
        }
    }

    private func isInRegionWhoseCountsSayNothing(_ index: Int) -> Bool {
        guard !regions[index].isFixed, let parent = regions[index].parent else {
            return false
        }
        return regions[parent].countsInItSayNothing
    }

    private func isDirectlyCounted(_ region: CountedRegion) -> Bool {
        region.isFixed ? madeWhereWritten.contains(region.span) : directlyCounted.contains(region.span)
    }

    /// Whether a function's body runs only once the code around it has: a closure, or the expression of an implicit
    /// closure or of a local variable's initial value, but not a named function's body, nor one in a type's property's
    /// value or a parameter's default, which are made when the type or the call is.
    private static func isMadeWhereItIsWritten(_ body: Syntax) -> Bool {
        guard body.is(ExprSyntax.self) else {
            return false
        }
        var ancestor = body.parent
        while let current = ancestor {
            // An enum case's parameters are in a member too.
            if current.is(MemberBlockItemSyntax.self) || current.is(FunctionParameterSyntax.self) {
                return false
            }
            if current.is(CodeBlockItemSyntax.self) || current.is(ClosureExprSyntax.self) {
                return true
            }
            ancestor = current.parent
        }
        return false
    }

    /// Records that share a closure literal's span: the closure's own, whose count is the times it was called, and
    /// the initializer, getter or implicit closure that makes it, whose count is the times it was made. The regions of
    /// the code that makes it are in its capture list, which ends at `captureEnd`, and the closure's own in its body.
    /// The closure's is the one with regions in its body, or else, of those with none, the smaller: 0 when it was
    /// never called.
    private static func closureCounts(
        _ records: [(count: Int, starts: [Point])],
        captureEnd: Point?
    ) -> (called: Int, made: Int?) {
        let inBody = records.indices.filter { index in
            records[index].starts.contains { start in captureEnd.map { start >= $0 } ?? true }
        }
        let withNone = records.indices.filter { records[$0].starts.isEmpty }
        let closure = inBody.isEmpty
            ? (withNone.isEmpty ? Array(records.indices) : withNone).min { records[$0].count < records[$1].count }
            : inBody.max { records[$0].count < records[$1].count }
        guard let closure else {
            return (0, nil)
        }
        return (records[closure].count, records.indices.filter { $0 != closure }.map { records[$0].count }.max())
    }

    /// Each region once, with its count worked out again where it follows from others, in order of start.
    var countedRegions: [Region] {
        regions.map {
            Region(
                lineStart: $0.span.start.line,
                columnStart: $0.span.start.column,
                lineEnd: $0.span.end.line,
                columnEnd: $0.span.end.column,
                executionCount: $0.count
            )
        }
    }

    /// Whether the tests ran `node`: the innermost region that holds all of it has a count, or holds code of its own
    /// function that Swift counts directly and that ran, or does in the code apart from the rest of it that holds the
    /// node, as does code in no region, outside every function. A node in
    /// a `#if` clause the build left out never ran. One the build kept starts on a skipped directive, and a `switch`'s
    /// cases start where the first one's region does, so the region at a node's start isn't enough.
    func ran(_ node: some SyntaxProtocol) -> Bool {
        let nodeSpan = span(of: node)
        if skipped.contains(where: { $0.contains(nodeSpan) }) {
            return false
        }
        return innermostRegion(holding: nodeSpan).map { index in
            regions[index].ran || regions[index].codeThatRanApart.contains { $0.contains(nodeSpan) }
        } ?? true
    }

    /// Whether the code in each of `countedRegions` ran, in its order.
    var regionsRan: [Bool] {
        regions.map(\.ran)
    }

    /// The last region that starts at or before `span` holds it, or one of its parents does: any region that holds
    /// `span` holds that one too, but for a closure's capture list and the regions that start there.
    private func innermostRegion(holding span: Span) -> Int? {
        var index = lastRegion(startingAtOrBefore: span.start)
        while let current = index, !holds(span, current) {
            index = next(after: current, lookingFor: span)
        }
        return index
    }

    private func holds(_ span: Span, _ index: Int) -> Bool {
        if let captureEnd = regions[index].captureEnd, span.start < captureEnd {
            return false
        }
        return regions[index].span.contains(span) && !crossesTheBody(holding: span, index)
    }

    /// The region to look at after `index` for one that holds `span`: its parent, but past a region that starts in a
    /// closure's capture list when `span` is in the closure's body, the one before it, in the closure, and past a
    /// closure, the last region that starts in its capture list and holds `span`, after the closure.
    private func next(after index: Int, lookingFor span: Span) -> Int? {
        if crossesTheBody(holding: span, index) {
            return index - 1
        }
        return regions[index].crossings.last { regions[$0].span != span && holds(span, $0) } ?? regions[index].parent
    }

    private func crossesTheBody(holding span: Span, _ index: Int) -> Bool {
        regions[index].crossedBodies.contains { holds(span, $0) }
    }

    private func lastRegion(startingAtOrBefore point: Point) -> Int? {
        var low = 0
        var high = regions.count
        while low < high {
            let middle = (low + high) / 2
            if regions[middle].span.start <= point {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }

    private func span(of node: some SyntaxProtocol) -> Span {
        Span(
            start: location(node.positionAfterSkippingLeadingTrivia),
            end: location(node.endPositionBeforeTrailingTrivia)
        )
    }

    // MARK: - The walk

    /// llvm-cov's count for code Swift counts directly.
    private func directCount(of node: some SyntaxProtocol) -> Int? {
        let nodeSpan = span(of: node)
        directlyCounted.insert(nodeSpan)
        return reported[nodeSpan]
    }

    private func walkFunctionBody(_ body: Syntax, entry: Int) {
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
    private func walk(_ statements: CodeBlockItemListSyntax, from count: Int?) -> Int? {
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

    private func walk(statement: Syntax, from count: Int?) -> Int? {
        if let labeled = statement.as(LabeledStmtSyntax.self) {
            return walk(statement: Syntax(labeled.statement), from: count)
        }
        if let expression = statement.as(ExpressionStmtSyntax.self) {
            return walk(expression: Syntax(expression.expression), from: count)
        }
        if let returnStatement = statement.as(ReturnStmtSyntax.self) {
            _ = returnStatement.expression.map { walk(expression: Syntax($0), from: count) }
            return 0
        }
        if let throwStatement = statement.as(ThrowStmtSyntax.self) {
            _ = walk(expression: Syntax(throwStatement.expression), from: count)
            return 0
        }
        if let breakStatement = statement.as(BreakStmtSyntax.self) {
            if let target = target(of: statement, label: breakStatement.label, loopsOnly: false) {
                addJump(to: target, count)
            }
            return 0
        }
        if let continueStatement = statement.as(ContinueStmtSyntax.self) {
            if let target = target(of: statement, label: continueStatement.label, loopsOnly: true) {
                addJump(to: target, count)
                continues[target.id] = sum(continues[target.id] ?? 0, count)
            }
            return 0
        }
        if statement.is(FallThroughStmtSyntax.self) {
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
            return walk(loopBody: forStatement.body, of: statement, reached: mayLeave && count != 0 ? nil : reached)
        }
        if let repeatStatement = statement.as(RepeatStmtSyntax.self) {
            return walk(repeatStatement, from: count)
        }
        if let doStatement = statement.as(DoStmtSyntax.self) {
            return walk(doStatement, from: count)
        }
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

    /// Walks the expressions in `node` in order, and returns the count after them.
    private func walk(expression node: Syntax, from count: Int?) -> Int? {
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
    private func walk(_ tryExpression: TryExprSyntax, from count: Int?, before rest: [ExprSyntax] = []) -> Int? {
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
                if let parent = region.parent, regions[parent].count <= Int.max / 2, region.count <= Int.max / 2 {
                    after = difference(after, regions[parent].count - region.count)
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
    private func regions(startingIn span: Span) -> [Int] {
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
    private func walk(sequence terms: [ExprSyntax], from count: Int?) -> Int? {
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
                index += 1 + elseTerms.count
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

    /// Walks the conditions of an `if`, `guard` or `while`, and returns the count after them. Swift counts the code in
    /// an `if`'s or `guard`'s conditions as the code before it, though a condition after the first runs only when the
    /// ones before it hold. A loop's run once more than its body each time, so the regions in them are left as they
    /// are, and the count after one that may throw is unknown.
    private func walk(conditions: ConditionElementListSyntax, from count: Int?, ofALoop: Bool = false) -> Int? {
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

    private func walk(_ ifExpression: IfExprSyntax, from count: Int?) -> Int? {
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

    private func walk(_ guardStatement: GuardStmtSyntax, from count: Int?) -> Int? {
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
    private func walk(loopBody body: CodeBlockSyntax, of loop: Syntax, reached: Int?) -> Int? {
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
    private func walk(_ repeatStatement: RepeatStmtSyntax, from count: Int?) -> Int? {
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

    private func walk(_ switchExpression: SwitchExprSyntax, from count: Int?) -> Int? {
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
    private func walk(cases: SwitchCaseListSyntax) -> Int? {
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
    private func walk(_ switchCase: SwitchCaseSyntax) -> Int? {
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

    private func walk(_ doStatement: DoStmtSyntax, from count: Int?) -> Int? {
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
    private func keptClause(of ifConfig: IfConfigDeclSyntax) -> IfConfigClauseSyntax? {
        ifConfig.clauses.first { clause in
            let clauseSpan = span(of: clause)
            return !skipped.contains { $0.contains(clauseSpan) }
        }
    }

    // MARK: - Jumps

    /// The statement a `break` or `continue` goes to: the one with its label, or else the innermost loop, or
    /// `switch` for a `break`.
    private func target(of jump: Syntax, label: TokenSyntax?, loopsOnly: Bool) -> Syntax? {
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

    private func addJump(to target: Syntax, _ count: Int?) {
        let previous = jumps[target.id] ?? 0
        jumps[target.id] = sum(previous, count)
    }

    /// `nil` when a jump to `statement` had an unknown count.
    private func jumps(to statement: some SyntaxProtocol) -> Int? {
        jumps[Syntax(statement).id] ?? 0
    }

    private func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else {
            return nil
        }
        return lhs + rhs
    }

    private func difference(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else {
            return nil
        }
        return lhs - rhs
    }

    /// The node whose code each function's first region counts, in order of start: a function's body, a closure, a
    /// getter's statements, or the expression of a property's initial value or of an implicit closure.
    private final class FunctionBodyFinder: SyntaxAnyVisitor {
        private let spans: Set<Span>
        private let span: (Syntax) -> Span
        private var found: [Span: Syntax] = [:]

        static func bodies(
            in source: SourceFileSyntax,
            spans: Set<Span>,
            span: @escaping (Syntax) -> Span
        ) -> [(span: Span, node: Syntax)] {
            let finder = FunctionBodyFinder(spans: spans, span: span)
            finder.walk(source)
            return finder.found
                .map { (span: $0.key, node: $0.value) }
                .sorted { ($0.span.start, $1.span.end) < ($1.span.start, $0.span.end) }
        }

        private init(spans: Set<Span>, span: @escaping (Syntax) -> Span) {
            self.spans = spans
            self.span = span
            super.init(viewMode: .sourceAccurate)
        }

        override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
            guard node.is(CodeBlockSyntax.self) || node.is(ClosureExprSyntax.self)
                || node.is(AccessorBlockSyntax.self) || node.is(ExprSyntax.self)
            else {
                return .visitChildren
            }
            let nodeSpan = span(node)
            if spans.contains(nodeSpan), found[nodeSpan] == nil {
                found[nodeSpan] = node
            }
            return .visitChildren
        }
    }
}

private extension SyntaxProtocol {
    /// Whether a call in it may throw, as Swift's coverage counts it: one in a `try` without `?`, outside the closures
    /// it holds but for their capture lists. One in a `try!` that threw would stop the tests, but Swift counts the
    /// times it threw all the same.
    var mayThrow: Bool {
        tokens(viewMode: .sourceAccurate).contains { token in
            guard token.tokenKind == .keyword(.try),
                  token.parent?.as(TryExprSyntax.self)?.questionOrExclamationMark?.text != "?"
            else {
                return false
            }
            // A closure's capture list runs where the closure is made.
            var ancestor = token.parent
            var isInACaptureList = false
            while let current = ancestor, current.id != Syntax(self).id {
                if current.is(ClosureCaptureClauseSyntax.self) {
                    isInACaptureList = true
                } else if current.is(ClosureExprSyntax.self) {
                    guard isInACaptureList else {
                        return false
                    }
                    isInACaptureList = false
                }
                ancestor = current.parent
            }
            return true
        }
    }
}

private extension [ExprSyntax] {
    var mayThrow: Bool {
        contains { $0.mayThrow }
    }
}

private extension ExprSyntax {
    /// `=`, or a standard operator such as `+=` that binds as loosely.
    var isAssignment: Bool {
        if self.is(AssignmentExprSyntax.self) {
            return true
        }
        guard let text = self.as(BinaryOperatorExprSyntax.self)?.operator.text else {
            return false
        }
        return Self.compoundAssignments.contains(text)
    }

    /// An operator that a project declared, which may bind more loosely than a ternary, or take a closure.
    var isDeclaredOperator: Bool {
        guard let text = self.as(BinaryOperatorExprSyntax.self)?.operator.text else {
            return false
        }
        return !Self.standardOperators.contains(text)
    }

    private static let compoundAssignments: Set<String> = [
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "&+=", "&-=", "&*=", "&<<=", "&>>=", ".&=", ".|=",
        ".^=",
    ]

    private static let standardOperators: Set<String> = [
        "==", "!=", "<=", ">=", "===", "!==", ".==", ".!=", ".<=", ".>=", "<", ">", ".<", ".>", "~=", "+", "-", "*",
        "/", "%", "&", "|", "^", "<<", ">>", "&+", "&-", "&*", "&<<", "&>>", ".&", ".|", ".^", "..<", "...", "??",
        "&&", "||",
    ]
}
