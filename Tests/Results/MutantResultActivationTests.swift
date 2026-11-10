@testable import muterCore
import XCTest

final class MutantResultActivationTests: XCTestCase {
    // A result reused from an earlier run says what that run showed of its code.
    func test_aReusedResult_keepsWhatItsRunShowed() {
        var result = MutantResult.make(session: 1, outcome: .passed)
        result.activated = false

        let reused = result.reused(
            from: "/logs/results.jsonl",
            headers: [],
            in: 1,
            at: .init(utf8Offset: 0, switchID: "id"),
            despiteChanges: false
        )

        XCTAssertFalse(try XCTUnwrap(reused.activated))
    }

    // An older line has no such key, which says nothing either way.
    func test_aLineWithoutTheKey_showsNothing() throws {
        let encoded = try ResultsCoding.encoder.encode(MutantResult.make(session: 1, outcome: .passed))

        let line = String(lossyUTF8: encoded)
        XCTAssertFalse(line.contains("activated"), line)
        XCTAssertNil(try ResultsCoding.decoder.decode(MutantResult.self, from: encoded).activated)
    }
}
