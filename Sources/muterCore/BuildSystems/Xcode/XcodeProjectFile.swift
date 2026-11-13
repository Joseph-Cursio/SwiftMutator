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
            decoded += decodedEscape(escaped, at: &index, in: bytes, upTo: range.upperBound).map { ($0, offset) }
        }
        return decoded
    }

    /// The escapes a backslash and one letter write, by the letter, and the byte each stands for.
    private static let simpleEscapes: [UInt8: UInt8] = [
        UInt8(ascii: "n"): 0x0A,
        UInt8(ascii: "t"): 0x09,
        UInt8(ascii: "r"): 0x0D,
        UInt8(ascii: "a"): 0x07,
        UInt8(ascii: "b"): 0x08,
        UInt8(ascii: "f"): 0x0C,
        UInt8(ascii: "v"): 0x0B,
    ]

    /// The bytes the escape of `escaped` after a backslash stands for, reading the digits that follow it from `index`,
    /// up to `end`.
    private static func decodedEscape(
        _ escaped: UInt8,
        at index: inout Int,
        in bytes: [UInt8],
        upTo end: Int
    ) -> [UInt8] {
        if let byte = simpleEscapes[escaped] {
            return [byte]
        }
        if escaped == UInt8(ascii: "U") {
            return unicodeEscape(at: &index, in: bytes, upTo: end)
        }
        if octalDigits.contains(escaped) {
            return [octalEscape(escaped, at: &index, in: bytes, upTo: end)]
        }
        return [escaped]
    }

    /// The UTF-8 bytes of the character a `\U` escape's up to four hex digits at `index` write.
    private static func unicodeEscape(at index: inout Int, in bytes: [UInt8], upTo end: Int) -> [UInt8] {
        var scalar: UInt32 = 0
        var digits = 0
        while digits < 4, index < end, let digit = hexValue(of: bytes[index]) {
            scalar = scalar * 16 + digit
            index += 1
            digits += 1
        }
        let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
        return Array(String(character).utf8)
    }

    /// The byte an octal escape writes, from its first digit, `escaped`, and up to two more at `index`.
    private static func octalEscape(_ escaped: UInt8, at index: inout Int, in bytes: [UInt8], upTo end: Int) -> UInt8 {
        var value = UInt32(escaped - UInt8(ascii: "0"))
        var digits = 1
        while digits < 3, index < end, octalDigits.contains(bytes[index]) {
            value = value * 8 + UInt32(bytes[index] - UInt8(ascii: "0"))
            index += 1
            digits += 1
        }
        return UInt8(truncatingIfNeeded: value)
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

    /// Reads one value at a time, skipping the comments and spaces between them.
    private struct Parser {
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
