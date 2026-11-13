@testable import muterCore
import XCTest

extension RemovedCallShapesTests {
    /// Some result builders take no `if`: an App's `SceneBuilder` and `RegexBuilder`. A mutant's switch in their
    /// bodies doesn't build, so they get no mutant, their lowercase parts included. In a builder that takes an `if`, a
    /// statement that makes a value of a type, as `ProgressView()` in a `ViewBuilder`'s case does, is a part, and is
    /// never removed (#112).
    func test_theGeneratedCodeBuildsInBuildersThatTakeNoIf() throws {
        #if canImport(SwiftUI) && canImport(RegexBuilder)
        let app = Self.buildersThatTakeNoIfCode
        let compiled = try compileMutated(["App.swift": app])

        let places = [
            "the main window", "a regex component", "a view in a case", "a regex's factory part",
            "a scene a function makes", "a lowercase part of a scene function", "a lowercase regex part",
            "a lowercase part of a regex getter", "a lowercase part of a match", "a scene in a group",
            "a scene in a modified group", "a lowercase part of a regex attribute's getter",
        ]
        for place in places {
            XCTAssertEqual(compiled.operators(in: "App.swift", onTheLineHolding: place), [], place)
        }
        XCTAssertEqual(
            compiled.operators(in: "App.swift", onTheLineHolding: "state > 1"),
            [.ror, .relationalBoundary, .swapTernary]
        )
        #else
        throw XCTSkip("SwiftUI and RegexBuilder are only on Apple's platforms")
        #endif
    }

    private static let buildersThatTakeNoIfCode = """
    import RegexBuilder
    import SwiftUI

    struct Demo: App {
        var body: some Scene {
            WindowGroup { Text("main") } // the main window
            Settings { Text("settings") }
            extraScene() // a scene a function makes
            Group {
                extraScene() // a scene in a group
                note()
            }
            Group {
                extraScene() // a scene in a modified group
                note()
            }
            .defaultSize(width: 400, height: 300)
        }

        @SceneBuilder
        func extraScene() -> some Scene {
            WindowGroup("Extra") { Text("extra") }
            note() // a lowercase part of a scene function
        }

        func note() -> some Scene {
            WindowGroup("Note") { Text("note") }
        }
    }

    @available(macOS 13, *)
    func separator() -> Regex<Substring> {
        Regex {
            ZeroOrMore(.whitespace) // a regex component
            ","
            CharacterClass.anyOf(";|") // a regex's factory part
            spaces() // a lowercase regex part
            ZeroOrMore(.whitespace)
        }
    }

    @available(macOS 13, *)
    func spaces() -> some RegexComponent {
        ZeroOrMore(.whitespace)
    }

    @available(macOS 13, *)
    @RegexComponentBuilder
    var pair: some RegexComponent {
        spaces() // a lowercase part of a regex getter
        ","
    }

    @available(macOS 13, *)
    @RegexComponentBuilder
    var plain: Regex<Substring> {
        spaces() // a lowercase part of a regex attribute's getter
        ","
    }

    @available(macOS 13, *)
    func matches(_ line: String) -> Bool {
        line.wholeMatch {
            spaces() // a lowercase part of a match
            ","
        } != nil
    }

    struct Rows: View {
        var state: Int

        var body: some View {
            VStack {
                Text(state > 1 ? "many" : "one")
                switch state {
                case 0: ProgressView() // a view in a case
                default: Text("done")
                }
            }
        }
    }
    """
}
