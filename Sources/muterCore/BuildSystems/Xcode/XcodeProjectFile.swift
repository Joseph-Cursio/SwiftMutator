import Foundation

/// An Xcode project's `project.pbxproj`, read as the old-style property list Xcode writes, with where each string lies
/// in the file's bytes: so a change to one string can leave every other byte of the file as it was, comments,
/// spacing and the order of its objects included. A file in another format, as XML, isn't read.
struct XcodeProjectFile {
    /// A string of the file, decoded, with the range of its bytes in the file, between the quotes of a quoted one.
    struct Text: Equatable {
        let value: String
        let range: Range<Int>
        let isQuoted: Bool
    }

    indirect enum Value {
        case text(Text)
        /// A dictionary's entries, in the file's order.
        case dictionary([(key: String, value: Self)])
        case array([Self])

        /// The value of `key`, if this is a dictionary that has it.
        subscript(key: String) -> Self? {
            guard case let .dictionary(entries) = self else { return nil }
            return entries.first { $0.key == key }?.value
        }

        var text: Text? {
            guard case let .text(text) = self else { return nil }
            return text
        }

        var string: String? {
            text?.value
        }

        var items: [Self] {
            guard case let .array(items) = self else { return [] }
            return items
        }

        var entries: [(key: String, value: Self)] {
            guard case let .dictionary(entries) = self else { return [] }
            return entries
        }
    }

    let bytes: [UInt8]
    let root: Value

    /// Nil when `bytes` isn't an old-style property list with a dictionary at its root.
    init?(_ bytes: [UInt8]) {
        var parser = Parser(bytes: bytes)
        guard let rootValue = parser.value(), case .dictionary = rootValue else { return nil }
        self.bytes = bytes
        self.root = rootValue
    }

    /// The project's objects, each by its identifier.
    var objects: [(key: String, value: Value)] {
        root["objects"]?.entries ?? []
    }

    /// Each byte that the escaped text at `range` of `bytes` stands for, with the offset in `bytes` of the text it was
    /// written as: an escape's backslash, or the byte itself. A `\U` escape of a character outside ASCII gives its
    /// UTF-8 bytes, each at the escape's offset.
    static func decodedBytes(of range: Range<Int>, in bytes: [UInt8]) -> [(byte: UInt8, offset: Int)] {
        var decoded: [(byte: UInt8, offset: Int)] = []
        var index = range.lowerBound
        while index < range.upperBound {
            let offset = index
            guard bytes[index] == UInt8(ascii: "\\"), index + 1 < range.upperBound else {
                decoded.append((bytes[index], offset))
                index += 1
                continue
            }
            index += 1
            let escaped = bytes[index]
            index += 1
            switch escaped {
            case UInt8(ascii: "n"): decoded.append((0x0A, offset))
            case UInt8(ascii: "t"): decoded.append((0x09, offset))
            case UInt8(ascii: "r"): decoded.append((0x0D, offset))
            case UInt8(ascii: "a"): decoded.append((0x07, offset))
            case UInt8(ascii: "b"): decoded.append((0x08, offset))
            case UInt8(ascii: "f"): decoded.append((0x0C, offset))
            case UInt8(ascii: "v"): decoded.append((0x0B, offset))

            case UInt8(ascii: "U"):
                var scalar: UInt32 = 0
                var digits = 0
                while digits < 4, index < range.upperBound, let digit = hexValue(of: bytes[index]) {
                    scalar = scalar * 16 + digit
                    index += 1
                    digits += 1
                }
                let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                decoded += Array(String(character).utf8).map { ($0, offset) }

            case octalDigits:
                var value = UInt32(escaped - UInt8(ascii: "0"))
                var digits = 1
                while digits < 3, index < range.upperBound, octalDigits.contains(bytes[index]) {
                    value = value * 8 + UInt32(bytes[index] - UInt8(ascii: "0"))
                    index += 1
                    digits += 1
                }
                decoded.append((UInt8(truncatingIfNeeded: value), offset))

            default:
                decoded.append((escaped, offset))
            }
        }
        return decoded
    }

    private static let octalDigits = UInt8(ascii: "0") ... UInt8(ascii: "7")

    private static func hexValue(of byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
        default: nil
        }
    }
}

private extension XcodeProjectFile {
    /// Reads one value at a time, skipping the comments and spaces between them.
    struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func value() -> Value? {
            skipTrivia()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                return dictionary()

            case UInt8(ascii: "("):
                index += 1
                return array()

            case UInt8(ascii: "\""):
                return quotedText().map(Value.text)

            default:
                return unquotedText().map(Value.text)
            }
        }

        private mutating func dictionary() -> Value? {
            var entries: [(key: String, value: Value)] = []
            while true {
                skipTrivia()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .dictionary(entries)
                }
                guard let key = value()?.string, skip("="), let item = value(), skip(";") else { return nil }
                entries.append((key, item))
            }
        }

        private mutating func array() -> Value? {
            var items: [Value] = []
            while true {
                skipTrivia()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ")") {
                    index += 1
                    return .array(items)
                }
                guard let item = value() else { return nil }
                items.append(item)
                skipTrivia()
                // The last item may or may not be followed by a comma.
                if index < bytes.count, bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if index >= bytes.count || bytes[index] != UInt8(ascii: ")") {
                    return nil
                }
            }
        }

        private mutating func quotedText() -> Text? {
            let start = index + 1
            index = start
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { return nil }
            let range = start ..< index
            index += 1
            let decoded = XcodeProjectFile.decodedBytes(of: range, in: bytes).map(\.byte)
            return Text(value: String(lossyUTF8: decoded), range: range, isQuoted: true)
        }

        private mutating func unquotedText() -> Text? {
            let start = index
            while index < bytes.count, !Self.endsUnquotedText(bytes[index]) {
                index += 1
            }
            guard index > start else { return nil }
            let range = start ..< index
            return Text(value: String(lossyUTF8: bytes[range]), range: range, isQuoted: false)
        }

        private static func endsUnquotedText(_ byte: UInt8) -> Bool {
            isSpace(byte) || "{}()=;,\"".utf8.contains(byte)
        }

        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || (0x09 ... 0x0D).contains(byte)
        }

        private mutating func skip(_ punctuation: Unicode.Scalar) -> Bool {
            skipTrivia()
            guard index < bytes.count, bytes[index] == UInt8(ascii: punctuation) else { return false }
            index += 1
            return true
        }

        /// Spaces, `/* … */` comments and `// …` comments, as the `// !$*UTF8*$!` the file starts with.
        private mutating func skipTrivia() {
            while index < bytes.count {
                if Self.isSpace(bytes[index]) {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "/"), index + 1 < bytes.count,
                          bytes[index + 1] == UInt8(ascii: "*") {
                    index += 2
                    while index + 1 < bytes.count,
                          !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) {
                        index += 1
                    }
                    index = min(index + 2, bytes.count)
                } else if bytes[index] == UInt8(ascii: "/"), index + 1 < bytes.count,
                          bytes[index + 1] == UInt8(ascii: "/") {
                    while index < bytes.count, bytes[index] != 0x0A {
                        index += 1
                    }
                } else {
                    return
                }
            }
        }
    }
}
