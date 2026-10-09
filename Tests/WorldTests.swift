@testable import muterCore
import XCTest

final class WorldTests: XCTestCase {
    // Rainbow's rule for where colour can show, so the progress bar redraws itself only there.
    func test_standardOutIsATerminal_whenItIsATty_andTERMIsSetAndNotDumb() {
        XCTAssertTrue(World.isTerminal(isatty: true, term: "xterm-256color"))
        XCTAssertTrue(World.isTerminal(isatty: true, term: ""))
        XCTAssertFalse(World.isTerminal(isatty: true, term: "dumb"))
        XCTAssertFalse(World.isTerminal(isatty: true, term: "DUMB"))
        XCTAssertFalse(World.isTerminal(isatty: true, term: nil))
        XCTAssertFalse(World.isTerminal(isatty: false, term: "xterm-256color"))
    }
}
