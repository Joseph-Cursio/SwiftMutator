@testable import muterCore
import XCTest

extension RunCommandTests {
    // On each command that builds, run-without-mutating too, whose plan records none of them. `--destination` is
    // repeatable, and the paths stay as written, so they are opened in the copy.
    func test_xcodebuildFlags_reachTheRunOptions_ofEachCommandThatBuilds_andTheHelp() throws {
        let flags = [
            "--workspace", "App.xcworkspace", "--scheme", "App", "--destination", "id=1", "--destination", "id=2",
        ]
        let chosen = XcodebuildChoice(workspace: "App.xcworkspace", scheme: "App", destinations: ["id=1", "id=2"])
        let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run"] + flags) as? Run)
        XCTAssertEqual(run.runOptions.xcodebuild, chosen)
        let plan = try MuterCommand.parseAsRoot(["run-without-mutating", "--project", "App.xcodeproj", "plan.json"])
        XCTAssertEqual(
            try XCTUnwrap(plan as? RunWithoutMutating).runOptions.xcodebuild,
            XcodebuildChoice(project: "App.xcodeproj")
        )
        let making = try MuterCommand.parseAsRoot(["mutate-without-running"] + flags)
        XCTAssertEqual(try XCTUnwrap(making as? MutateWithoutRunning).runOptions.xcodebuild, chosen)
        XCTAssertEqual(try XCTUnwrap(MuterCommand.parseAsRoot(["run"]) as? Run).runOptions.xcodebuild, .init())
        let help = Run.helpMessage(columns: 200)
        for line in ["--workspace <path>", "--project <path>", "--scheme <name>", "--destination <specifier>"] {
            XCTAssertTrue(help.contains("\n  \(line)"), help)
        }
    }

    // xcodebuild opens one workspace or project, and a blank value gives it nothing.
    func test_workspaceWithProject_orABlankXcodebuildFlag_isAUsageError() {
        let message = "--workspace and --project can't be given together: xcodebuild opens one of them."
        assertUsageError(["run", "--workspace", "App.xcworkspace", "--project", "App.xcodeproj"], message)
        assertUsageError(
            ["mutate-without-running", "--project", "A.xcodeproj", "--workspace", "A.xcworkspace"], message
        )
        assertUsageError(["run", "--scheme", " "], "--scheme can't be blank.")
        assertUsageError(["run", "--destination", "id=1", "--destination", ""], "--destination can't be blank.")
    }

    func test_runOptionsEquality_coversTheXcodebuildChoice() {
        for choice in [
            XcodebuildChoice(workspace: "A.xcworkspace"), XcodebuildChoice(project: "A.xcodeproj"),
            XcodebuildChoice(scheme: "A"), XcodebuildChoice(destinations: ["id=1"]),
        ] {
            XCTAssertNotEqual(Run.Options.make(xcodebuild: choice), .make())
            XCTAssertEqual(Run.Options.make(xcodebuild: choice), .make(xcodebuild: choice))
        }
        XCTAssertEqual(Run.Options.null.xcodebuild, XcodebuildChoice())
        XCTAssertEqual(XcodebuildChoice(destinations: []), XcodebuildChoice())
    }
}
