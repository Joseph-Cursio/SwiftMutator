/// A three-state value that a summary's JSON holds as a Bool that may be left out, as the `Bool?` it stands for was:
/// `whenTrue` as `true`, `whenFalse` as `false`, and `whenAbsent` by leaving its key out.
///
/// A property of such a type is coded through the `KeyedEncodingContainer` and `KeyedDecodingContainer` overloads
/// below, which a synthesized `Codable` conformance picks over the generic ones, so the key is left out, or read as
/// missing, just as `encodeIfPresent` and `decodeIfPresent` did for the Bool.
protocol AbsentOrBool: Codable, Equatable {
    /// What `true` stands for.
    static var whenTrue: Self { get }
    /// What `false` stands for.
    static var whenFalse: Self { get }
    /// What a missing key stands for.
    static var whenAbsent: Self { get }
}

extension AbsentOrBool {
    /// As a value of its own, outside a keyed container: `true` or `false`.
    init(from decoder: Decoder) throws {
        self = try decoder.singleValueContainer().decode(Bool.self) ? .whenTrue : .whenFalse
    }

    /// As a value of its own, outside a keyed container: `true`, `false`, or null for `whenAbsent`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if self == .whenAbsent {
            try container.encodeNil()
        } else {
            try container.encode(self == .whenTrue)
        }
    }
}

extension KeyedEncodingContainer {
    // `value` at `key` as a Bool, or no key at all for `whenAbsent`.
    // swiftlint:disable:next unused_declaration - only synthesized Codable conformances call it
    mutating func encode<Value: AbsentOrBool>(_ value: Value, forKey key: Key) throws {
        guard value != .whenAbsent else { return }
        try encode(value == .whenTrue, forKey: key)
    }
}

extension KeyedDecodingContainer {
    // The Bool at `key` as a `Value`, and `whenAbsent` when the key is missing or null.
    // swiftlint:disable:next unused_declaration - only synthesized Codable conformances call it
    func decode<Value: AbsentOrBool>(_: Value.Type, forKey key: Key) throws -> Value {
        guard let present = try decodeIfPresent(Bool.self, forKey: key) else { return .whenAbsent }
        return present ? .whenTrue : .whenFalse
    }
}
