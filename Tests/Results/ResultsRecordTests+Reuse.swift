@testable import muterCore
import XCTest

extension ResultsRecordTests {
    // A reused result goes into the reusing session's file in its job's place, as tested where it was, with where that
    // was. Changes let through by a later session of its file, by an earlier reuse or by the reusing session mark it.
    func test_aReusedResult_takesTheNewSessionAndPlace_andSaysWhereItWasTested() {
        let tested = MutantResult.make(
            session: 1,
            utf8Offset: 3_361,
            outcome: .failed,
            killedBy: [.init(name: "sum()", location: nil)]
        )

        let copy = reuse(tested, from: "/logs/a/results.jsonl", headers: [.make(session: 1)])

        XCTAssertEqual(copy.session, 1)
        XCTAssertEqual(copy.utf8Offset, 4_000)
        XCTAssertEqual(copy.switchID, "Sum_new")
        XCTAssertEqual(
            copy.reusedFrom,
            ReusedFrom(resultsFile: "/logs/a/results.jsonl", session: 1, despiteChanges: false)
        )
        var unmarked = copy
        unmarked.reusedFrom = nil
        XCTAssertEqual(
            unmarked,
            MutantResult.make(
                session: 1,
                utf8Offset: 4_000,
                switchID: "Sum_new",
                outcome: .failed,
                killedBy: tested.killedBy
            )
        )

        let waivedLater = reuse(
            tested,
            from: "/logs/a/results.jsonl",
            headers: [.make(session: 1), .make(formatVersion: 2, session: 2, waived: ["README.md"])]
        )
        XCTAssertEqual(waivedLater.reusedFrom?.despiteChanges, true)

        // Reused again, it still says where it was tested, and that changes were let through on the way.
        let again = reuse(
            waivedLater,
            from: "/logs/b/results.jsonl",
            headers: [.make(session: 1)],
            utf8Offset: 4_100,
            switchID: "Sum_newer"
        )
        XCTAssertEqual(
            again.reusedFrom,
            ReusedFrom(resultsFile: "/logs/a/results.jsonl", session: 1, despiteChanges: true)
        )
    }

    // A result tested here has no `reusedFrom`, and one kept without any change let through has no `despiteChanges`.
    func test_reusedFrom_isLeftOutWhenNil_andDespiteChangesUnlessTrue() throws {
        let tested = try XCTUnwrap(String(data: ResultsCoding.encoder.encode(MutantResult.make()), encoding: .utf8))
        XCTAssertFalse(tested.contains("reusedFrom"))

        let reused = MutantResult.make(
            reusedFrom: ReusedFrom(resultsFile: "/r.jsonl", session: 1, despiteChanges: false)
        )
        let line = try XCTUnwrap(String(data: ResultsCoding.encoder.encode(reused), encoding: .utf8))
        XCTAssertTrue(line.contains(#""reusedFrom":{"resultsFile":"/r.jsonl","session":1}"#), line)
        XCTAssertEqual(try ResultsCoding.decoder.decode(MutantResult.self, from: Data(line.utf8)), reused)
    }

    // A tested result has no `rerun`; a timeout tested again says why and at what load.
    func test_rerun_isLeftOutWhenNil_andRoundTrips() throws {
        XCTAssertFalse(try line(MutantResult.make()).contains("rerun"))

        let rerun = MutantResult.make(rerun: MutantResult.Rerun(because: MutantResult.Rerun.timeout, workers: 2))
        let written = try line(rerun)
        XCTAssertTrue(written.contains(#""rerun":{"because":"timeout","workers":2}"#), written)
        XCTAssertEqual(try decode(MutantResult.self, from: written), rerun)
    }

    // A reason a later SwiftMutator adds must not make the line unreadable: a reader would skip it, and the first
    // run's timeout would stand in its place.
    func test_aRerunForAReasonAddedLater_stillReads() throws {
        let written = try line(MutantResult.make(rerun: MutantResult.Rerun(because: "timeout", workers: 1)))
            .replacingOccurrences(of: #""because":"timeout""#, with: #""because":"flaky""#)

        XCTAssertEqual(try decode(MutantResult.self, from: written).rerun?.because, "flaky")
    }

    // A reused rerun's result is the rerun's, and so is the log copied with it.
    func test_aReusedRerun_keepsItsRerun() {
        let rerun = MutantResult.Rerun(because: MutantResult.Rerun.timeout, workers: 1)
        let copy = MutantResult.make(rerun: rerun).reused(
            from: "/logs/a/results.jsonl",
            headers: [.make(session: 1)],
            in: 1,
            at: .init(utf8Offset: 4_000, switchID: "Sum_new"),
            despiteChanges: false
        )

        XCTAssertEqual(copy.rerun, rerun)
    }

    /// `result` reused from `resultsFile` into session 1, in place of `switchID` at `utf8Offset`, with no change let
    /// through by the reusing session.
    private func reuse(
        _ result: MutantResult,
        from resultsFile: String,
        headers: [ResultsHeader],
        utf8Offset: Int = 4_000,
        switchID: String = "Sum_new"
    ) -> MutantResult {
        result.reused(
            from: resultsFile,
            headers: headers,
            in: 1,
            at: .init(utf8Offset: utf8Offset, switchID: switchID),
            despiteChanges: false
        )
    }
}
