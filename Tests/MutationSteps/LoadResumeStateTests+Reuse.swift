@testable import muterCore
import TestingExtensions
import XCTest

extension LoadResumeStateTests {
    // A reuse writes a file of its own, so it neither opens the earlier one to append nor locks it: a run still writing
    // it doesn't stop it. Changed files don't refuse it, but decide what it keeps once the copy is fingerprinted, so
    // the project isn't listed here.
    func test_aReuse_readsTheFileWithoutLockingIt_andChangedFilesDontRefuseIt() async throws {
        let header = ResultsHeader.make(project: await projectTree())
        try writeResults(header, ResultsEnd.make())
        try write(["README.md": "a changed readme"], in: project)
        let running = try ResultsFile.Opener().openForResume(at: resultsPath)
        defer { running.close() }
        reuse(logs)

        let changes = try await sut.run(with: state)
        state.apply(changes)

        let loaded = try XCTUnwrap(state.resumeState)
        XCTAssertTrue(loaded.isReuse)
        XCTAssertNil(loaded.file)
        XCTAssertEqual(loaded.path, resultsPath)
        XCTAssertEqual(loaded.lastHeader, header)
        XCTAssertEqual(listed.value, [])
    }

    // Its logs are copied long after the file is read, so the reuse holds a shared lock on the earlier run's folders
    // until it ends, which a run that prunes log folders in another lock domain sees as in use.
    func test_aReuse_holdsTheEarlierRunsFolders_soNoRunPrunesThem() async throws {
        let header = ResultsHeader.make(project: await projectTree(), logDirectory: logs)
        try writeResults(header, ResultsEnd.make())
        RunMarker.hold(in: logs)?.release()
        let marker = logs + "/" + RunMarker.fileName
        reuse(logs)

        state.apply(try await sut.run(with: state))

        XCTAssertNotNil(state.resumeState?.reusedFolders)
        XCTAssertEqual(ResultsFile.probeLock(marker), .inUse)
        state.resumeState = nil
        guard case let .held(probe) = ResultsFile.probeLock(marker) else {
            XCTFail("still locked")
            return
        }
        close(probe)
    }

    func test_aReuse_ofAResumedSessionsLogFolder_readsTheFileItsNoteNames() async throws {
        let header = ResultsHeader.make(project: await projectTree())
        try writeResults(header, ResultsEnd.make())
        reuse(try makeAResumedSessionsLogFolder())

        let changes = try await sut.run(with: state)
        state.apply(changes)

        let loaded = try XCTUnwrap(state.resumeState)
        XCTAssertTrue(loaded.isReuse)
        XCTAssertEqual(loaded.path, resultsPath)
        XCTAssertEqual(loaded.lastHeader, header)
    }

    // What a reuse can't take, it refuses as a resume does, naming its own flags.
    func test_aReuse_isRefusedAsAResumeIs_namingForceReuse() async throws {
        try await writeResults(ResultsHeader.make(project: projectTree()), ResultsEnd.make())
        let changed = provenance(toolchain: "Apple Swift version 6.5")
        current.provenance = { _ in changed }
        reuse(resultsPath, reportURL: URL(fileURLWithPath: resultsPath))

        await AssertThrowsError(try await sut.run(with: state)) { error in
            let refused = error as? ResumeRefused
            XCTAssertEqual(refused?.isReuse, true)
            XCTAssertEqual(refused?.reasons.count, 2)
            let message = refused.map { "\($0)" } ?? ""
            XCTAssertTrue(message.hasPrefix("SwiftMutator won't reuse the results in "), message)
            XCTAssertTrue(message.contains("--force-reuse reuses the results anyway."), message)
            XCTAssertFalse(message.contains("--force-resume"), message)
            XCTAssertTrue(message.contains("is the results file itself"), message)
        }
        XCTAssertNil(state.resumeState)

        current.provenance = { _ in .fixture }
        reuse(resultsPath, forcing: true)
        current.provenance = { _ in changed }
        let changes = try await sut.run(with: state)
        state.apply(changes)
        XCTAssertEqual(state.resumeState?.forced, ["toolchain.testCommandVersion"])
    }
}
