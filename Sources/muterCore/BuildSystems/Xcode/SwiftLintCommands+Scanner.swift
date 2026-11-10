import Foundation

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
        /// How many `case` statements are open where the scanner is.
        private var openCases = 0
        /// Whether what comes next is a `case` item's patterns, as after `in` or `;;`, rather than commands.
        private var expectingPatterns = false

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
                if skipCaseItemEnd() {
                    continue
                }
                if isSeparator(script[index]) {
                    index += 1
                    continue
                }
                if script[index] == UInt8(ascii: "#") {
                    skipComment()
                    continue
                }
                if expectingPatterns {
                    skipPatterns()
                    continue
                }
                if let command = readCommand() {
                    return command
                }
            }
            return nil
        }

        /// The simple command at `index`, if it is one: nil for only reserved words, a `case` statement's start, or
        /// a function's name.
        private mutating func readCommand() -> Command? {
            var start = index
            var words: [String] = []
            while index < script.count, !isSeparator(script[index]) {
                if script[index] == UInt8(ascii: "#") {
                    skipComment()
                    break
                }
                let word = readWord()
                if words.isEmpty, word == "case" {
                    skipCaseSubject()
                    return nil
                }
                if words.isEmpty, word == "esac", openCases > 0 {
                    openCases -= 1
                    skipBlanks()
                    start = index
                } else if words.isEmpty, Self.leadingReservedWords.contains(word) {
                    skipBlanks()
                    start = index
                } else {
                    words.append(word)
                }
                skipBlanks()
            }
            // `name()`: only a function's definition has words just before a `(`, and they don't run.
            if index < script.count, script[index] == UInt8(ascii: "(") {
                return nil
            }
            return words.isEmpty ? nil : Command(start: start, words: words)
        }

        /// The word and `in` after `case`, after which its first item's patterns come.
        private mutating func skipCaseSubject() {
            skipBlanks()
            _ = readWord()
            while index < script.count, isBlank(script[index]) || script[index] == 0x0A {
                index += 1
            }
            if readWord() == "in" {
                openCases += 1
                expectingPatterns = true
            }
        }

        /// A `case` item's patterns, as `swiftlint | lint)`, to the `)` after them; or the `esac` that ends the
        /// statement. A `(` before them is a separator, so already passed.
        private mutating func skipPatterns() {
            expectingPatterns = false
            if readWord() == "esac" {
                openCases -= 1
                return
            }
            while index < script.count {
                skipBlanks()
                guard index < script.count else { return }
                switch script[index] {
                case UInt8(ascii: ")"):
                    index += 1
                    return

                case UInt8(ascii: "|"):
                    index += 1

                default:
                    let before = index
                    _ = readWord()
                    // A byte no word takes, as a newline where a `)` belongs: the script isn't one the shell reads.
                    if index == before {
                        return
                    }
                }
            }
        }

        /// `;;`, `;&` or `;;&` inside a `case` statement, which ends an item: its next item's patterns come after.
        private mutating func skipCaseItemEnd() -> Bool {
            guard openCases > 0, index + 1 < script.count, script[index] == UInt8(ascii: ";"),
                  script[index + 1] == UInt8(ascii: ";") || script[index + 1] == UInt8(ascii: "&") else { return false }
            index += 2
            if index < script.count, script[index - 1] == UInt8(ascii: ";"), script[index] == UInt8(ascii: "&") {
                index += 1
            }
            expectingPatterns = true
            return true
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
                    word += readEscaped()

                case UInt8(ascii: "'"):
                    word += readSingleQuoted()

                case UInt8(ascii: "\""):
                    word += readDoubleQuoted()

                case UInt8(ascii: "`"):
                    word += readBackquoted()

                case UInt8(ascii: ">"), UInt8(ascii: "<"):
                    word += readRedirection(byte)

                default:
                    word.append(byte)
                    index += 1
                }
            }
            index = min(index, script.count)
            return String(lossyUTF8: word)
        }

        /// The byte the backslash at `index` escapes; nothing for a backslash before a newline, which joins two lines.
        private mutating func readEscaped() -> [UInt8] {
            defer { index += 2 }
            return index + 1 < script.count && script[index + 1] != 0x0A ? [script[index + 1]] : []
        }

        /// The text between single quotes at `index`, as it is.
        private mutating func readSingleQuoted() -> [UInt8] {
            var text: [UInt8] = []
            index += 1
            while index < script.count, script[index] != UInt8(ascii: "'") {
                text.append(script[index])
                index += 1
            }
            index += 1
            return text
        }

        /// The redirection `byte` at `index` starts, as `2>&1`, whose `&` doesn't end the command.
        private mutating func readRedirection(_ byte: UInt8) -> [UInt8] {
            var text = [byte]
            index += 1
            if index < script.count, script[index] == UInt8(ascii: "&") {
                text.append(script[index])
                index += 1
            }
            return text
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
