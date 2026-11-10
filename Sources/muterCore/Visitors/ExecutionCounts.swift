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

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.line, lhs.column) < (rhs.line, rhs.column)
        }
    }

    let location: (AbsolutePosition) -> Point
    /// Sorted by start, and by end from the last, so a region's parent comes before it.
    private(set) var regions: [CountedRegion] = []
    /// llvm-cov's count for each region inside a function, which the walk reads for the code Swift counts directly.
    private(set) var reported: [Span: Int] = [:]
    /// The code of the `#if` clauses the build left out, and the directives of the one it kept.
    private(set) var skipped: [Span] = []

    /// What the walk works out, for the regions over a whole node and the regions that start at a point.
    var expectedOver: [Span: Int] = [:]
    var expectedFrom: [Point: Int] = [:]
    /// The times `break` and `continue` jumped to each statement, `nil` once one of them is unknown, and the times
    /// `continue` did.
    var jumps: [SyntaxIdentifier: Int?] = [:]
    var continues: [SyntaxIdentifier: Int?] = [:]
    /// The nodes whose code functions of their own count, and the one being walked.
    private(set) var functionBodies: Set<SyntaxIdentifier> = []
    private(set) var walking: SyntaxIdentifier?
    /// The functions' bodies that run only once the code around them has: closures, written or implicit.
    private(set) var madeWhereWritten: Set<Span> = []
    /// The closure literals that are the whole body of a function that makes them, which runs their capture lists.
    private(set) var madeElsewhere: Set<Span> = []
    /// Code that runs apart from the code around it, and where the regions that hold both start: a `case`'s pattern
    /// and `where`, tried for each value, which its region holds with its body, and a `repeat` loop's condition, which
    /// the region after its body holds with the code after the loop.
    var runApart: [(code: Span, holdersStart: Point)] = []
    /// The other regions whose counts Swift keeps directly, which a builder doesn't get wrong.
    var directlyCounted: Set<Span> = []
    /// The regions that run each time the code before them does: an `if`'s condition, a `switch`'s subject, a `do`.
    var runWithTheCodeBefore: Set<Span> = []
    /// The regions that Swift counts apart from the code around them, though not directly: a `repeat` loop's
    /// condition, from the loop's body, when the walk can't work it out and nothing in the body throws.
    var countedApart: Set<Span> = []
    /// How many ternaries the walk is in the second branch of, each a call deeper, up to a depth well within a
    /// discovery thread's stack.
    var ternaryDepth = 0
    static let deepestTernary = 50
    /// How many expressions the walk is in, each a call deeper, up to a depth well within a discovery thread's stack.
    /// Code deeper than that keeps llvm-cov's counts.
    var expressionDepth = 0
    static let deepestExpression = 200

    init(
        coverage: FileCoverage,
        source: SourceFileSyntax,
        location: @escaping (AbsolutePosition) -> Point
    ) {
        self.location = location

        let bodyRecords = records(of: coverage)
        let bodies = FunctionBodyFinder.bodies(in: source, spans: Set(bodyRecords.keys), span: span(of:))
        let closureBodies = Set(bodies.filter { $0.node.is(ClosureExprSyntax.self) }.map(\.span))
        // A closure, written or implicit, runs only once the code that makes it has.
        madeWhereWritten = Set(bodies.filter { Self.isMadeWhereItIsWritten($0.node) }.map(\.span))
        let captureEnds = Self.captureEnds(of: bodies, location: location)
        let bodyCounts = makeRegions(from: bodyRecords, closureBodies: closureBodies, captureEnds: captureEnds)
        linkCaptureLists(captureEnds)
        linkParents()
        walkTheBodies(bodies, entries: bodyCounts)
        markTheRegionsThatHoldCodeThatRan()
        workOutTheCounts()
        decideWhatRan()
    }

    /// Each function's first region, the body, with its count and where its other regions start, by its span. Notes
    /// the skipped code, and llvm-cov's count for every other region.
    private func records(of coverage: FileCoverage) -> [Span: [(count: Int, starts: [Point])]] {
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

        return bodyRecords
    }

    /// Where the capture list of each closure in `bodies` ends.
    private static func captureEnds(
        of bodies: [(span: Span, node: Syntax)],
        location: (AbsolutePosition) -> Point
    ) -> [Span: Point] {
        var captureEnds: [Span: Point] = [:]
        for body in bodies {
            if let capture = body.node.as(ClosureExprSyntax.self)?.signature?.capture {
                captureEnds[body.span] = location(capture.endPositionBeforeTrailingTrivia)
            }
        }
        return captureEnds
    }

    /// Makes `regions` from the bodies' records and llvm-cov's regions, and returns each body's count.
    private func makeRegions(
        from bodyRecords: [Span: [(count: Int, starts: [Point])]],
        closureBodies: Set<Span>,
        captureEnds: [Span: Point]
    ) -> [Span: Int] {
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
        return bodyCounts
    }

    /// Notes, for each closure's body, the regions that start in its capture list.
    private func linkCaptureLists(_ captureEnds: [Span: Point]) {
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
    }

    /// Notes each region's parent: the innermost earlier region that holds it.
    private func linkParents() {
        for index in regions.indices {
            let span = regions[index].span
            var candidate = index > 0 ? index - 1 : nil
            while let current = candidate, !holds(span, current) {
                candidate = next(after: current, lookingFor: span)
            }
            regions[index].parent = candidate
        }
    }

    /// Walks each function's body from its count, `entries`.
    private func walkTheBodies(_ bodies: [(span: Span, node: Syntax)], entries bodyCounts: [Span: Int]) {
        functionBodies = Set(bodies.map(\.node.id))
        for body in bodies {
            walking = body.node.id
            walkFunctionBody(body.node, entry: bodyCounts[body.span] ?? 0)
        }
        walking = nil
    }

    /// Marks the regions that hold code Swift counts directly and that ran, up to the function's body.
    private func markTheRegionsThatHoldCodeThatRan() {
        for index in regions.indices
        where isDirectlyCounted(regions[index]) && (1...Int.max / 2).contains(regions[index].executionCount) {
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
    }

    /// Puts the counts the walk worked out in place, and notes the regions whose counts say nothing.
    private func workOutTheCounts() {
        for index in regions.indices {
            let span = regions[index].span
            if !regions[index].isFixed, let count = expectedOver[span] ?? expectedFrom[span.start] {
                regions[index].executionCount = count
                regions[index].wasWorkedOut = true
            }
            let region = regions[index]
            let parentsCountsSayNothing = region.parent.map { regions[$0].countsInItSayNothing } ?? false
            if region.isFixed {
                regions[index].countsInItSayNothing = region.executionCount == 0
                    || madeWhereWritten.contains(span) && parentsCountsSayNothing
            } else if directlyCounted.contains(span) || countedApart.contains(span) {
                regions[index].countsInItSayNothing = region.executionCount == 0 || parentsCountsSayNothing
            } else {
                regions[index].countsInItSayNothing = region.reportedCount == 0
                    || region.wasWorkedOut && region.executionCount == 0 || parentsCountsSayNothing
            }
        }
    }

    /// Decides whether the code in each region ran.
    private func decideWhatRan() {
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
            if region.holdsCodeThatRan || !saysNothing && (1...Int.max / 2).contains(region.executionCount) {
                regions[index].ran = true
            } else if saysNothing, runWithTheCodeBefore.contains(region.span), let parent = region.parent {
                regions[index].ran = regions[parent].ran
            } else {
                regions[index].ran = region.executionCount != 0 && !isInRegionWhoseCountsSayNothing(index)
            }
        }
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
}
