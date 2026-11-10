import Foundation

/// A compile error parsed out of a compiler or test log: mostly `file:line:column: error: message`.
struct CompilerError: Hashable, Sendable {
    /// Where a macro's expanded code came from, as the note after an error in its expansion names it.
    private struct ExpansionOrigin {
        let path: String
        let line: Int
        let column: Int
    }

    let filePath: String
    let line: Int
    let column: Int
    let message: String

    var fileName: String {
        filePath.lastPathComponent
    }

    var description: String {
        "\(fileName):\(line):\(column): error: \(message)"
    }

    /// The first compile error in `log` reported against any of `filePaths`, the rewritten files in the project's copy,
    /// as the build's paths are. Compared in `canonicalPath` form, as the build and SwiftMutator can spell one file
    /// differently: a file of the same name in another target, whose error isn't SwiftMutator's, isn't one of them.
    static func first(
        in log: String,
        inFilesAt filePaths: [String]
    ) -> CompilerError? {
        let rewritten = Set(filePaths.map(\.canonicalPath))

        return all(in: log).first { error in
            guard error.filePath.hasPrefix("/") else {
                // A build that runs `swiftc` on paths relative to the copy prints them so.
                let relative = error.filePath.hasPrefix("./") ? String(error.filePath.dropFirst(2)) : error.filePath
                return rewritten.contains { $0.hasSuffix("/" + relative) }
            }
            return rewritten.contains(error.filePath.canonicalPath)
        }
    }

    /// Every compile error `log` shows, without colour codes, as `swift build` prints them to a log, whatever the path
    /// holds. Each is listed each time it is printed: xcodebuild prints an error once per architecture.
    ///
    /// An error in a macro's expansion is reported in a buffer that is no file of the project. The note after it says
    /// where the expanded code came from, and it counts as an error there: otherwise a macro that copies a mutated
    /// value to where it can't compile could be pinned on no mutant, and would stop the run.
    static func all(in log: String) -> [CompilerError] {
        let lines = log.split(whereSeparator: \.isNewline)
        return lines.indices.compactMap { index in
            let line = lines[index]
            guard line.contains("error:"), let error = from(logLine: FailedTestLine.withoutColours(line)) else {
                return nil
            }
            guard error.isInAMacroExpansion else { return error }
            return lines[(index + 1)...].prefix(notesLookedAtAfterAnExpansionsError)
                .lazy.compactMap { origin(ofExpansionNamedBy: $0) }.first
                .map { CompilerError(filePath: $0.path, line: $0.line, column: $0.column, message: error.message) }
                ?? error
        }
    }

    /// How many lines after an error in a macro's expansion are looked at for the note that names its origin.
    private static let notesLookedAtAfterAnExpansionsError = 3

    /// `macro expansion @State:13:41`, or a generated buffer's path, as a compiler with another diagnostic style gives.
    private var isInAMacroExpansion: Bool {
        filePath.hasPrefix("macro expansion ") || filePath.contains("@__swiftmacro_")
    }

    /// `` `- /path/to/File.swift:12:34: note: expanded code originates here ``.
    private static let expansionOrigin = NSRegularExpression.regexWithPattern(
        #"(/(?:(?!: ).)+?):([0-9]+):([0-9]+):\s+note:\s+expanded code originates here\s*$"#
    )

    private static func origin(
        ofExpansionNamedBy line: Substring
    ) -> ExpansionOrigin? {
        guard line.contains("expanded code originates here") else { return nil }
        let text = FailedTestLine.withoutColours(line)
        guard let match = expansionOrigin.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let path = Range(match.range(at: 1), in: text),
              let number = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }),
              let column = Range(match.range(at: 3), in: text).flatMap({ Int(text[$0]) })
        else {
            return nil
        }
        return ExpansionOrigin(path: String(text[path]), line: number, column: column)
    }

    /// `/path/to/File.swift:12:34: error: expected expression`. The path holds no `: `, so a diagnostic quoted after a
    /// label, such as `note: /path/File.swift:1:1: error: …`, isn't taken for one. The message runs to the end of the
    /// line; anything that doesn't have exactly this shape is not a diagnostic.
    private static let diagnostic = NSRegularExpression.regexWithPattern(
        #"^((?:(?!: ).)+?):([0-9]+):([0-9]+):\s+error:\s+(\S.*?)\s*$"#
    )

    /// `error: /path/to/File.swift:12:34 #_hasSymbol may only be used as condition…`, as Swift Build's driver prints an
    /// error it finds before compiling, with no colon after the column, and glued to whatever the progress line had
    /// printed: `[28 / 51] Serror: /path/…`. Only an absolute path, so that `error: <a path> failed…` isn't one.
    private static let driverDiagnostic = NSRegularExpression.regexWithPattern(
        #"^[^:]*?error:\s+(/(?:(?!: ).)+?):([0-9]+):([0-9]+)\s+(\S.*?)\s*$"#
    )

    private static func from(logLine: String) -> CompilerError? {
        let whole = NSRange(logLine.startIndex..., in: logLine)
        guard let match = diagnostic.firstMatch(in: logLine, range: whole)
            ?? driverDiagnostic.firstMatch(in: logLine, range: whole),
              let path = Range(match.range(at: 1), in: logLine),
              let line = Range(match.range(at: 2), in: logLine).flatMap({ Int(logLine[$0]) }),
              let column = Range(match.range(at: 3), in: logLine).flatMap({ Int(logLine[$0]) }),
              let message = Range(match.range(at: 4), in: logLine)
        else {
            return nil
        }

        return CompilerError(
            filePath: String(logLine[path]),
            line: line,
            column: column,
            message: String(logLine[message])
        )
    }
}
