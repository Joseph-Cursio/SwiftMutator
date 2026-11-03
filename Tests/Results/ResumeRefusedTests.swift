@testable import muterCore
import XCTest

final class ResumeRefusedTests: XCTestCase {
    private let path = "/logs/results.jsonl"

    func test_listsEveryReason_andSaysNothingWasCopiedOrRemoved() {
        let refused = ResumeRefused(
            path: path,
            reasons: [
                .configurationChanged(.init(name: "mutationTestTimeout", was: "120", isNow: "60")),
                .needsForce(
                    .init(
                        name: "toolchain.testCommandVersion",
                        was: #""Apple Swift version 6.3.3""#,
                        isNow: #""Apple Swift version 6.4""#
                    )
                ),
                .filesChanged([
                    .init(path: "README.md", kind: .changed),
                    .init(path: "notes.txt", kind: .added),
                ]),
            ],
            beforeTheCopy: true
        )

        XCTAssertEqual(
            "\(refused)",
            """
            SwiftMutator won't resume the run in '/logs/results.jsonl', so that no result is reused that this run \
            might not reproduce:
              - mutationTestTimeout was 120 and is 60 now. A time limit shorter than a session's, or none, needs a \
            new run: one at least as long as every session's only tests timeouts again.
              - The toolchain (toolchain.testCommandVersion) was "Apple Swift version 6.3.3" and is \
            "Apple Swift version 6.4" now. --force-resume reuses the results anyway.
              - 2 project files changed since the run stopped: README.md (changed), notes.txt (added).
                If they can't change any test's result: --resume-ignoring 'README.md' --resume-ignoring 'notes.txt'
                Mutants in a changed source file are tested again either way.
            Nothing was copied or removed.
            """
        )
    }

    func test_afterTheCopy_doesNotSayNothingWasCopied() {
        let refused = ResumeRefused(
            path: path,
            reasons: [.filesChanged([.init(path: "Sources/Sum.swift", kind: .changed)])],
            beforeTheCopy: false
        )

        XCTAssertFalse("\(refused)".contains("Nothing was copied"))
        XCTAssertTrue("\(refused)".hasSuffix("Mutants in a changed source file are tested again either way."))
    }

    func test_aLockedFile_namesTheHolder() {
        let holder = LockHolder(process: 81234, started: 1_700_000_000_000_000, host: "studio.local")
        let refused = ResumeRefused(
            path: path,
            reasons: [.inUse(holder: .running(holder), lastProcess: nil, lastHost: nil)],
            beforeTheCopy: true
        )

        XCTAssertEqual(
            "\(refused)",
            """
            SwiftMutator won't resume the run in '/logs/results.jsonl': another SwiftMutator run, process 81234 on \
            studio.local, holds its lock. Wait for that run to end, or stop it, then resume again.
            Nothing was copied or removed.
            """
        )
    }

    func test_aLockedFile_whoseHolderNamesNoHost_namesItsProcess() {
        let holder = LockHolder(process: 81234, started: 1_700_000_000_000_000, host: "")

        XCTAssertEqual(
            "\(ResumeRefusal.inUse(holder: .running(holder), lastProcess: nil, lastHost: nil))",
            "another SwiftMutator run, process 81234, holds its lock. Wait for that run to end, or stop it, then "
                + "resume again."
        )
    }

    // A record from another host may be one a killed run left, and a host's name can change while it runs.
    func test_aLockedFile_whoseHolderIsOnAnotherHost_saysItCantBeChecked() {
        let holder = LockHolder(process: 81234, started: 1_700_000_000_000_000, host: "mini.local")

        XCTAssertEqual(
            "\(ResumeRefusal.inUse(holder: .unchecked(holder), lastProcess: nil, lastHost: nil))",
            "another SwiftMutator run holds its lock: by its record, process 81234 on mini.local, which this host "
                + "can't check."
        )
    }

    // An older SwiftMutator records no holder, and a resume holds the lock long before it writes its session.
    func test_aLockedFile_withoutAHolder_namesTheLastSessionsProcessAndHost_asMaybeNotTheHolder() {
        XCTAssertEqual(
            "\(ResumeRefusal.inUse(holder: nil, lastProcess: 81234, lastHost: "studio.local"))",
            "another SwiftMutator run holds its lock, and doesn't say which. The file's last session was written by "
                + "process 81234 on studio.local, but that run may not be the one: a resume holds the lock before it "
                + "writes a session of its own."
        )
        XCTAssertEqual(
            "\(ResumeRefusal.inUse(holder: nil, lastProcess: 81234, lastHost: ""))",
            "another SwiftMutator run holds its lock, and doesn't say which. The file's last session was written by "
                + "process 81234, but that run may not be the one: a resume holds the lock before it writes a "
                + "session of its own."
        )
        XCTAssertEqual(
            "\(ResumeRefusal.inUse(holder: nil, lastProcess: nil, lastHost: "studio.local"))",
            "another SwiftMutator run holds its lock, and doesn't say which. The file's last session was written on "
                + "studio.local, but that run may not be the one: a resume holds the lock before it writes a session "
                + "of its own."
        )
    }

