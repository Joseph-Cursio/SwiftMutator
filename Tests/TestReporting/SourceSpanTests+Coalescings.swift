@testable import muterCore
import XCTest

extension SourceSpanTests {
    // A `??` term is placed where it starts, and spans the whole term, over as many lines as it takes; a chain's inner
    // link spans its own term from its own left side.
    func test_aReplacedCoalescing_spansItsTerm() {
        let text = "    return a\n        ?? b ?? 0"

        XCTAssertEqual(
            span(text, utf8Column: 12, before: "a ?? b ?? 0", by: .replaceNilCoalescing, after: "b ?? 0"),
            SourceSpan(start: position(1, 12), end: position(2, 18))
        )
        XCTAssertEqual(
            span(text, utf8Column: 12, line: 2, before: "b ?? 0", by: .replaceNilCoalescing, after: "0"),
            SourceSpan(start: position(2, 12), end: position(2, 18))
        )
    }
}
