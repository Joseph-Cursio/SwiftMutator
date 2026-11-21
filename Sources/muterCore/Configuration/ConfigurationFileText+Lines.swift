import Yams

extension ConfigurationFileText {
    /// Each key the configuration writes, with its value as YAML.
    static func values(of configuration: MuterConfiguration) throws -> [String: Node] {
        let mapping = try Yams.compose(yaml: YAMLEncoder().encode(configuration))?.mapping
        var values: [String: Node] = [:]
        for (key, value) in mapping ?? [:] {
            if let name = key.string {
                values[name] = value
            }
        }
        return values
    }

    /// The text in lines of at most `width` characters, broken between words.
    static func wrapped(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.isEmpty {
                line = String(word)
            } else if line.count + 1 + word.count <= width {
                line += " \(word)"
            } else {
                lines.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty {
            lines.append(line)
        }
        return lines
    }
}
