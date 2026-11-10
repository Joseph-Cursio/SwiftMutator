import Foundation

/// The commands of a shell script that run SwiftLint, found by a reading of the script that is only as close as it
/// needs to be: each simple command, after `then`, `do`, `else`, `&&`, `;`, `|`, a newline and the like, is split into
/// words, with their quotes, escapes and expansions kept whole, and judged by them. A command runs SwiftLint when its
/// first word, past any `NAME=value`, is `swiftlint`, by name or by a path that ends in it, as
/// `"${PODS_ROOT}/SwiftLint/swiftlint"` is, or when a launcher runs it so: `xcrun swiftlint`, `mint run swiftlint` or
/// `mint run realm/SwiftLint`, `swift run swiftlint`, `mise exec -- swiftlint`, `env`, `exec`, `command`, `nice`,
/// `nohup` and `arch`. Nothing else is: not `which swiftlint`, `command -v swiftlint`, an `echo` that names it, a path
/// to it given as an argument, a variable such as `$SWIFTLINT`, or a script that runs it, as `scripts/swiftlint.sh`.
/// Nor is a word that only looks like a command: a function's name, as in `swiftlint() { … }`, or a `case` pattern,
/// as in `swiftlint) …`, where a `: ` before it would be a syntax error that fails every build. Heredocs aren't
/// understood, so a line of one that starts with `swiftlint` is taken for a command, and gets `: ` in its text.
enum SwiftLintCommands {
    struct Found: Equatable {
        /// Where each command that runs SwiftLint starts, in the script's bytes: after any `then` or `!` before it,
        /// and before its `NAME=value` words and launchers.
        var running: [Int] = []
        /// How many commands already have SwiftLint turned off, with `: ` before them, as this leaves them.
        var turnedOff = 0
    }

    /// What turns a command off: `:`, the shell's command that does nothing and succeeds, whatever it is given. So a
    /// script that runs under `set -e`, or that checks SwiftLint's status, goes on as if it had passed.
    static let prefix = ": "

    static func find(in script: [UInt8]) -> Found {
        var scanner = Scanner(script: script)
        var found = Found()
        while let command = scanner.nextCommand() {
            switch kind(of: command.words[...]) {
            case .runsSwiftLint: found.running.append(command.start)
            case .turnedOff: found.turnedOff += 1
            case .other: break
            }
        }
        return found
    }

    enum Kind: Equatable {
        case runsSwiftLint
        case turnedOff
        case other
    }

    /// What the command with `words` does, as `find(in:)` judges it.
    static func kind(of words: ArraySlice<String>) -> Kind {
        let command = words.drop(while: isAssignment)
        guard let first = command.first else { return .other }
        if first == ":" {
            return kind(of: command.dropFirst()) == .runsSwiftLint ? .turnedOff : .other
        }
        if isSwiftLint(first) {
            return .runsSwiftLint
        }
        guard let launcher = Launcher.all[name(of: first)],
              let launched = launcher.command(in: command.dropFirst()) else { return .other }
        return kind(of: launched) == .runsSwiftLint ? .runsSwiftLint : .other
    }

    /// Whether `word` names SwiftLint: `swiftlint`, in any case, or a path that ends in it, or a Mint package, as
    /// `realm/SwiftLint@0.57.0`.
    static func isSwiftLint(_ word: String) -> Bool {
        let name = name(of: word)
        let withoutVersion = name.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return withoutVersion.lowercased() == "swiftlint"
    }

    /// The last part of a path.
    private static func name(of word: String) -> String {
        word.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? word
    }

    /// `NAME=value`, which sets a variable for the command that follows.
    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.first.map { $0 == "_" || $0.isASCII && $0.isLetter } == true
            && name.allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// A command that runs the command its words go on to name.
    struct Launcher {
        /// The words one of which must come first, as `run` for `mint`; empty for none.
        var subcommands: Set<String> = []
        /// The options that take the next word as their value.
        var optionsWithValues: Set<String> = []
        /// The options that make it look a command up rather than run it, as `command -v`.
        var lookups: Set<String> = []
        /// Whether its own words end at `--`, as `mise exec`'s tools do, rather than at its first word that isn't an
        /// option.
        var endsAtDoubleDash = false

        static let all: [String: Self] = [
            "xcrun": Self(
                optionsWithValues: ["--sdk", "-sdk", "--toolchain", "-toolchain"],
                lookups: ["-f", "--find"]
            ),
            "mint": Self(subcommands: ["run"], optionsWithValues: ["-m", "--mintfile"]),
            "swift": Self(
                subcommands: ["run"],
                optionsWithValues: [
                    "--package-path", "-c", "--configuration", "--scratch-path", "--build-path", "-Xswiftc",
                ]
            ),
            "mise": Self(subcommands: ["exec", "x"], endsAtDoubleDash: true),
            "env": Self(optionsWithValues: ["-u", "-P", "-C"]),
            "exec": Self(optionsWithValues: ["-a"]),
            "command": Self(lookups: ["-v", "-V"]),
            "nice": Self(optionsWithValues: ["-n"]),
            "nohup": Self(),
            "arch": Self(),
        ]

        /// The words of the command it runs, of `words`, those after its own name; nil when it runs none, or only
        /// looks one up.
        func command(in words: ArraySlice<String>) -> ArraySlice<String>? {
            var rest = words
            if !subcommands.isEmpty {
                guard let first = rest.first, subcommands.contains(first) else { return nil }
                rest = rest.dropFirst()
            }
            if endsAtDoubleDash, let dashes = rest.firstIndex(of: "--") {
                return rest[(dashes + 1)...]
            }
            while let option = rest.first, option.hasPrefix("-") {
                guard !lookups.contains(option) else { return nil }
                rest = rest.dropFirst()
                if option == "--" {
                    break
                }
                if optionsWithValues.contains(option) {
                    rest = rest.dropFirst()
                }
            }
            return rest
        }
    }
}
