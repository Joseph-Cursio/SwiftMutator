import Foundation
import Yams

extension MuterConfiguration {
    /// The reports `key` asks for, each `format:path` (`ReportRequest.parse`), or nil if it isn't set. Throws on an
    /// entry that isn't one, as `--report` refuses it, and on a value that isn't a list of strings, so a typo is a
    /// configuration error rather than a report not saved.
    static func reports(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [ReportRequest]? {
        try container.decodeIfPresent([String].self, forKey: key)?.map { entry in
            switch ReportRequest.parse(entry) {
            case let .success(request):
                return request

            case let .failure(problem):
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "\(key.stringValue): \(problem), not \(entry)"
                )
            }
        }
    }

    /// The operators `key` names, or nil if it isn't set. Throws on a name that isn't an operator, and on a value that
    /// isn't a list of strings, so a typo is a configuration error rather than an operator left in or out.
    static func operators(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [MutationOperator.Id]? {
        try container.decodeIfPresent([String].self, forKey: key)?.map { name in
            guard let found = MutationOperator.Id(rawValue: name) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "\(key.stringValue): \(name) isn't an operator. "
                        + "The operators are: \(MutationOperator.Id.description)"
                )
            }
            return found
        }
    }

    /// A list of globs, or of test filters, or nil if `key` isn't set. Throws on an empty entry, which would select
    /// nothing, and on a value that isn't a list of strings, so a typo is a configuration error rather than "unset".
    static func globs(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String]? {
        guard let globs = try container.decodeIfPresent([String].self, forKey: key) else { return nil }
        if let error = PropertyTestPattern.problem(with: globs) {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue): \(error)"
            )
        }
        return globs
    }

    /// A percent from 0 to 100, or nil if `key` isn't set, written as `--fail-under` takes it (`ScoreGate.percent`):
    /// plain decimal digits, with at most `ScoreGate.maximumDecimals` decimals, so not 1e2, 0x50, 8_0 or 1:20, which
    /// YAML would read as numbers. A JSON configuration, such as a results file's header, holds a number instead,
    /// whose shortest decimal form is checked the same way. Throws on any other value, so a typo is a configuration
    /// error rather than "unset".
    static func percent(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Double? {
        // YAML gives any scalar as the text it is written with; JSON gives only a string so.
        let text: String
        let number: Double?
        if let written = try? container.decodeIfPresent(String.self, forKey: key) {
            (text, number) = (written, nil)
        } else if let value = try Self.number(forKey: key, in: container) {
            (text, number) = (ScoreGate.shown(value), value)
        } else {
            return nil
        }
        // A number must be the one its text gives, so one with more decimals than its text shows is refused.
        guard let percent = ScoreGate.percent(text), number.map({ $0 == percent }) ?? true else {
            let shown = number.map { Double(text) == $0 ? text : "\($0)" } ?? text
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be a number from 0 to 100, with at most "
                    + "\(ScoreGate.maximumDecimals) decimals, such as 80 or 72.5, not \(shown)"
            )
        }
        return percent
    }

    /// A percent, written in JSON as a number and in YAML as a plain scalar, both in decimal digits
    /// (`ScoreGate.shown`): 80, 72.5, 0.00001.
    struct WrittenPercent: YAMLEncodable {
        let value: Double

        /// A `Decimal`, which JSONEncoder writes in plain digits, as 0.00001 rather than 1e-05.
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(Decimal(string: ScoreGate.shown(value)) ?? Decimal(value))
        }

        func box() -> Node {
            Node(ScoreGate.shown(value), Tag(value == value.rounded() ? .int : .float))
        }
    }

    /// A whole number in `range`, or nil if `key` isn't set. Throws on any other value, so a typo is a configuration
    /// error rather than "unset".
    static func whole(
        forKey key: CodingKeys,
        in range: ClosedRange<Int>,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Int? {
        guard let value = try container.decodeIfPresent(Int.self, forKey: key) else { return nil }
        guard range.contains(value) else {
            let bounds = range.upperBound == Int.max
                ? "at least \(range.lowerBound)" : "from \(range.lowerBound) to \(range.upperBound)"
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be a whole number \(bounds), not \(value)"
            )
        }
        return value
    }

    /// A number, written as an Int or a Double, or nil if `key` isn't set. Throws on a value that isn't one, so a typo
    /// is a configuration error rather than "unset". Its range is checked once the run's flags are in
    /// (`LoadConfiguration`), not here: a results file's header holds the configuration it loaded, which a resume must
    /// still read.
    static func number(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Double? {
        do {
            return try container.decodeIfPresent(Double.self, forKey: key)
                ?? (try container.decodeIfPresent(Int.self, forKey: key)).flatMap(Double.init)
        } catch DecodingError.typeMismatch {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be a number\(Self.writtenValue(forKey: key, in: container))"
            )
        }
    }

    /// The list of strings `key` holds, empty if it isn't set or is blank. Throws on a value that isn't a list, such as
    /// one string, naming `entries`, what the list holds.
    static func list(
        forKey key: CodingKeys,
        of entries: String,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String] {
        do {
            return try container.decodeIfPresent([String].self, forKey: key) ?? []
        } catch DecodingError.typeMismatch {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be a list of \(entries), one to a line after `- `, "
                    + "or in brackets, as [a, b]\(Self.writtenValue(forKey: key, in: container))"
            )
        }
    }

    /// `buildSystem:`'s, or nil if it isn't set, or is `unknown` (`BuildSystem.recordedUnknown`). Throws on any value
    /// but `swift` and `xcodebuild`, which an earlier version took as `unknown`, then ignored.
    static func buildSystem(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> BuildSystem? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        let written = try? container.decode(String.self, forKey: key)
        if written == BuildSystem.recordedUnknown {
            return nil
        }
        guard let written, let writtenSystem = BuildSystem(written: written) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be swift or xcodebuild"
                    + Self.writtenValue(forKey: key, in: container)
            )
        }
        return writtenSystem
    }

    /// ", not <value>", the scalar `key` holds as written, or "" when it holds a list or a mapping.
    static func writtenValue(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> String {
        (try? container.decode(String.self, forKey: key)).map { ", not \($0)" } ?? ""
    }
}
