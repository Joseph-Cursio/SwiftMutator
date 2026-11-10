@testable import muterCore
import XCTest

extension ResumeCheckTests {
    static let selected = ChangeSelection.make(
        changedLines: true,
        files: [ChangedFile(path: "Sources/Sum.swift", sha256: "ab12", lines: [LineRange(first: 3, last: 4)])]
    )

    func test_theSameMergeBase_resumes_whateverTheRefIsCalled() {
        let recorded = header(of: current(since: Self.selected))
        let renamed = ChangeSelection.make(ref: "ba5e000", changedLines: true, files: Self.selected.files)

        XCTAssertEqual(check(current(since: renamed), recorded: recorded), ResumeCheck.Verdict())
    }

    func test_sinceGivenOnOneSideOnly_refuses() {
        let verdict = check(current(since: Self.selected))

        let difference = ResumeCheck.Difference(name: "since", was: nil, isNow: #""main""#)
        XCTAssertEqual(verdict.refusals, [.selectionChanged(difference)])
        XCTAssertEqual(
            "\(ResumeRefusal.selectionChanged(difference))",
            #"since was not set and is "main" now. A change to which mutants are tested needs a new run."#
        )
        XCTAssertEqual(
            check(current(), recorded: header(of: current(since: Self.selected))).refusals,
            [.selectionChanged(.init(name: "since", was: #""main""#, isNow: nil))]
        )
    }

    // A ref that moved, as origin/main does after a fetch, names another merge base, and so other changes.
    func test_anotherMergeBase_orChangedLinesTurnedOn_refuses() {
        let recorded = header(of: current(since: .make(files: Self.selected.files)))
        let moved = ChangeSelection.make(mergeBase: "fee1000000000000000000000000000000000000", changedLines: true)

        let verdict = check(current(since: moved), recorded: recorded)

        XCTAssertEqual(verdict.refusals, [
            .selectionChanged(.init(
                name: "since.mergeBase",
                was: #""ba5e000000000000000000000000000000000000""#,
                isNow: #""fee1000000000000000000000000000000000000""#
            )),
            .selectionChanged(.init(name: "since.changedLines", was: "false", isNow: "true")),
        ])
    }

    // The files and lines follow from the working tree: a changed file is compared as the project's files are, and its
    // mutants are tested again; a mutant no longer chosen is one no longer discovered.
    func test_otherFilesOrLines_fromTheSameMergeBase_resume() {
        let recorded = header(of: current(since: Self.selected))
        let edited = ChangeSelection.make(changedLines: true, files: [
            ChangedFile(path: "Sources/Product.swift", sha256: "ef56"),
            ChangedFile(
                path: "Sources/Sum.swift",
                sha256: "ff",
                lines: [LineRange(first: 3, last: 5)],
                deletionsAfter: [9]
            ),
        ])

        XCTAssertEqual(check(current(since: edited), recorded: recorded).refusals, [])
    }

    // A reuse keeps a result only for a mutant it discovers, which holds whatever else is tested.
    func test_aReuse_doesntCompareWhatSinceChose_eitherWay() {
        let moved = ChangeSelection.make(mergeBase: "fee1000000000000000000000000000000000000")

        XCTAssertEqual(
            check(current(), recorded: header(of: current(since: Self.selected)), for: .reuse).refusals,
            []
        )
        XCTAssertEqual(
            check(current(since: Self.selected), recorded: header(of: current()), for: .reuse).refusals,
            []
        )
        XCTAssertEqual(
            check(current(since: moved), recorded: header(of: current(since: Self.selected)), for: .reuse).refusals,
            []
        )
    }
}
