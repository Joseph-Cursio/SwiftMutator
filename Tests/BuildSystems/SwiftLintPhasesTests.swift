@testable import muterCore
import XCTest

final class SwiftLintPhasesTests: XCTestCase {
    /// A shell script build phase: its identifier, the `name` entry it has if any, its shell, and its script as
    /// written.
    private struct Phase {
        let id: String
        let name: String
        let shell: String
        let script: String

        init(_ id: String, _ name: String, _ shell: String, _ script: String) {
            self.id = id
            self.name = name
            self.shell = shell
            self.script = script
        }
    }

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
            Phase("AAA1", named, "/bin/sh", #""\"${PODS_ROOT}/SwiftLint/swiftlint\" lint --strict\n""#),
            Phase("AAA2", "", "/bin/zsh", ifWhich),
            Phase("AAA3", "name = Generate;\n\t\t\t", "/bin/sh", #""swiftgen config run\n""#),
        ])
        let expected = project(phases: [
            Phase("AAA1", named, "/bin/sh", #"": \"${PODS_ROOT}/SwiftLint/swiftlint\" lint --strict\n""#),
            Phase("AAA2", "", "/bin/zsh", ifWhichTurnedOff),
            Phase("AAA3", "name = Generate;\n\t\t\t", "/bin/sh", #""swiftgen config run\n""#),
        ])

        let (bytes, phases) = SwiftLintPhases.turningOff(in: Array(file.utf8), project: "App.xcodeproj")

        // Before the escaped quote that starts the command, as the shell reads it: `: "${PODS_ROOT}/…/swiftlint"`.
        XCTAssertEqual(String(lossyUTF8: bytes), expected)
        XCTAssertEqual(phases, SwiftLintPhases(turnedOff: [
            .init(project: "App.xcodeproj", name: "Run SwiftLint", targets: ["App", "AppTests"]),
            .init(project: "App.xcodeproj", name: "Run Script", targets: ["App"]),
        ]))
    }

    // A second pass finds the commands turned off, and changes nothing.
    func test_turningOffTwice_changesNothingTheSecondTime() {
        let file = Array(project(phases: [Phase("AAA1", "", "/bin/sh", ifWhich)]).utf8)

        let once = SwiftLintPhases.turningOff(in: file, project: "App.xcodeproj")
        let twice = SwiftLintPhases.turningOff(in: once.bytes, project: "App.xcodeproj")

        XCTAssertNotEqual(once.bytes, file)
        XCTAssertEqual(once.phases.turnedOff.count, 1)
        XCTAssertEqual(twice.bytes, once.bytes)
        XCTAssertEqual(twice.phases, SwiftLintPhases())
    }

    // A phase the project itself wrote with SwiftLint off is said neither to be turned off here, where
    // `keepSwiftLintPhases` would keep it running, nor to be one SwiftLint may still run in.
    func test_aPhaseWhoseCommandsAreAllOffAlready_isntSaid() {
        let file = Array(project(phases: [Phase("AAA1", "", "/bin/sh", #""which swiftlint && : swiftlint\n""#)]).utf8)

        let (bytes, phases) = SwiftLintPhases.turningOff(in: file, project: "App.xcodeproj")

        XCTAssertEqual(bytes, file)
        XCTAssertEqual(phases, SwiftLintPhases())
    }

    // Another command that runs SwiftLint some other way, as through a variable, can't be told from one that only
    // names it: the phase is said to be turned off, as one of its commands is.
    func test_aPhaseWithACommandTurnedOff_andOneThatRunsSwiftLintThroughAVariable_isSaidToBeTurnedOff() {
        let file = project(phases: [Phase("AAA1", "", "/bin/sh", #""swiftlint autocorrect\n\"$SWIFTLINT\" lint\n""#)])

        let (bytes, phases) = SwiftLintPhases.turningOff(in: Array(file.utf8), project: "App.xcodeproj")

        XCTAssertEqual(
            String(lossyUTF8: bytes),
            project(phases: [Phase("AAA1", "", "/bin/sh", #"": swiftlint autocorrect\n\"$SWIFTLINT\" lint\n""#)])
        )
        XCTAssertEqual(phases, SwiftLintPhases(turnedOff: [
            .init(project: "App.xcodeproj", name: "Run Script", targets: ["App", "AppTests"]),
        ]))
    }

    // Xcode writes a script without quotes when it needs none. Changed, it needs them.
    func test_aScriptWrittenWithoutQuotes_isQuotedOnceChanged() {
        let file = project(phases: [Phase("AAA1", "", "/bin/sh", "swiftlint")])

        let (bytes, phases) = SwiftLintPhases.turningOff(in: Array(file.utf8), project: "App.xcodeproj")

        XCTAssertEqual(
            String(lossyUTF8: bytes),
            project(phases: [Phase("AAA1", "", "/bin/sh", "\": swiftlint\"")])
        )
        XCTAssertEqual(phases.turnedOff.count, 1)
    }

    // A `\U` escape, or a character outside ASCII written as it is, takes more bytes in the file than in the script:
    // the `: ` still goes where the command starts in the file.
    func test_escapesBeforeTheCommand_dontMoveWhereItsTurnedOff() {
        let file = project(phases: [Phase("AAA1", "", "/bin/sh", #""echo \"\U2014 lint —\"\n\tswiftlint\n""#)])

        let (bytes, _) = SwiftLintPhases.turningOff(in: Array(file.utf8), project: "App.xcodeproj")

        XCTAssertEqual(
            String(lossyUTF8: bytes),
            project(phases: [Phase("AAA1", "", "/bin/sh", #""echo \"\U2014 lint —\"\n\t: swiftlint\n""#)])
        )
    }

    // `:` isn't a command of every interpreter, and a script that runs SwiftLint some other way can't be turned off:
    // each phase that names it is said, as it may still run.
    func test_aPhaseThatNamesSwiftLint_inNoCommandItCanTurnOff_isLeftRunning() {
        let file = project(phases: [
            Phase("AAA1", "name = Lint;\n\t\t\t", "/usr/bin/python3", #""import os\nos.system(\"swiftlint\")\n""#),
            Phase("AAA2", "", "/bin/sh", #""\"${SRCROOT}/scripts/swiftlint.sh\"\n""#),
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

        let turnedOff = SwiftLintPhases.turningOff(in: xml, project: "App.xcodeproj")
        let unnamed = SwiftLintPhases.turningOff(in: Array("<?xml version=\"1.0\"?>".utf8), project: "App.xcodeproj")

        XCTAssertEqual(turnedOff.bytes, xml)
        XCTAssertEqual(turnedOff.phases, SwiftLintPhases(unreadProjects: ["App.xcodeproj"]))
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
    private func project(phases: [Phase]) -> String {
        let objects = phases.map(shellScriptObject)
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

    /// The `PBXShellScriptBuildPhase` entry of `phase`.
    private func shellScriptObject(_ phase: Phase) -> String {
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
}
