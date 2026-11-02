import Foundation

extension NSRegularExpression {
    static func regexWithPattern(
        _ pattern: String,
        _ options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        let currentThread = Thread.current
        let cacheKey = pattern + "\(options)"
        if let cached = currentThread.threadDictionary[cacheKey] as? NSRegularExpression {
            return cached
        }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            // Every pattern is a literal in SwiftMutator's own code, so one that doesn't compile is a bug in it.
            preconditionFailure("\(pattern) is not a valid regular expression: \(error)")
        }
        currentThread.threadDictionary[cacheKey] = regex

        return regex
    }
}
