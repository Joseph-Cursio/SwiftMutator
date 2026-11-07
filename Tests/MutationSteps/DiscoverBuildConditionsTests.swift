@testable import muterCore
import XCTest

final class DiscoverBuildConditionsTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = DiscoverBuildConditions()

    override func setUp() {
        super.setUp()
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project", isDirectory: true)
    }

    func test_aBuildSystemItDoesntKnow_isAskedNothing_andNothingIsSaid() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/make", arguments: ["test"])
        var notices: [String] = []
        let observer = runEvents.observe(.buildConditionsUnavailable) { notices.append($0.object as? String ?? "") }
        defer { observer.cancel() }

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [])
        XCTAssertEqual(process.commandsRun, [])
        XCTAssertEqual(notices, [])
    }

    func test_xcodebuildsSettings_areKept() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: [])
        process.commandResult = { _ in
            CommandResult(
                status: 0,
                endedBySignal: false,
                output: #"[{"buildSettings": {"PLATFORM_NAME": "macosx", "ARCHS": "arm64"}}]"#,
                errors: ""
            )
        }

        let result = try await sut.run(with: state)

        let change = try XCTUnwrap(result.first)
        guard case let .buildConditionsDiscovered(conditions) = change else {
            return XCTFail("Expected conditions, got \(change)")
        }
        XCTAssertEqual(conditions.everyTarget.platform?.system, "macOS")
    }

    func test_whenTheyCantBeHad_itSaysWhy_andTheRunGoesOn() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        var notices: [String] = []
        let observer = runEvents.observe(.buildConditionsUnavailable) { notices.append($0.object as? String ?? "") }
        defer { observer.cancel() }

        let result = try await sut.run(with: state)

        XCTAssertEqual(result, [])
        XCTAssertEqual(notices, ["xcodebuild reported no build settings"])
    }

    func test_itAsksFromTheMutatedProject_andComesBack() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        fileManager.currentDirectoryPathToReturn = "/original"

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.changeCurrentDirectoryPath, ["/project", "/original"])
    }
}
