@testable import muterCore
import XCTest

final class SwiftLintCommandsTests: XCTestCase {
    // Each command that runs SwiftLint gets `: ` before it, and nothing else in the script changes, so an `if which`
    // guard, its echo and any other tool still run.
    func test_eachCommandThatRunsSwiftLint_isTurnedOff() {
        let cases: [(script: String, turnedOff: String)] = [
            ("swiftlint\n", ": swiftlint\n"),
            ("  swiftlint lint --strict", "  : swiftlint lint --strict"),
            (#""${PODS_ROOT}/SwiftLint/swiftlint""#, #": "${PODS_ROOT}/SwiftLint/swiftlint""#),
            ("/opt/homebrew/bin/swiftlint", ": /opt/homebrew/bin/swiftlint"),
            (#""$SRCROOT/swiftlint" lint --strict"#, #": "$SRCROOT/swiftlint" lint --strict"#),
            (
                "if which swiftlint >/dev/null; then\n  swiftlint\nelse\n  echo \"warning: no SwiftLint\"\nfi\n",
                "if which swiftlint >/dev/null; then\n  : swiftlint\nelse\n  echo \"warning: no SwiftLint\"\nfi\n"
            ),
            (
                "if command -v swiftlint >/dev/null 2>&1; then swiftlint lint; fi",
                "if command -v swiftlint >/dev/null 2>&1; then : swiftlint lint; fi"
            ),
            ("which swiftlint && swiftlint lint", "which swiftlint && : swiftlint lint"),
            ("cd \"$SRCROOT\"; swiftlint | tee lint.txt", "cd \"$SRCROOT\"; : swiftlint | tee lint.txt"),
            ("swiftlint lint 2>&1 | xcpretty", ": swiftlint lint 2>&1 | xcpretty"),
            ("(cd App && swiftlint)", "(cd App && : swiftlint)"),
            ("for f in a b; do swiftlint lint \"$f\"; done", "for f in a b; do : swiftlint lint \"$f\"; done"),
            ("swiftlint lint \\\n  --strict\nswiftformat .", ": swiftlint lint \\\n  --strict\nswiftformat ."),
            // A failure the script checks for reads as a pass.
            ("if ! swiftlint; then exit 1; fi", "if ! : swiftlint; then exit 1; fi"),
            (#"PATH="$PATH:/opt/homebrew/bin" swiftlint"#, #": PATH="$PATH:/opt/homebrew/bin" swiftlint"#),
            ("SwiftLint lint", ": SwiftLint lint"),
            ("mint run swiftlint", ": mint run swiftlint"),
            ("mint run realm/SwiftLint@0.57.0 lint", ": mint run realm/SwiftLint@0.57.0 lint"),
            ("xcrun --sdk macosx swiftlint", ": xcrun --sdk macosx swiftlint"),
            ("swift run --package-path BuildTools swiftlint", ": swift run --package-path BuildTools swiftlint"),
            ("mise exec swiftlint@0.57 -- swiftlint lint", ": mise exec swiftlint@0.57 -- swiftlint lint"),
            ("/usr/bin/env -u CI swiftlint", ": /usr/bin/env -u CI swiftlint"),
            ("exec swiftlint", ": exec swiftlint"),
            ("time swiftlint", "time : swiftlint"),
        ]

        for (script, turnedOff) in cases {
            XCTAssertEqual(turningOff(script), turnedOff, script)
        }
    }

    // A word that only names SwiftLint, or looks it up, runs nothing; nor is a command whose name a variable or another
    // command gives known to be SwiftLint.
    func test_aCommandThatDoesntRunSwiftLint_isLeftAsItIs() {
        let scripts = [
            "echo \"warning: SwiftLint not installed, download from https://github.com/realm/SwiftLint\"",
            "which swiftlint",
            "command -v swiftlint",
            "xcrun -f swiftlint",
            "swiftformat --lint .",
            "# swiftlint\n",
            "echo hi # then swiftlint",
            "cp swiftlint /tmp/swiftlint",
            "\"$(which swiftlint)\" lint",
            "$SWIFTLINT lint",
            "\"${SRCROOT}/scripts/swiftlint.sh\"",
            "swiftlint.yml",
            "mint bootstrap swiftlint",
            "swift build --product swiftlint",
        ]

        for script in scripts {
            XCTAssertEqual(SwiftLintCommands.find(in: Array(script.utf8)), SwiftLintCommands.Found(), script)
        }
    }

    // So a copy that already has SwiftLint off, as one whose turning off was interrupted, is never changed twice.
    func test_aCommandAlreadyTurnedOff_isCountedAndLeftAsItIs() {
        let script = "if which swiftlint; then\n  : swiftlint\nfi\n: mint run swiftlint"

        let found = SwiftLintCommands.find(in: Array(script.utf8))

        XCTAssertEqual(found, SwiftLintCommands.Found(running: [], turnedOff: 2))
    }

    private func turningOff(_ script: String) -> String {
        var bytes = Array(script.utf8)
        for start in SwiftLintCommands.find(in: bytes).running.reversed() {
            bytes.insert(contentsOf: SwiftLintCommands.prefix.utf8, at: start)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

final class SwiftLintPhasesTests: XCTestCase {
    // SwiftProjectLint's own phase, as Xcode wrote it, which runs SwiftLint by its full path.
    private let ifWhich = #""if which /opt/homebrew/bin/swiftlint >/dev/null; then\n  /opt/homebrew/bin/swiftlint\n"#
        + #"else\n  echo \"warning: SwiftLint not installed. Download from https://github.com/realm/SwiftLint\"\nfi\n""#
    private let ifWhichTurnedOff = #""if which /opt/homebrew/bin/swiftlint >/dev/null; then\n"#
        + #"  : /opt/homebrew/bin/swiftlint\n"#
        + #"else\n  echo \"warning: SwiftLint not installed. Download from https://github.com/realm/SwiftLint\"\nfi\n""#
    private let named = "name = \"Run SwiftLint\";\n\t\t\t"

    // Only the commands change: the rest of the file, its comments and spacing included, is the same bytes. The names
    // of the phases and their targets are found, and an unnamed phase is Xcode's "Run Script".
    func test_turnsOffEachSwiftLintCommand_andLeavesEveryOtherByteAsItWas() {
        let file = project(phases: [
            ("AAA1", named, "/bin/sh", #""\"${PODS_ROOT}/SwiftLint/swiftlint\" lint --strict\n""#),
            ("AAA2", "", "/bin/zsh", ifWhich),
            ("AAA3", "name = Generate;\n\t\t\t", "/bin/sh", #""swiftgen config run\n""#),
        ])
        let expected = project(phases: [
            ("AAA1", named, "/bin/sh", #"": \"${PODS_ROOT}/SwiftLint/swiftlint\" lint --strict\n""#),
            ("AAA2", "", "/bin/zsh", ifWhichTurnedOff),
            ("AAA3", "name = Generate;\n\t\t\t", "/bin/sh", #""swiftgen config run\n""#),
        ])

        let (bytes, phases) = SwiftLintPhases.turningOff(in: Array(file.utf8), project: "App.xcodeproj")

        // Before the escaped quote that starts the command, as the shell reads it: `: "${PODS_ROOT}/…/swiftlint"`.
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), expected)
        XCTAssertEqual(phases, SwiftLintPhases(turnedOff: [
            .init(project: "App.xcodeproj", name: "Run SwiftLint", targets: ["App", "AppTests"]),
            .init(project: "App.xcodeproj", name: "Run Script", targets: ["App"]),
        ]))
    }

    // A second pass finds the commands turned off, and changes nothing.
    func test_turningOffTwice_changesNothingTheSecondTime() {
        let file = Array(project(phases: [("AAA1", "", "/bin/sh", ifWhich)]).utf8)

        let once = SwiftLintPhases.turningOff(in: file, project: "App.xcodeproj")
        let twice = SwiftLintPhases.turningOff(in: once.bytes, project: "App.xcodeproj")

        XCTAssertNotEqual(once.bytes, file)
        XCTAssertEqual(twice.bytes, once.bytes)
        XCTAssertEqual(twice.phases, once.phases)
    }

    // Xcode writes a script without quotes when it needs none. Changed, it needs them.
    func test_aScriptWrittenWithoutQuotes_isQuotedOnceChanged() {
        let file = project(phases: [("AAA1", "", "/bin/sh", "swiftlint")])

        let (bytes, phases) = SwiftLintPhases.turningOff(in: Array(file.utf8), project: "App.xcodeproj")

        XCTAssertEqual(
            String(decoding: bytes, as: UTF8.self),
            project(phases: [("AAA1", "", "/bin/sh", "\": swiftlint\"")])
        )
        XCTAssertEqual(phases.turnedOff.count, 1)
    }

    // A `\U` escape, or a character outside ASCII written as it is, takes more bytes in the file than in the script:
    // the `: ` still goes where the command starts in the file.
    func test_escapesBeforeTheCommand_dontMoveWhereItsTurnedOff() {
        let file = project(phases: [("AAA1", "", "/bin/sh", #""echo \"\U2014 lint —\"\n\tswiftlint\n""#)])

        let (bytes, _) = SwiftLintPhases.turningOff(in: Array(file.utf8), project: "App.xcodeproj")

        XCTAssertEqual(
            String(decoding: bytes, as: UTF8.self),
            project(phases: [("AAA1", "", "/bin/sh", #""echo \"\U2014 lint —\"\n\t: swiftlint\n""#)])
        )
    }

    // `:` isn't a command of every interpreter, and a script that runs SwiftLint some other way can't be turned off:
    // each phase that names it is said, as it may still run.
    func test_aPhaseThatNamesSwiftLint_inNoCommandItCanTurnOff_isLeftRunning() {
        let file = project(phases: [
            ("AAA1", "name = Lint;\n\t\t\t", "/usr/bin/python3", #""import os\nos.system(\"swiftlint\")\n""#),
            ("AAA2", "", "/bin/sh", #""\"${SRCROOT}/scripts/swiftlint.sh\"\n""#),
        ])

        let (bytes, phases) = SwiftLintPhases.turningOff(in: Array(file.utf8), project: "App.xcodeproj")

        XCTAssertEqual(bytes, Array(file.utf8))
        XCTAssertEqual(phases, SwiftLintPhases(leftRunning: [
            .init(project: "App.xcodeproj", name: "Lint", targets: ["App", "AppTests"]),
            .init(project: "App.xcodeproj", name: "Run Script", targets: ["App"]),
        ]))
    }

    func test_aFileThatIsntAnOldStylePropertyList_isLeftAsItIs_andSaidWhenItNamesSwiftLint() {
        let xml = Array("<?xml version=\"1.0\"?><plist><string>swiftlint</string></plist>".utf8)

        let named = SwiftLintPhases.turningOff(in: xml, project: "App.xcodeproj")
        let unnamed = SwiftLintPhases.turningOff(in: Array("<?xml version=\"1.0\"?>".utf8), project: "App.xcodeproj")

        XCTAssertEqual(named.bytes, xml)
        XCTAssertEqual(named.phases, SwiftLintPhases(unreadProjects: ["App.xcodeproj"]))
        XCTAssertTrue(unnamed.phases.isEmpty)
    }

    func test_isProjectFile() {
        XCTAssertTrue(SwiftLintPhases.isProjectFile("App.xcodeproj/project.pbxproj"))
        XCTAssertTrue(SwiftLintPhases.isProjectFile("Apps/App.xcodeproj/project.pbxproj"))
        XCTAssertFalse(SwiftLintPhases.isProjectFile("project.pbxproj"))
        XCTAssertFalse(SwiftLintPhases.isProjectFile("App/project.pbxproj"))
    }

    /// A project file as Xcode writes it, with an `App` target that builds with each of `phases`, given by its
    /// identifier, the `name` entry it has if any, its shell, and its script as written, and an `AppTests` target that
    /// builds with the first.
    private func project(phases: [(id: String, name: String, shell: String, script: String)]) -> String {
        let objects = phases.map { phase in
            """
            \t\t\(phase.id) /* ShellScript */ = {
            \t\t\tisa = PBXShellScriptBuildPhase;
            \t\t\tbuildActionMask = 2147483647;
            \t\t\tfiles = (
            \t\t\t);
            \t\t\t\(phase.name)inputPaths = (
            \t\t\t);
            \t\t\toutputPaths = (
            \t\t\t);
            \t\t\trunOnlyForDeploymentPostprocessing = 0;
            \t\t\tshellPath = \(phase.shell);
            \t\t\tshellScript = \(phase.script);
            \t\t};
            """
        }
        let listed = phases.map { "\t\t\t\t\($0.id) /* ShellScript */," }.joined(separator: "\n")
        return """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 77;
        \tobjects = {

        /* Begin PBXNativeTarget section */
        \t\tBBB1 /* App */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildPhases = (
        \(listed)
        \t\t\t);
        \t\t\tname = App;
        \t\t\tproductName = App;
        \t\t};
        \t\tBBB2 /* AppTests */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildPhases = (
        \t\t\t\t\(phases.first?.id ?? "") /* ShellScript */
        \t\t\t);
        \t\t\tname = "AppTests";
        \t\t};
        /* End PBXNativeTarget section */

        /* Begin PBXShellScriptBuildPhase section */
        \(objects.joined(separator: "\n"))
        /* End PBXShellScriptBuildPhase section */
        \t};
        \trootObject = CCC1 /* Project object */;
        }

        """
    }
}

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
