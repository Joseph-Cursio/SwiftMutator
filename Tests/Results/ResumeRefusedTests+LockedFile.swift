@testable import muterCore
import XCTest

extension ResumeRefusedTests {
    func test_aLockedFile_namesTheHolder() {
        let holder = LockHolder(process: 81_234, started: 1_700_000_000_000_000, host: "studio.local")
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
        let holder = LockHolder(process: 81_234, started: 1_700_000_000_000_000, host: "")

        XCTAssertEqual(
            "\(ResumeRefusal.inUse(holder: .running(holder), lastProcess: nil, lastHost: nil))",
            "another SwiftMutator run, process 81234, holds its lock. Wait for that run to end, or stop it, then "
                + "resume again."
        )
    }

    // A record from another host may be one a killed run left, and a host's name can change while it runs.
    func test_aLockedFile_whoseHolderIsOnAnotherHost_saysItCantBeChecked() {
        let holder = LockHolder(process: 81_234, started: 1_700_000_000_000_000, host: "mini.local")

        XCTAssertEqual(
            "\(ResumeRefusal.inUse(holder: .unchecked(holder), lastProcess: nil, lastHost: nil))",
            "another SwiftMutator run holds its lock: by its record, process 81234 on mini.local, which this host "
                + "can't check."
        )
    }

    // An older SwiftMutator records no holder, and a resume holds the lock long before it writes its session.
    func test_aLockedFile_withoutAHolder_namesTheLastSessionsProcessAndHost_asMaybeNotTheHolder() {
        XCTAssertEqual(
            "\(ResumeRefusal.inUse(holder: nil, lastProcess: 81_234, lastHost: "studio.local"))",
            "another SwiftMutator run holds its lock, and doesn't say which. The file's last session was written by "
                + "process 81234 on studio.local, but that run may not be the one: a resume holds the lock before it "
                + "writes a session of its own."
        )
        XCTAssertEqual(
            "\(ResumeRefusal.inUse(holder: nil, lastProcess: 81_234, lastHost: ""))",
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
}
