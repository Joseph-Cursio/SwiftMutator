import Foundation
import Yams

/// The configuration file: its names, and its contents as YAML, or as the JSON of older versions.
extension MuterConfiguration {
    init(from data: Data) throws {
        do {
            self = try YAMLDecoder().decode(Self.self, from: data)
        } catch {
            let yamlError = error
            do {
                self = try JSONDecoder().decode(Self.self, from: data)
            } catch {
                // YAML's reason, which names the key at fault, rather than that the file isn't JSON.
                throw yamlError
            }
        }
    }

    static let fileName = "muter.conf"
    static let `extension` = "yml"
    static let fileNameWithExtension = "\(fileName).\(`extension`)"
    static let legacyFileNameWithExtension = "\(fileName).json"

    var asData: Data {
        get throws {
            Data(try YAMLEncoder().encode(self).utf8)
        }
    }
}
