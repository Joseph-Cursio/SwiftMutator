@testable import muterCore
import XCTest

/// Real folders for the copy, in place of a project copied.
final class TurnOffSwiftLintPhasesTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = TurnOffSwiftLintPhases()
    private var copy = ""
    private let script = """
    // !$*UTF8*$!
    {
    \tobjects = {
    \t\tAAA1 = {
    \t\t\tisa = PBXShellScriptBuildPhase;
    \t\t\tname = "Run SwiftLint";
    \t\t\tshellScript = "swiftlint\\n";
    \t\t};
    \t};
    }

    """

    override func setUpWithError() throws {
        try super.setUpWithError()
        copy = try makeTemporaryDirectory()
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: copy)
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        // A package's own project, in a checkout SwiftPM made, isn't built, and neither is what is in DerivedData.
        try write(script, to: "App/App.xcodeproj/project.pbxproj")
        try write(script, to: ".build/checkouts/Yams/Yams.xcodeproj/project.pbxproj")
        try write(script, to: "DerivedData/Old.xcodeproj/project.pbxproj")
    }

    func test_turnsSwiftLintOff_inTheCopysProjects_andSaysWhere() async throws {
        var sent: SwiftLintPhases?
        let token = runEvents.observe(.swiftLintPhasesTurnedOff) { sent = $0.object as? SwiftLintPhases }
        defer { token.cancel() }

        let changes = try await sut.run(with: state)

        XCTAssertEqual(changes, [])
        XCTAssertEqual(try read("App/App.xcodeproj/project.pbxproj"), script.replacingOccurrences(
            of: #""swiftlint\n""#, with: #"": swiftlint\n""#
        ))
        XCTAssertEqual(try read(".build/checkouts/Yams/Yams.xcodeproj/project.pbxproj"), script)
        XCTAssertEqual(try read("DerivedData/Old.xcodeproj/project.pbxproj"), script)
        XCTAssertEqual(sent, SwiftLintPhases(turnedOff: [
            .init(project: "App/App.xcodeproj", name: "Run SwiftLint", targets: []),
        ]))
    }

    // Never the project's own file, even through a link the copy holds to it.
    func test_aLinkToAFileOutsideTheCopy_isReplaced_notWrittenThrough() async throws {
        let outside = try makeTemporaryDirectory() + "/project.pbxproj"
        try Data(script.utf8).write(to: URL(fileURLWithPath: outside))
        try FileManager.default.createDirectory(
            atPath: copy + "/Linked.xcodeproj", withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: copy + "/Linked.xcodeproj/project.pbxproj", withDestinationPath: outside
        )

        _ = try await sut.run(with: state)

        XCTAssertEqual(try String(contentsOfFile: outside, encoding: .utf8), script)
        XCTAssertEqual(try read("Linked.xcodeproj/project.pbxproj"), script.replacingOccurrences(
            of: #""swiftlint\n""#, with: #"": swiftlint\n""#
        ))
    }

    // An atomic write puts a new file in the old one's place, which needs only the folder to be writable.
    func test_aReadOnlyProjectFile_isTurnedOffAllTheSame() async throws {
        let path = copy + "/App/App.xcodeproj/project.pbxproj"
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)

        _ = try await sut.run(with: state)

        XCTAssertEqual(try read("App/App.xcodeproj/project.pbxproj"), script.replacingOccurrences(
            of: #""swiftlint\n""#, with: #"": swiftlint\n""#
        ))
    }

    func test_aProjectFileThatCantBeWritten_isSaid_andNotSaidToBeTurnedOff() async throws {
        let folder = copy + "/App/App.xcodeproj"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        var sent: SwiftLintPhases?
        let token = runEvents.observe(.swiftLintPhasesTurnedOff) { sent = $0.object as? SwiftLintPhases }
        defer { token.cancel() }

        _ = try await sut.run(with: state)

        XCTAssertEqual(try read("App/App.xcodeproj/project.pbxproj"), script)
        XCTAssertEqual(sent, SwiftLintPhases(unreadProjects: ["App/App.xcodeproj"]))
    }

    func test_keepSwiftLintPhases_keepsThem() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild", arguments: ["test"], keepSwiftLintPhases: true
        )
        var sent = false
        let token = runEvents.observe(.swiftLintPhasesTurnedOff) { _ in sent = true }
        defer { token.cancel() }

        _ = try await sut.run(with: state)

        XCTAssertEqual(try read("App/App.xcodeproj/project.pbxproj"), script)
        XCTAssertFalse(sent)
    }

    // A SwiftPM build has no build phases, even where the project has an Xcode project beside its package.
    func test_aSwiftPMRun_leavesThemAlone() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])

        _ = try await sut.run(with: state)

        XCTAssertEqual(try read("App/App.xcodeproj/project.pbxproj"), script)
    }

    private func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: copy).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: copy).appendingPathComponent(path), encoding: .utf8)
    }
}
