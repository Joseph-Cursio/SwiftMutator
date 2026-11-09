import Foundation

/// The commands of a shell script that run SwiftLint, found by a reading of the script that is only as close as it
/// needs to be: each simple command, after `then`, `do`, `else`, `&&`, `;`, `|`, a newline and the like, is split into
/// words, with their quotes, escapes and expansions kept whole, and judged by them. A command runs SwiftLint when its
/// first word, past any `NAME=value`, is `swiftlint`, by name or by a path that ends in it, as
/// `"${PODS_ROOT}/SwiftLint/swiftlint"` is, or when a launcher runs it so: `xcrun swiftlint`, `mint run swiftlint` or
/// `mint run realm/SwiftLint`, `swift run swiftlint`, `mise exec -- swiftlint`, `env`, `exec`, `command`, `nice`,
/// `nohup` and `arch`. Nothing else is: not `which swiftlint`, `command -v swiftlint`, an `echo` that names it, a path
/// to it given as an argument, a variable such as `$SWIFTLINT`, or a script that runs it, as `scripts/swiftlint.sh`.
/// Heredocs and `case` patterns aren't understood, but a misreading can only make a command named `swiftlint` be
/// taken for one, or missed.
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

        static let all: [String: Launcher] = [
            "xcrun": Launcher(
                optionsWithValues: ["--sdk", "-sdk", "--toolchain", "-toolchain"],
                lookups: ["-f", "--find"]
            ),
            "mint": Launcher(subcommands: ["run"], optionsWithValues: ["-m", "--mintfile"]),
            "swift": Launcher(
                subcommands: ["run"],
                optionsWithValues: [
                    "--package-path", "-c", "--configuration", "--scratch-path", "--build-path", "-Xswiftc",
                ]
            ),
            "mise": Launcher(subcommands: ["exec", "x"], endsAtDoubleDash: true),
            "env": Launcher(optionsWithValues: ["-u", "-P", "-C"]),
            "exec": Launcher(optionsWithValues: ["-a"]),
            "command": Launcher(lookups: ["-v", "-V"]),
            "nice": Launcher(optionsWithValues: ["-n"]),
            "nohup": Launcher(),
            "arch": Launcher(),
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

extension SwiftLintCommands {
    /// A simple command: where it starts in the script, and its words, unquoted, with expansions kept as written.
    struct Command: Equatable {
        let start: Int
        let words: [String]
    }

    /// Splits a script into its simple commands, one at a time.
    struct Scanner {
        let script: [UInt8]
        private var index = 0

        init(script: [UInt8]) {
            self.script = script
        }

        /// The words after which a new command starts, as `then` in `if …; then swiftlint`.
        private static let leadingReservedWords: Set = [
            "then", "do", "else", "elif", "if", "while", "until", "!", "{", "time",
        ]

        mutating func nextCommand() -> Command? {
            while index < script.count {
                skipBlanks()
                guard index < script.count else { return nil }
                if isSeparator(script[index]) {
                    index += 1
                    continue
                }
                if script[index] == UInt8(ascii: "#") {
                    skipComment()
                    continue
                }
                var start = index
                var words: [String] = []
                while index < script.count, !isSeparator(script[index]) {
                    if script[index] == UInt8(ascii: "#") {
                        skipComment()
                        break
                    }
                    let word = readWord()
                    if words.isEmpty, Self.leadingReservedWords.contains(word) {
                        skipBlanks()
                        start = index
                    } else {
                        words.append(word)
                    }
                    skipBlanks()
                }
                if !words.isEmpty {
                    return Command(start: start, words: words)
                }
            }
            return nil
        }

        /// A newline, `;`, `&`, `|`, `(` or `)`: what ends a command, or a list of them.
        private func isSeparator(_ byte: UInt8) -> Bool {
            byte == 0x0A || ";&|()".utf8.contains(byte)
        }

        private func isBlank(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0D
        }

        /// Spaces, tabs, and a backslash before a newline, which joins two lines.
        private mutating func skipBlanks() {
            while index < script.count {
                if isBlank(script[index]) {
                    index += 1
                } else if script[index] == UInt8(ascii: "\\"), index + 1 < script.count, script[index + 1] == 0x0A {
                    index += 2
                } else {
                    return
                }
            }
        }

        private mutating func skipComment() {
            while index < script.count, script[index] != 0x0A {
                index += 1
            }
        }

        /// The word at `index`, without its quotes and escapes, and with any expansion in it as written.
        private mutating func readWord() -> String {
            var word: [UInt8] = []
            while index < script.count {
                let byte = script[index]
                if byte == UInt8(ascii: "$"), index + 1 < script.count,
                   script[index + 1] == UInt8(ascii: "(") || script[index + 1] == UInt8(ascii: "{") {
                    word += readExpansion()
                    continue
                }
                if isBlank(byte) || isSeparator(byte) {
                    break
                }
                switch byte {
                case UInt8(ascii: "\\"):
                    if index + 1 < script.count, script[index + 1] != 0x0A {
                        word.append(script[index + 1])
                    }
                    index += 2
                case UInt8(ascii: "'"):
                    index += 1
                    while index < script.count, script[index] != UInt8(ascii: "'") {
                        word.append(script[index])
                        index += 1
                    }
                    index += 1
                case UInt8(ascii: "\""):
                    word += readDoubleQuoted()
                case UInt8(ascii: "`"):
                    word += readBackquoted()
                case UInt8(ascii: ">"), UInt8(ascii: "<"):
                    // A redirection, as `2>&1`, whose `&` doesn't end the command.
                    word.append(byte)
                    index += 1
                    if index < script.count, script[index] == UInt8(ascii: "&") {
                        word.append(script[index])
                        index += 1
                    }
                default:
                    word.append(byte)
                    index += 1
                }
            }
            index = min(index, script.count)
            return String(decoding: word, as: UTF8.self)
        }

        /// The text between double quotes at `index`, unescaped, with any expansion in it as written.
        private mutating func readDoubleQuoted() -> [UInt8] {
            var text: [UInt8] = []
            index += 1
            while index < script.count, script[index] != UInt8(ascii: "\"") {
                let byte = script[index]
                if byte == UInt8(ascii: "\\"), index + 1 < script.count {
                    text.append(script[index + 1])
                    index += 2
                } else if byte == UInt8(ascii: "$"), index + 1 < script.count,
                          script[index + 1] == UInt8(ascii: "(") || script[index + 1] == UInt8(ascii: "{") {
                    text += readExpansion()
                } else if byte == UInt8(ascii: "`") {
                    text += readBackquoted()
                } else {
                    text.append(byte)
                    index += 1
                }
            }
            index += 1
            return text
        }

        /// `$( … )` or `${ … }` at `index`, as written, to its matching parenthesis or brace.
        private mutating func readExpansion() -> [UInt8] {
            let start = index
            let open = script[index + 1]
            let close = open == UInt8(ascii: "(") ? UInt8(ascii: ")") : UInt8(ascii: "}")
            var depth = 0
            index += 1
            while index < script.count {
                let byte = script[index]
                if byte == UInt8(ascii: "\\") {
                    index += 2
                    continue
                }
                if byte == UInt8(ascii: "'") || byte == UInt8(ascii: "\"") {
                    index += 1
                    while index < script.count, script[index] != byte {
                        index += script[index] == UInt8(ascii: "\\") && byte == UInt8(ascii: "\"") ? 2 : 1
                    }
                } else if byte == open {
                    depth += 1
                } else if byte == close {
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        break
                    }
                }
                index += 1
            }
            index = min(index, script.count)
            return Array(script[start ..< index])
        }

        /// `` `…` `` at `index`, as written.
        private mutating func readBackquoted() -> [UInt8] {
            let start = index
            index += 1
            while index < script.count, script[index] != UInt8(ascii: "`") {
                index += script[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            index = min(index + 1, script.count)
            return Array(script[start ..< index])
        }
    }
}
