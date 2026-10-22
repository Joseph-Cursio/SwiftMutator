import Foundation

/// An `exclude` entry with a `*` in it, matched against a file's path in the project, such as
/// `Sources/App/Model.swift`. It starts at the project's folder, with or without a leading `/` or `./`. `*` and `?`
/// stay within one folder, `**/` stands for any number of folders, none included, and `[…]`, or `[!…]`, is one of a
/// set of characters. Anything else matches itself.
///
/// Both sides are compared in Unicode's composed form: Finder and Xcode name files with decomposed accents, and an
/// editor types the configuration with composed ones.
struct ExcludeGlob {
    private let regex: NSRegularExpression?

    init(_ glob: String) {
        regex = try? NSRegularExpression(pattern: Self.regularExpression(for: glob))
    }

    func matches(_ pathInProject: String) -> Bool {
        let path = pathInProject.precomposedStringWithCanonicalMapping
        return regex?.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    static func regularExpression(for glob: String) -> String {
        var rest = Substring(glob.precomposedStringWithCanonicalMapping)
        while true {
            if rest.hasPrefix("./") {
                rest = rest.dropFirst(2)
            } else if rest.hasPrefix("/") {
                rest = rest.dropFirst()
            } else {
                break
            }
        }

        var expression = "^"
        while let character = rest.first {
            if rest.hasPrefix("**/") {
                expression += "(?:.*/)?"
                rest = rest.dropFirst(3)
            } else if rest.hasPrefix("**") {
                expression += ".*"
                rest = rest.dropFirst(2)
            } else if character == "*" {
                expression += "[^/]*"
                rest = rest.dropFirst()
            } else if character == "?" {
                expression += "[^/]"
                rest = rest.dropFirst()
            } else if character == "[", let set = characterSet(atStartOf: rest) {
                expression += set.expression
                rest = rest.dropFirst(set.length)
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
                rest = rest.dropFirst()
            }
        }
        return expression + "$"
    }

    /// The set at the start of `text`, `[…]` or `[!…]`, as a regular expression, and how many characters it takes. Nil
    /// if no `]` closes it, so the `[` matches itself. Like `*` and `?`, a negated set never matches a `/`.
    private static func characterSet(atStartOf text: Substring) -> (expression: String, length: Int)? {
        let afterBracket = text.dropFirst()
        let negated = afterBracket.hasPrefix("!")
        let body = negated ? afterBracket.dropFirst() : afterBracket
        guard let close = body.firstIndex(of: "]"), close != body.startIndex else {
            return nil
        }

        let members = body[..<close].map { "\\&[".contains($0) ? "\\\($0)" : String($0) }.joined()
        let length = text.distance(from: text.startIndex, to: close) + 1
        return (negated ? "[^/" + members + "]" : "[" + members + "]", length)
    }
}
