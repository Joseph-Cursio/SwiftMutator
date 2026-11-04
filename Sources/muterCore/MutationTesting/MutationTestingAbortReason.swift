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
            SwiftMutator could not establish a baseline because a file it had mutated failed to compile:

              \(error.description)

            SwiftMutator rewrites the files it mutates before running your test suite, so a compile error in \
            \(error.fileName) is most likely a bug in SwiftMutator's own rewriting rather than a problem with \
            your \(MuterConfiguration.fileNameWithExtension).

            Please report this at https://github.com/Joseph-Cursio/SwiftMutator/issues and include \
            the log below. To rule out a pre-existing error, check that \(error.fileName) compiles in \
            your unmutated project.
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
struct CompilerError: Equatable {
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
    /// The first compile error in `log` reported against any of `filePaths`.
    ///
    /// Matching is by file name rather than full path: the log's paths point into SwiftMutator's copy of the
    /// project, while the paths SwiftMutator records for its mutants are relative to the original.
    static func first(
        in log: String,
        inFilesAt filePaths: [String]
    ) -> CompilerError? {
        let fileNames = Set(filePaths.map(\.lastPathComponent))

        return all(in: log).first { fileNames.contains($0.fileName) }
    }

    static func all(in log: String) -> [CompilerError] {
        log.split(separator: "\n").compactMap { from(logLine: String($0)) }
    }

    /// Parses one `/path/to/File.swift:12:34: error: expected expression` line. The message runs to the
    /// end of the line; anything that doesn't have exactly this shape is not a diagnostic.
    private static func from(logLine: String) -> CompilerError? {
        let components = logLine.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard components.count == 5,
              let line = Int(components[1]),
              let column = Int(components[2]),
              String(components[3]).trimmed == "error",
              !String(components[4]).trimmed.isEmpty
        else {
            return nil
        }

        return CompilerError(
            filePath: String(components[0]),
            line: line,
            column: column,
            message: String(components[4]).trimmed
        )
    }
}

private extension String {
    var lastPathComponent: String {
        URL(fileURLWithPath: self).lastPathComponent
    }
}
