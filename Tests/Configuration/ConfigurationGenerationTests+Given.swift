@testable import muterCore
import XCTest

/// #262: a run with no configuration file takes the workspace or project, scheme and destinations its flags give in
/// place of what it would work out.
extension ConfigurationGenerationTests {
    // A given scheme and destination are never looked for, so xcodebuild only runs for `which`, and the scheme is no
    // guess to warn of.
    func test_aGivenSchemeAndDestinations_areTaken_withoutLookingForThem() async throws {
        process.stdoutToBeReturned = which("xcodebuild")

        let generated = try await MuterConfiguration.generated(
            from: ["CocoaApp.xcodeproj"],
            in: xcodeProjectFiles,
            choosing: XcodebuildChoice(scheme: "Other", destinations: ["platform=macOS", "id=2"])
        )

        XCTAssertEqual(generated.configuration.testCommandArguments, [
            "-project", "CocoaApp.xcodeproj", "-scheme", "Other", "-destination", "platform=macOS",
            "-destination", "id=2", "test",
        ])
        XCTAssertEqual(process.processesRun, [["/usr/bin/which", "xcodebuild"]])
        XCTAssertEqual(generated.scheme?.chosen, "Other")
        XCTAssertEqual(generated.scheme?.isAGuess, false)
    }

    // A given workspace settles which of several is tested, which is otherwise refused. It is written as given, as
    // the run's merged arguments have it, so the worked-out line names the command that runs.
    func test_aGivenWorkspace_isChosenAmongSeveral() async throws {
        process.stdoutToBeReturned = which("xcodebuild")

        let generated = try await MuterConfiguration.generated(
            from: ["A.xcworkspace", "B.xcworkspace"],
            in: "/some/path",
            choosing: XcodebuildChoice(workspace: "./B.xcworkspace", scheme: "Shop", destinations: ["platform=macOS"])
        )

        XCTAssertEqual(generated.configuration.testCommandArguments, [
            "-workspace", "./B.xcworkspace", "-scheme", "Shop", "-destination", "platform=macOS", "test",
        ])
    }

    // One that isn't at the top of the folder, or isn't of the kind its flag names, is refused before anything runs.
    func test_aGivenWorkspaceOrProject_thatIsntAtTheTop_isRefused() async {
        let cases = [
            (XcodebuildChoice(workspace: "Other.xcworkspace"), "`--workspace Other.xcworkspace` names no Xcode "
                + "workspace"),
            (XcodebuildChoice(project: "Example/Demo.xcodeproj"), "`--project Example/Demo.xcodeproj` names no "
                + "Xcode project"),
            (XcodebuildChoice(project: "A.xcworkspace"), "`--project A.xcworkspace` names no Xcode project"),
        ]
        for (given, start) in cases {
            do {
                _ = try await MuterConfiguration.generated(
                    from: ["A.xcworkspace", "Example/Demo.xcodeproj"],
                    in: "/some/path",
                    choosing: given
                )
                XCTFail("\(given) wasn't refused")
            } catch {
                XCTAssertEqual(
                    "\(error)",
                    "\(start) at the top of the project's folder, where SwiftMutator works out the test command from "
                        + "without muter.conf.yml."
                )
            }
        }
        XCTAssertEqual(process.processesRun, [])
    }
}
