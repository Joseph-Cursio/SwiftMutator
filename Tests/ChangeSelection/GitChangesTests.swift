@testable import muterCore
import XCTest

/// Real folders and a real git. The fixtures are made without the user's or the system's git settings, under a fixed
/// identity; the selection's own git calls see them, as a user's run would.
final class GitChangesTests: XCTestCase {
    private var repository = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        repository = try makeTemporaryDirectory()
        try git("init", "-q", "-b", "main")
    }

    // The merge base, not main itself: a change main made after the branch left it isn't the branch's.
    func test_choosesWhatTheBranchChanged_sinceItsMergeBase() async throws {
        try write(["Sources/A.swift": lines(1...5), "Sources/B.swift": lines(1...5), "README.md": "readme"])
        try commit("start")
        let start = try output("rev-parse", "HEAD")
        try git("checkout", "-q", "-b", "feature")
        try write(["Sources/A.swift": lines(1...5, changing: [3]), "README.md": "changed"])
        try commit("feature")
        try git("checkout", "-q", "main")
        try write(["Sources/B.swift": lines(1...5, changing: [1])])
        try commit("main moves on")
        try git("checkout", "-q", "feature")

        let selection = try await select(since: "main")

        XCTAssertEqual(selection.ref, "main")
        XCTAssertEqual(selection.mergeBase, start)
        XCTAssertEqual(selection.commit, try output("rev-parse", "main"))
        XCTAssertEqual(selection.files.map(\.path), ["Sources/A.swift"])
        XCTAssertEqual(selection.files.first?.sha256, FileDigest.sha256(of: url("Sources/A.swift")))
        XCTAssertNil(selection.files.first?.lines)
    }

    func test_uncommittedAndUntrackedSwiftFilesCount_butIgnoredAndRemovedOnesDont() async throws {
        try write([".gitignore": "Generated/\n", "Sources/A.swift": lines(1...5), "Sources/Gone.swift": lines(1...2)])
        try commit("start")
        try write([
            "Sources/A.swift": lines(1...5, changing: [2]),
            "Sources/New.swift": lines(1...3),
            "Generated/Made.swift": lines(1...3),
        ])
        try FileManager.default.removeItem(at: url("Sources/Gone.swift"))

        let selection = try await select(since: "HEAD", changedLines: true)

        XCTAssertEqual(selection.files.map(\.path), ["Sources/A.swift", "Sources/New.swift"])
        XCTAssertEqual(selection.files.first?.lines, [LineRange(first: 2, last: 2)])
        XCTAssertNil(selection.files.last?.lines, "a new file is changed throughout")
    }

    func test_changedLines_areTheWorkingTreesLines() async throws {
        try write(["A.swift": lines(1...20)])
        try commit("start")
        // Two lines added above the change move it down by two.
        try write(["A.swift": "added\nadded\n" + lines(1...20, changing: [10], removing: [15, 16])])

        let file = try await select(since: "HEAD", changedLines: true).files.first

        XCTAssertEqual(file?.lines, [LineRange(first: 1, last: 2), LineRange(first: 12, last: 12)])
        XCTAssertEqual(file?.deletionsAfter, [16])
    }

    // Moved and edited: only the edit is a change, and the file is chosen by its new path.
    func test_aRenamedFile_isChangedOnlyWhereItWasEdited() async throws {
        try write(["Old.swift": lines(1...30)])
        try commit("start")
        try git("mv", "Old.swift", "New.swift")
        try write(["New.swift": lines(1...30, changing: [7])])

        let selection = try await select(since: "HEAD", changedLines: true)

        XCTAssertEqual(selection.files.map(\.path), ["New.swift"])
        XCTAssertEqual(selection.files.first?.lines, [LineRange(first: 7, last: 7)])
    }

    // A project in a folder of its repository gets its own paths, and nothing from beside it.
    func test_aProjectInAFolder_getsPathsInIt() async throws {
        try write(["App/Sources/A.swift": lines(1...3), "Other/B.swift": lines(1...3)])
        try commit("start")
        try write(["App/Sources/A.swift": lines(1...3, changing: [1]), "Other/B.swift": lines(1...3, changing: [1])])
        try write(["App/Sources/New.swift": "new", "Other/New.swift": "new"])

        let selection = try await select(since: "HEAD", in: url("App"))

        XCTAssertEqual(selection.files.map(\.path), ["Sources/A.swift", "Sources/New.swift"])
    }

    func test_nonSwiftChanges_chooseNothing() async throws {
        try write(["A.swift": "a", "README.md": "readme"])
        try commit("start")
        try write(["README.md": "changed"])

        let selection = try await select(since: "HEAD")

        XCTAssertEqual(selection.files, [])
    }

    func test_aRefGitDoesntKnow_isRefused() async throws {
        try write(["A.swift": "a"])
        try commit("start")

        let result = await GitChanges.select(since: "nonexistent", changedLines: false, in: url(""))

        XCTAssertEqual(result, .failure(.unknownRef("nonexistent")))
    }

    func test_aRepositoryWithoutCommits_isRefused() async throws {
        let result = await GitChanges.select(since: "main", changedLines: false, in: url(""))

        XCTAssertEqual(result, .failure(.noCommits))
    }

    func test_unrelatedHistories_haveNoMergeBase() async throws {
        try write(["A.swift": "a"])
        try commit("start")
        try git("checkout", "-q", "--orphan", "other")
        try write(["A.swift": "other"])
        try commit("other")

        let result = await GitChanges.select(since: "main", changedLines: false, in: url(""))

        XCTAssertEqual(result, .failure(.noMergeBase(ref: "main")))
    }

    func test_aFolderOutsideAnyRepository_isRefused() async throws {
        let folder = try makeTemporaryDirectory()

        let result = await GitChanges.select(since: "main", changedLines: false, in: URL(fileURLWithPath: folder))

        XCTAssertEqual(result, .failure(.notARepository(project: folder)))
    }

    // Its markers wouldn't build, and git compares it as an ordinary change.
    // Outside a repository is one failure that exits 128; a repository another user owns is another, which git
    // explains.
    func test_onlyNotBeingInARepository_readsAsSuch() async throws {
        let project = URL(fileURLWithPath: "/project")
        func select(_ errors: String) async -> Result<ChangeSelection, ChangeSelectionError> {
            await GitChanges.select(since: "main", changedLines: false, in: project) { _, _ in
                CommandResult(status: 128, endedBySignal: false, output: "", errors: errors)
            }
        }

        let outside = await select("fatal: not a git repository (or any of the parent directories): .git\n")
        XCTAssertEqual(outside, .failure(.notARepository(project: "/project")))
        let owned = await select("fatal: detected dubious ownership in repository at '/project'\n")
        XCTAssertEqual(owned, .failure(.gitFailed(
            arguments: ["rev-parse", "--is-inside-work-tree"],
            errors: "fatal: detected dubious ownership in repository at '/project'\n"
        )))
    }

    // GIT_DIFF_OPTS would add context lines to the -U0 diff, which would read as changed.
    func test_gitDiffOpts_isLeftOutOfGitsEnvironment() {
        let environment = GitFileListing.environment(["GIT_DIFF_OPTS": "--unified=3", "HOME": "/Users/me"])

        XCTAssertNil(environment["GIT_DIFF_OPTS"])
        XCTAssertEqual(environment["HOME"], "/Users/me")
    }

    func test_aFileWithMergeConflicts_isRefused() async throws {
        try write(["A.swift": lines(1...3)])
        try commit("start")
        try git("checkout", "-q", "-b", "other")
        try write(["A.swift": lines(1...3, changing: [2])])
        try commit("other")
        try git("checkout", "-q", "main")
        try write(["A.swift": "line 1\nline 2 on main\nline 3\n"])
        try commit("main")
        _ = try? run(
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "merge", "-q", "--no-ff", "other"],
            expecting: 1
        )

        let result = await GitChanges.select(since: "HEAD", changedLines: false, in: url(""))

        XCTAssertEqual(result, .failure(.unmerged(paths: ["A.swift"])))
    }

    // git gives a file renamed only in case, without `git mv`, its old name; discovery lists the disk's.
    func test_aFileRenamedOnlyInCase_isChosenByItsNameOnDisk() async throws {
        try write(["Sources/Parser.swift": lines(1...3)])
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url("Sources/PARSER.swift").path),
            "on a disk that tells names apart by case, git sees a removed file and a new one"
        )
        try commit("start")
        try FileManager.default.moveItem(at: url("Sources/Parser.swift"), to: url("Sources/parser.swift"))
        try write(["Sources/parser.swift": lines(1...3, changing: [2])])

        let selection = try await select(since: "HEAD", changedLines: true)

        XCTAssertEqual(selection.files.map(\.path), ["Sources/parser.swift"])
        XCTAssertEqual(selection.files.first?.lines, [LineRange(first: 2, last: 2)])
    }

    // An untracked repository in the project, as a local package checked out there can be, isn't this one's to compare.
    func test_aRepositoryOfItsOwn_isNamed_andNoneOfItsFilesChosen() async throws {
        try write(["A.swift": "a"])
        try commit("start")
        try write(["LocalPackage/Sources/L.swift": "l"])
        try run(["-C", url("LocalPackage").path, "init", "-q"], expecting: 0)

        let selection = try await select(since: "HEAD")

        XCTAssertEqual(selection.files, [])
        XCTAssertEqual(selection.foldersNotCompared, ["LocalPackage"])
    }

    // Not git's to compare: it holds a path, not the code it leads to.
    func test_aSymbolicLink_isNotChosen() async throws {
        try write(["A.swift": "a"])
        try commit("start")
        try FileManager.default.createSymbolicLink(atPath: url("L.swift").path, withDestinationPath: "A.swift")

        let selection = try await select(since: "HEAD")

        XCTAssertEqual(selection.files, [])
    }
}

