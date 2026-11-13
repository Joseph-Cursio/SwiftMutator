@testable import muterCore
import XCTest

final class MutationPositionTests: XCTestCase {
    // A later position on a later line, at an earlier column: `<` once needed all three to be less, so neither was
    // less than the other, and `sorted()` left them as they were.
    func test_positions_sortByOffset_whateverTheirColumns() {
        let earlier = MutationPosition(utf8Offset: 40, line: 2, column: 30)
        let later = MutationPosition(utf8Offset: 90, line: 5, column: 3)

        XCTAssertTrue(earlier < later)
        XCTAssertFalse(later < earlier)
        XCTAssertEqual([later, earlier].sorted(), [earlier, later])
    }

    // Equal offsets fall back to the line, then the column, and no position is less than an equal one.
    func test_equalOffsets_fallBackToTheLine_thenTheColumn() {
        let position = MutationPosition(utf8Offset: 7, line: 1, column: 8)
        let same = MutationPosition(utf8Offset: 7, line: 1, column: 8)

        XCTAssertFalse(position < same)
        XCTAssertTrue(position < MutationPosition(utf8Offset: 7, line: 2, column: 1))
        XCTAssertTrue(position < MutationPosition(utf8Offset: 7, line: 1, column: 9))
    }
}
