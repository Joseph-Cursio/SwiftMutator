import ArgumentParser
@testable import muterCore
import XCTest

/// `--project-folder`: on each command that runs, and `init`, and resolved, as the other paths on the command line are,
/// against the folder the command was given in.
extension RunCommandTests {
    func test_projectFolder_reachesTheRunOptions_ofEachCommandThatRuns_andTheHelp() throws {
        let folder = try makeTemporaryDirectory()
        let given = URL(fileURLWithPath: folder)

        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--project-folder", folder]) as? Run)
        XCTAssertEqual(run.runOptions.projectFolder, given)
        let plan = try MuterCommand.parseAsRoot(["run-without-mutating", "--project-folder", folder, "plan.json"])
        XCTAssertEqual(try XCTUnwrap(plan as? RunWithoutMutating).runOptions.projectFolder, given)
        let making = try MuterCommand.parseAsRoot(["mutate-without-running", "--project-folder", folder])
        XCTAssertEqual(try XCTUnwrap(making as? MutateWithoutRunning).runOptions.projectFolder, given)
        XCTAssertNil(try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions.projectFolder)

        let commands: [ParsableCommand.Type] = [Run.self, RunWithoutMutating.self, MutateWithoutRunning.self, Init.self]
        for command in commands {
            let help = command.helpMessage(columns: 200)
            XCTAssertTrue(help.contains("\n  --project-folder <path>"), help)
        }
    }

    // A relative path, and one with `~`, as `-c`'s and `-o`'s are.
    func test_projectFolder_isResolvedAgainstTheCurrentFolder_andExpandsTheHomeFolder() throws {
        let currentFolder = FileManager.default.currentDirectoryPath
        let upAndBack = "../" + URL(fileURLWithPath: currentFolder).lastPathComponent
        let relative = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--project-folder", upAndBack]) as? Run)
        XCTAssertEqual(
            relative.runOptions.projectFolder?.standardizedFileURL.path,
            URL(fileURLWithPath: currentFolder).standardizedFileURL.path
        )
        let home = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--project-folder", "~"]) as? Run)
        XCTAssertEqual(home.runOptions.projectFolder?.path, URL.expandingTilde("~"))
    }

    func test_aProjectFolderThatIsMissing_orAFile_isAUsageError() throws {
        let folder = try makeTemporaryDirectory()
        let file = "\(folder)/Package.swift"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data()))
        let missing = "\(folder)/Missing"

        for path in [missing, file] {
            let message = "--project-folder must be a folder, and \(path) isn't one."
            assertUsageError(["run", "--project-folder", path], message)
            assertUsageError(["run-without-mutating", "--project-folder", path, "plan.json"], message)
            assertUsageError(["mutate-without-running", "--project-folder", path], message)
            assertUsageError(["init", "--project-folder", path], message)
        }
    }
}