    func test_aLockedFile_whoseLastSessionIsUnknown_saysOnlyThatItIsLocked() {
        XCTAssertEqual(
            "\(ResumeRefusal.inUse(holder: nil, lastProcess: nil, lastHost: nil))",
            "another SwiftMutator run holds its lock."
        )
    }

    func test_isInUse_onlyWhenTheLockIsTheOnlyReason() {
        let locked = ResumeRefusal.inUse(holder: nil, lastProcess: 81234, lastHost: "studio.local")
        let changed = ResumeRefusal.filesChanged([.init(path: "notes.txt", kind: .added)])
        let alone = ResumeRefused(path: path, reasons: [locked], beforeTheCopy: true)
        let otherReasons = ResumeRefused(path: path, reasons: [changed, .noProjectTree], beforeTheCopy: true)
        let lockedAndChanged = ResumeRefused(path: path, reasons: [locked, changed], beforeTheCopy: true)

        XCTAssertTrue(alone.isInUse)
        XCTAssertFalse(otherReasons.isInUse)
        XCTAssertFalse(lockedAndChanged.isInUse)
        XCTAssertFalse(ResumeRefused(path: path, reasons: [changed], beforeTheCopy: true).isInUse)
        XCTAssertEqual(
            "\(alone)",
            "SwiftMutator won't resume the run in '/logs/results.jsonl': \(locked)\nNothing was copied or removed."
        )
        XCTAssertTrue(
            "\(otherReasons)".hasPrefix(
                "SwiftMutator won't resume the run in '/logs/results.jsonl', so that no result is reused"
            ),
            "\(otherReasons)"
        )
        XCTAssertTrue(
            "\(lockedAndChanged)".hasPrefix(
                "SwiftMutator won't resume the run in '/logs/results.jsonl', so that no result is reused"
            ),
            "\(lockedAndChanged)"
        )
    }

    func test_oneChangedFile_isSaidInTheSingular() {
        XCTAssertEqual(
            "\(ResumeRefusal.filesChanged([.init(path: "Docs/rules/Sum.md", kind: .removed)]))",
            """
            1 project file changed since the run stopped: Docs/rules/Sum.md (removed).
            If it can't change any test's result: --resume-ignoring 'Docs/rules/Sum.md'
            Mutants in a changed source file are tested again either way.
            """
        )
    }

    func test_moreThanTenChangedFiles_namesTen_andCountsTheRest() {
        let changes = (1 ... 13).map { ProjectTree.FileChange(path: "Docs/\($0).md", kind: .changed) }

        let lines = "\(ResumeRefusal.filesChanged(changes))".components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("13 project files changed since the run stopped: Docs/1.md (changed), "))
        XCTAssertTrue(lines[0].hasSuffix(", Docs/10.md (changed), and 3 more."))
        XCTAssertFalse(lines[0].contains("Docs/11.md"))
        XCTAssertTrue(lines[1].hasPrefix("If they can't change any test's result: --resume-ignoring 'Docs/1.md' "))
        XCTAssertTrue(lines[1].hasSuffix(" --resume-ignoring 'Docs/10.md', plus globs for the other 3"))
        XCTAssertFalse(lines[1].contains("Docs/11.md"))
    }

    func test_eachIgnoringGlob_matchesOnlyItsOwnFile() {
        let paths = ["Docs/a*b.md", "Docs/aXb.md", "Tests/[x].json", "Tests/x.json", "q?.md", "qq.md", #"back\slash"#]
        let changes = paths.map { ProjectTree.FileChange(path: $0, kind: .changed) }

        for path in paths {
            let glob = ResumeRefusal.glob(matching: path)

            XCTAssertEqual(changes.partition(by: [glob]).waived.map(\.path), [path], glob)
        }
        XCTAssertEqual(ResumeRefusal.glob(matching: "Docs/a*b.md"), #"Docs/a\*b.md"#)
    }

    func test_anIgnoringFlag_isQuotedForAShell() {
        let description = "\(ResumeRefusal.filesChanged([.init(path: "it's here.md", kind: .added)]))"

        XCTAssertTrue(description.contains(#"--resume-ignoring 'it'\''s here.md'"#), description)
    }

    func test_otherReasons_sayWhatIsNeeded() {
        XCTAssertEqual(
            "\(ResumeRefusal.testPlanRun)",
            "A run that tests a test plan (run-without-mutating) can't be resumed."
        )
        XCTAssertEqual(
            "\(ResumeRefusal.noProjectTree)",
            "The file's last session recorded no project files, as SwiftMutator didn't before --resume, "
                + "so nothing shows that they haven't changed. A new run is needed."
        )
        XCTAssertEqual(
            "\(ResumeRefusal.reportWouldReplaceTheResultsFile("/logs/results.jsonl"))",
            "-o '/logs/results.jsonl' is the results file itself, which the report would replace. "
                + "Write the report to another file."
        )
    }
}
