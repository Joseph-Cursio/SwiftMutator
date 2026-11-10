import Foundation
import SnapshotTesting

extension Snapshotting where Value: Encodable, Format == String {
    static func json(excludingKeysMatching predicate: @escaping (String) -> Bool) -> Snapshotting {
        let encoder = JSONEncoder()
        var snapshotting = SimplySnapshotting.lines.pullback { (encodable: Value) in
            // A report that can't be encoded, or isn't a JSON object, is snapshotted as the error that says so, which
            // no recorded snapshot matches.
            do {
                let object = try JSONSerialization.jsonObject(with: encoder.encode(encodable), options: [])
                guard let workingDictionary = object as? [String: Any] else { return "Not a JSON object: \(object)" }

                let newDictionary = workingDictionary.recursivelyFiltered { !predicate($0) }
                let data = try JSONSerialization.data(
                    withJSONObject: newDictionary,
                    options: [.sortedKeys, .prettyPrinted]
                )
                return String(data: data, encoding: .utf8) ?? "Not UTF-8"
            } catch {
                return "Not encoded: \(error)"
            }
        }
        snapshotting.pathExtension = "json"
        return snapshotting
    }
}