private extension GitChangesTests {
    func select(
        since ref: String,
        changedLines: Bool = false,
        in project: URL? = nil
    ) async throws -> ChangeSelection {
        try await GitChanges.select(since: ref, changedLines: changedLines, in: project ?? url("")).get()
    }

    func url(_ path: String) -> URL {
        URL(fileURLWithPath: repository).appendingPathComponent(path)
    }

    /// "line 1\n" to "line n\n", with each line in `changing` changed and each in `removing` left out.
    func lines(_ numbers: ClosedRange<Int>, changing: Set<Int> = [], removing: Set<Int> = []) -> String {
        numbers.filter { !removing.contains($0) }
            .map { changing.contains($0) ? "line \($0) changed\n" : "line \($0)\n" }
            .joined()
    }

    func write(_ files: [String: String]) throws {
        for (path, contents) in files {
            let file = url(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    func commit(_ message: String) throws {
        try git("add", "-A")
        try run([
            "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
            "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", message,
        ])
    }

    func git(_ arguments: String...) throws {
        _ = try run(arguments)
    }

    func output(_ arguments: String...) throws -> String {
        try run(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func run(_ arguments: [String], expecting status: Int32 = 0) throws -> String {
        let git = Foundation.Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", repository] + arguments
        // None of the user's or the system's settings, hooks or templates in the fixtures' setup.
        var environment = GitFileListing.environment(ProcessInfo.processInfo.environment)
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        git.environment = environment
        let output = Pipe()
        git.standardOutput = output
        git.standardError = FileHandle.nullDevice
        try git.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, status, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }
}
