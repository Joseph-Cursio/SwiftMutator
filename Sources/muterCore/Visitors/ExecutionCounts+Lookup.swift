import SwiftSyntax

extension ExecutionCounts {
    func isInRegionWhoseCountsSayNothing(_ index: Int) -> Bool {
        guard !regions[index].isFixed, let parent = regions[index].parent else {
            return false
        }
        return regions[parent].countsInItSayNothing
    }

    func isDirectlyCounted(_ region: CountedRegion) -> Bool {
        region.isFixed ? madeWhereWritten.contains(region.span) : directlyCounted.contains(region.span)
    }

    /// Each region once, with its count worked out again where it follows from others, in order of start.
    var countedRegions: [Region] {
        regions.map {
            Region(
                lineStart: $0.span.start.line,
                columnStart: $0.span.start.column,
                lineEnd: $0.span.end.line,
                columnEnd: $0.span.end.column,
                executionCount: $0.executionCount
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
    func innermostRegion(holding span: Span) -> Int? {
        var index = lastRegion(startingAtOrBefore: span.start)
        while let current = index, !holds(span, current) {
            index = next(after: current, lookingFor: span)
        }
        return index
    }

    func holds(_ span: Span, _ index: Int) -> Bool {
        if let captureEnd = regions[index].captureEnd, span.start < captureEnd {
            return false
        }
        return regions[index].span.contains(span) && !crossesTheBody(holding: span, index)
    }

    /// The region to look at after `index` for one that holds `span`: its parent, but past a region that starts in a
    /// closure's capture list when `span` is in the closure's body, the one before it, in the closure, and past a
    /// closure, the last region that starts in its capture list and holds `span`, after the closure.
    func next(after index: Int, lookingFor span: Span) -> Int? {
        if crossesTheBody(holding: span, index) {
            return index - 1
        }
        return regions[index].crossings.last { regions[$0].span != span && holds(span, $0) } ?? regions[index].parent
    }

    func crossesTheBody(holding span: Span, _ index: Int) -> Bool {
        regions[index].crossedBodies.contains { holds(span, $0) }
    }

    func lastRegion(startingAtOrBefore point: Point) -> Int? {
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

    func span(of node: some SyntaxProtocol) -> Span {
        Span(
            start: location(node.positionAfterSkippingLeadingTrivia),
            end: location(node.endPositionBeforeTrailingTrivia)
        )
    }
}
