import SwiftSyntax

extension ExecutionCounts {
    struct Span: Hashable {
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
        func contains(_ other: Self) -> Bool {
            start <= other.start && other.end <= end
        }
    }

    struct CountedRegion {
        let span: Span
        var executionCount: Int
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
            executionCount = count
            reportedCount = count
            self.isFixed = isFixed
            self.makesAClosure = makesAClosure
        }
    }

    /// The node whose code each function's first region counts, in order of start: a function's body, a closure, a
    /// getter's statements, or the expression of a property's initial value or of an implicit closure.
    final class FunctionBodyFinder: SyntaxAnyVisitor {
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
