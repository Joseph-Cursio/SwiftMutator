@testable import muterCore
import XCTest

// A resumed header records its tree as what changed since an earlier session's, and is read with that tree made again.
extension RecordedResultsTests {
    func test_aResumedHeadersDelta_isReadAsTheWholeTree_sessionAfterSession() throws {
        let first = projectTree(["Sum.swift": "1", "Total.swift": "2"])
        let second = projectTree(["Sum.swift": "1", "Total.swift": "3", "Product.swift": "4"])
        let third = projectTree(["Total.swift": "3", "Product.swift": "4"])

        let recorded = try read(file(
            ResultsHeader.make(project: first),
            end,
            resumed(session: 2, ProjectTreeDelta(from: first, to: second)),
            resumed(session: 3, ProjectTreeDelta(from: second, to: third))
        ))

        XCTAssertEqual(recorded.headers.map(\.project), [first, second, third])
        XCTAssertEqual(recorded.unreadableLines, [])
    }

    // Without the tree it was recorded against, as when that header's line was cut off, a delta's header doesn't read,
    // and nor do its session's results, which a resume then tests again.
    func test_aDeltaWithoutItsBase_leavesItsHeaderAndItsSessionsResultsUnread() throws {
        let first = projectTree(["Sum.swift": "1"])
        let second = projectTree(["Sum.swift": "2"])
        let other = projectTree(["Total.swift": "9"])
        let secondSum = MutantResult.make(session: 2, path: "Sources/Sum.swift")

        let recorded = try read(file(
            ResultsHeader.make(project: first),
            end,
            resumed(session: 2, ProjectTreeDelta(from: other, to: second)),
            secondSum
        ))

        XCTAssertEqual(recorded.headers.map(\.session), [1])
        XCTAssertEqual(recorded.unreadableLines, [3, 4])
        XCTAssertEqual(recorded.latest.count, 0)
    }
}
