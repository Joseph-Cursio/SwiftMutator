import Foundation

extension AcceptanceTests {
    func numberOfDiscoveredFileLists(in output: String) throws -> Int {
        try applyRegex("[a-zA-Z]+.swift \\([0-9]+ mutants\\)", to: output)
    }

    func numberOfXcodeFormattedMessages(in output: String) throws -> Int {
        try applyRegex(
            "[\\/[:alnum:]\\/]+[a-zA-Z]+.swift\\:[0-9]+:[0-9]+\\: warning: [a-zA-Z ]+: [a-zA-Z[:punct:] ]+/?",
            to: output
        )
    }

    func numberOfProgressUpdates(in output: String) throws -> Int {
        try applyRegex(
            "^\\[[0-9]{2}:[0-9]{2}:[0-9]{2}\\] [0-9]+ of [0-9]+ \\([0-9]+%\\)",
            to: output
        )
    }

    func numberOfDurationEstimates(in output: String) throws -> Int {
        try applyRegex(
            " [0-9]+ (min|h) left",
            to: output
        )
    }

    func applyRegex(_ regex: String, to output: String) throws -> Int {
        let filePathRegex = try NSRegularExpression(pattern: regex, options: .anchorsMatchLines)
        let entireString = NSRange(location: 0, length: output.count)
        return filePathRegex.numberOfMatches(
            in: output,
            options: .withoutAnchoringBounds,
            range: entireString
        )
    }
}
