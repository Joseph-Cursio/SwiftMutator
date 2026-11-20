import Foundation

// swiftlint:disable legacy_objc_type - JSONSerialization reads every number as an NSNumber, of which only the type
// tells a Boolean from a number
extension JSONSerialization {
    /// Reads JSON as `jsonObject(with:)` does, into values that compare the same on every platform: objects as
    /// `[String: AnyHashable]`, arrays as `[AnyHashable]`, `true` and `false` as `Bool`, whole numbers as `Int`
    /// and others as `Double`.
    ///
    /// On Darwin, `jsonObject(with:)` gives Foundation's collections and `NSNumber`s, which bridge to `AnyHashable`
    /// and compare as Swift's numbers and Booleans. On Linux it gives `[String: Any]` and `[Any]`, which aren't
    /// hashable, so a cast to `[String: AnyHashable]` fails, and `NSNumber`s that, as `AnyHashable`, equal no Swift
    /// number or Boolean.
    static func hashableObject(with data: Data) throws -> Any {
        try hashable(jsonObject(with: data))
    }

    private static func hashable(_ value: Any) -> AnyHashable {
        switch value {
        case let string as String:
            return string

        case let number as NSNumber:
            return swiftValue(of: number)

        case let object as [String: Any]:
            return object.mapValues(hashable)

        case let array as [Any]:
            return array.map(hashable)

        case is NSNull:
            return NSNull()

        default:
            preconditionFailure("JSONSerialization gave a \(type(of: value))")
        }
    }

    /// The Swift value of a number `JSONSerialization` read.
    private static func swiftValue(of number: NSNumber) -> AnyHashable {
        switch String(cString: number.objCType) {
        case "c":
            // A `char`, which JSONSerialization gives only for `true` and `false`.
            return number.boolValue

        case "d", "f":
            return number.doubleValue

        default:
            return number.intValue
        }
    }
}

extension Dictionary where Key == String {
    /// The number at `key` as a `Double`, whole or not. `JSONSerialization.hashableObject(with:)` reads `80` as an
    /// `Int`, which casts to `Double` on Darwin but not on Linux.
    func double(at key: String) -> Double? {
        (self[key] as? NSNumber)?.doubleValue
    }
}

// swiftlint:enable legacy_objc_type
