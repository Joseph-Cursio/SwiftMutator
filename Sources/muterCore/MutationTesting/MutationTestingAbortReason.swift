import Foundation

public enum MutationTestingAbortReason: Equatable, Sendable {
    /// `mutatedFilePaths` are the files SwiftMutator rewrote to insert mutants. A compile error in one of
    /// them points at SwiftMutator's own rewriting rather than at the user's configuration, so the message
    /// needs them to tell the two apart.
    case baselineTestFailed(log: String, mutatedFilePaths: [String])
    /// The mutated project's baseline passed, but a parallel worker's clone of it, at `directory`,
    /// failed the same build-and-test run.
    case workerBaselineTestFailed(worker: Int, directory: String, log: String)
    case tooManyBuildErrors
    /// The mutant `id`'s run couldn't be told to switch it on: under xcodebuild, its `muter.xctestrun` couldn't be
    /// written, as `description` says. The file left by the run before would have switched that run's mutant on.
    case mutantNotSwitchedOn(id: String, description: String)
    /// Control run `number`'s xcodebuild worker's `.xctestrun` couldn't be written with no mutant on, as `description`
    /// says. The file left by the run before would have switched that run's mutant on.
    case controlRunNotSwitchedOff(number: Int, description: String)
    /// The simulator that worker `worker`'s xcodebuild run tested on is gone, as `line` of the run's log says: every
    /// run on it would fail without testing its mutant. `log` is where that run's log is kept, if it is.
    case simulatorUnavailable(worker: Int, line: String, log: String?)
    case unknownError(description: String)
}

extension MutationTestingAbortReason: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .baselineTestFailed(log, mutatedFilePaths):
            return Self.baselineTestFailedDescription(
                log: log,
                mutatedFilePaths: mutatedFilePaths
            )

        case let .workerBaselineTestFailed(worker, directory, log):
            return """
            Your test suite passed its baseline in the mutated project, but failed the same build-and-test \
            run in the copy SwiftMutator made for parallel worker \(worker), at \(directory).

            Your tests may not tolerate running alongside a copy of themselves, for example if they share \
            files outside the project, ports, user defaults or the keychain. Or the workers' builds ran out \
            of disk space or memory. Run with --workers 1, or set mutationTestWorkers to 1 in your \
            \(MuterConfiguration.fileNameWithExtension), to test one mutant at a time.

            \(Self.baselineTestFailedEvidence(log: log))
            """

        case .tooManyBuildErrors:
            return """
            SwiftMutator noticed the last 5 attempts to apply a mutation operator resulted in a build error within your code base.
            This is considered unlikely and abnormal. If you can reproduce this, please consider filing an issue at
            https://github.com/Joseph-Cursio/SwiftMutator/issues
            """

        case let .mutantNotSwitchedOn(id, description):
            return """
            SwiftMutator could not switch on mutant \(id) for its test run, and stopped rather than record a verdict \
            for code the run may not have tested.

            \(description)
            """

        case let .controlRunNotSwitchedOff(number, description):
            return """
            SwiftMutator could not switch every mutant off for control run \(number), and stopped rather than record \
            as flaky the tests that failed for a mutant the run may have tested.

            \(description)
            """

        case let .simulatorUnavailable(worker, line, log):
            let kept = log.map { "\n\nThe run's log is in \($0)." } ?? ""
            return """
            SwiftMutator stopped because the simulator that worker \(worker) tests mutants on is gone: every run on it \
            would fail without testing its mutant, and count as a kill. It recorded no verdict for that run. \
            xcodebuild said:

              \(line)\(kept)

            The results so far are kept. If the simulator the -destination in your \
            \(MuterConfiguration.fileNameWithExtension) names was deleted, make it again, then resume the run with the \
            command its summary's Continue line gives. Workers' own simulators are made again for each run.
            """

        case let .unknownError(error):
            return "SwiftMutator encountered an error running your test suite and can't continue\n\(error)"
        }
    }
}

private extension MutationTestingAbortReason {
    static func baselineTestFailedDescription(
        log: String,
        mutatedFilePaths: [String]
    ) -> String {
        """
        \(baselineTestFailedCause(log: log, mutatedFilePaths: mutatedFilePaths))

        \(baselineTestFailedEvidence(log: log))
        """
    }

    static func baselineTestFailedCause(
        log: String,
        mutatedFilePaths: [String]
    ) -> String {
        if let error = CompilerError.first(in: log, inFilesAt: mutatedFilePaths) {
            return """
            SwiftMutator could not establish a baseline because a file it had rewritten failed to compile:

              \(error.description)

            First check that \(error.fileName) compiles in your unmutated project. If it does: a test plan's run tests \
            its copy as it is, so there this is most likely a mutant that doesn't compile. Fix it in the copy, or make the \
            plan again without its operator. Any other run takes such a mutant out of the build, so there this is most \
            likely a bug in SwiftMutator's own rewriting rather than a problem with your \
            \(MuterConfiguration.fileNameWithExtension). Please report that bug at \
            https://github.com/Joseph-Cursio/SwiftMutator/issues and include the log below.
            """
        }

        return """
        SwiftMutator noticed that your test suite initially failed to compile or produced a test failure.

        Assuming you have no build errors, this is usually due to misconfiguring the "executable" and \
        "arguments" options inside of your \(MuterConfiguration.fileNameWithExtension).
        Alternatively, it could mean you have a nondeterministic test failure in your test suite.

        We recommend you try your settings out in a terminal prior to using SwiftMutator for the best configuration experience.
        We also recommend removing tests which you know are flaky from the set of tests that SwiftMutator exercises.
        """
    }

    static func baselineTestFailedEvidence(log: String) -> String {
        guard !log.trimmed.isEmpty else {
            return """
            SwiftMutator captured no output at all from your test command, so it has no log to show. That \
            normally means the command never started — check that "executable" in \
            \(MuterConfiguration.fileNameWithExtension) names a command SwiftMutator can launch.
            """
        }

        return """
        Here's the log your test command produced:

        \(log)
        """
    }
}

/// A `file:line:column: error: message` diagnostic parsed out of a compiler or test log.
struct CompilerError: Hashable, Sendable {
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
}

extension CompilerError {
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
    ) -> (path: String, line: Int, column: Int)? {
        guard line.contains("expanded code originates here") else { return nil }
        let text = FailedTestLine.withoutColours(line)
        guard let match = expansionOrigin.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let path = Range(match.range(at: 1), in: text),
              let number = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }),
              let column = Range(match.range(at: 3), in: text).flatMap({ Int(text[$0]) })
        else {
            return nil
        }
        return (String(text[path]), number, column)
    }

    /// `/path/to/File.swift:12:34: error: expected expression`. The path holds no `: `, so a diagnostic quoted after a
    /// label, such as `note: /path/File.swift:1:1: error: …`, isn't taken for one. The message runs to the end of the
    /// line; anything that doesn't have exactly this shape is not a diagnostic.
    private static let diagnostic = NSRegularExpression.regexWithPattern(
        #"^((?:(?!: ).)+?):([0-9]+):([0-9]+):\s+error:\s+(\S.*?)\s*$"#
    )

    private static func from(logLine: String) -> CompilerError? {
        let whole = NSRange(logLine.startIndex..., in: logLine)
        guard let match = diagnostic.firstMatch(in: logLine, range: whole),
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

private extension String {
    var lastPathComponent: String {
        URL(fileURLWithPath: self).lastPathComponent
    }
}
