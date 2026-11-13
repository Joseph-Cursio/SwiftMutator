@testable import muterCore
import XCTest

final class SwiftLintCommandsTests: XCTestCase {
    /// Scripts that run SwiftLint, each with how it reads turned off.
    private let scriptsAndTurnedOff: [(script: String, turnedOff: String)] = [
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
        ("xcrun swiftlint", ": xcrun swiftlint"),
        ("env swiftlint", ": env swiftlint"),
        ("command swiftlint", ": command swiftlint"),
        ("nice -n 10 swiftlint", ": nice -n 10 swiftlint"),
        ("nohup swiftlint", ": nohup swiftlint"),
        ("arch -arm64 swiftlint", ": arch -arm64 swiftlint"),
        ("mise x -- swiftlint", ": mise x -- swiftlint"),
        // Inside a function, which the script then calls by its name.
        (
            "swiftlint() { \"$PODS_ROOT/SwiftLint/swiftlint\" \"$@\"; }\nswiftlint lint",
            "swiftlint() { : \"$PODS_ROOT/SwiftLint/swiftlint\" \"$@\"; }\n: swiftlint lint"
        ),
        // In a `case` item, after its patterns, which may name SwiftLint too.
        (
            "case \"$1\" in\n  swiftlint|lint) swiftlint lint;;\n  (*) exit 1 ;;\nesac\nswiftlint",
            "case \"$1\" in\n  swiftlint|lint) : swiftlint lint;;\n  (*) exit 1 ;;\nesac\n: swiftlint"
        ),
        ("case $x in a) swiftlint ;& b) swiftlint ;; esac", "case $x in a) : swiftlint ;& b) : swiftlint ;; esac"),
        ("diff <(swiftlint) expected.txt", "diff <(: swiftlint) expected.txt"),
    ]

    // Each command that runs SwiftLint gets `: ` before it, and nothing else in the script changes, so an `if which`
    // guard, its echo and any other tool still run.
    func test_eachCommandThatRunsSwiftLint_isTurnedOff() {
        for (script, turnedOff) in scriptsAndTurnedOff {
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
            "command -V swiftlint",
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

    // A function's name, and a `case` pattern, look like a command but run nothing, and a `: ` before either is a
    // syntax error, which would fail every build of the copy.
    func test_aFunctionsNameOrACasePattern_isLeftAsItIs() {
        let scripts = [
            "swiftlint() { echo; }",
            "swiftlint () {\n  echo\n}",
            "function swiftlint() { echo; }",
            "case \"$1\" in\n  swiftlint) echo a ;;\nesac",
            "case \"$1\" in\n  (swiftlint) echo a ;;\n  lint | swiftlint) echo b ;;\nesac",
            "case $x\nin swiftlint) echo ;; esac",
            "case $x in a) case $y in swiftlint) echo ;; esac ;; swiftlint) echo ;; esac",
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
        return String(lossyUTF8: bytes)
    }
}
