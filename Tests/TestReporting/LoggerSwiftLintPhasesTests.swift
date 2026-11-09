import Foundation
@testable import muterCore
import Rainbow
import XCTest

/// What the logger says of the build phases of the copy whose SwiftLint was turned off.
final class LoggerSwiftLintPhasesTests: MuterTestCase {
    private let sut = Logger()

    // Each phase by its project, name and targets, and the key that keeps them; then what may still run SwiftLint.
    func test_namesEachPhase_andTheKeyThatKeepsThem() {
        sut.swiftLintPhasesTurnedOff(SwiftLintPhases(
            turnedOff: [
                .init(project: "App.xcodeproj", name: "Run SwiftLint", targets: ["App", "AppTests"]),
                .init(project: "Tools/Tools.xcodeproj", name: "Run Script", targets: ["Tool"]),
            ],
            leftRunning: [.init(project: "App.xcodeproj", name: "Lint", targets: [])],
            unreadProjects: ["Old.xcodeproj"]
        ))

        XCTAssertEqual(printer.linesPassed, [
            """
            🔇 Turned SwiftLint off in 2 build phases of the copy, as each mutated file turns its rules off anyway. \
            Only the command that runs it is skipped, so the rest of the script still runs, and a report it writes is \
            left empty:
              App.xcodeproj: Run SwiftLint, in targets App, AppTests
              Tools/Tools.xcodeproj: Run Script, in target Tool
            \("keepSwiftLintPhases: true".bold) keeps it running there.
            ⚠️ 1 build phase of the copy names SwiftLint in no command SwiftMutator could turn off, so it may still \
            run there:
              App.xcodeproj: Lint
            ⚠️ Couldn't read or write Old.xcodeproj in the copy, which names SwiftLint, so its build phases may still \
            run it.
            """,
        ])
    }

    func test_onePhase_isSaidSo() {
        sut.swiftLintPhasesTurnedOff(SwiftLintPhases(turnedOff: [
            .init(project: "App.xcodeproj", name: "Run Script", targets: ["App"]),
        ]))

        let said = printer.linesPassed.first ?? ""
        XCTAssertTrue(said.hasPrefix("🔇 Turned SwiftLint off in 1 build phase of the copy,"), said)
    }
}
