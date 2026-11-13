import Foundation

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

            \(Self.failedTestsAndEvidence(log: log))
            """

        case let .buildForTestingFailed(description, log):
            let kept = log.map { "\n\nThe build's log is in \($0)." } ?? ""
            return """
            \(description)\(kept)

            SwiftMutator tested no mutant. First check that your unmutated project builds for testing with the \
            "executable" and "arguments" in your \(MuterConfiguration.fileNameWithExtension). If it does, the errors \
            are in code SwiftMutator rewrote: in a test plan's copy, fix the mutant there, or make the plan again \
            without its operator. Any other run takes mutants that don't compile out of the build, so an error in the \
            code SwiftMutator adds around them is a bug in SwiftMutator: please report it at \
            https://github.com/Joseph-Cursio/SwiftMutator/issues.
            """

        case let .buildTimeoutReached(step, seconds, output, log):
            return Self.buildTimeoutReachedDescription(step: step, seconds: seconds, output: output, log: log)

        case .tooManyBuildErrors:
            return """
            SwiftMutator noticed the last 5 attempts to apply a mutation operator resulted in a build error within \
            your code base.
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

        case let .noMutantCodeShownRunning(runs):
            return """
            SwiftMutator stopped after \(runs) mutants: none of their test runs read the mutants' switches, though the \
            coverage run shows the tests reach these mutants, so no mutant was switched on, and every one would have \
            survived. A test command that runs `swift test` through a wrapper must pass \(activeMutantFileKey) on to \
            it.

            --resume tests these mutants again once that is fixed.
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

extension MutationTestingAbortReason {
    /// The tests `log` shows failing, up to `FailedTestLine.killedByLimit`, a line each, and how many more failed, or
    /// nil if it shows none: what the whole log, which follows, can bury.
    static func failedTestsList(in log: String) -> String? {
        let failed = FailedTestLine.failedTests(inLog: log)
        guard failed.total > 0 else { return nil }
        let (names, more) = failed.named(upTo: FailedTestLine.killedByLimit)
        let heading = failed.total == 1 ? "This test failed:" : "These \(failed.total) tests failed:"
        let lines = names.map { "  \($0)" } + (more > 0 ? ["  and \(more) more"] : [])
        return ([heading] + lines).joined(separator: "\n")
    }
}

private extension MutationTestingAbortReason {
    static func baselineTestFailedDescription(
        log: String,
        mutatedFilePaths: [String]
    ) -> String {
        """
        \(baselineTestFailedCause(log: log, mutatedFilePaths: mutatedFilePaths))

        \(failedTestsAndEvidence(log: log))
        """
    }

    /// The tests a failed baseline's `log` shows failing, if any, then the log.
    static func failedTestsAndEvidence(log: String) -> String {
        [failedTestsList(in: log), baselineTestFailedEvidence(log: log)].compactMap(\.self).joined(separator: "\n\n")
    }

    /// How many of the last lines of a stopped step's output its abort message shows: where it hung.
    static let lastLinesShown = 20

    static func buildTimeoutReachedDescription(
        step: BuildStep,
        seconds: Double,
        output: String,
        log: String?
    ) -> String {
        let what = switch step {
        case .buildForTesting:
            "xcodebuild's build for testing"

        case .baseline:
            "the baseline run, which builds your project and runs its tests with no mutant switched on,"

        case let .workerBaseline(worker, directory):
            "the baseline run in the copy it made for parallel worker \(worker), at \(directory),"
        }
        let limit = String(format: "%g", seconds)
        let kept = log.map { "Its log is in \($0)." } ?? "It kept no log."
        let lines = output.split(whereSeparator: \.isNewline).suffix(lastLinesShown)
        let printed = lines.isEmpty
            ? "\(kept) It printed nothing."
            : "\(kept) The last lines it printed:\n\n" + lines.joined(separator: "\n")
        return [
            "SwiftMutator stopped \(what) after \(limit) s, the limit buildTimeout or --build-timeout sets, and "
                + "tested no mutant.",
            failedTestsList(in: output),
            printed,
            "If the build and its tests need longer, raise buildTimeout, or --build-timeout, which takes its place. If "
                + "they hang, the last lines show where.",
        ].compactMap(\.self).joined(separator: "\n\n")
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
            its copy as it is, so there this is most likely a mutant that doesn't compile. Fix it in the copy, or make \
            the plan again without its operator. Any other run takes such a mutant out of the build, so there this is \
            most likely a bug in SwiftMutator's own rewriting rather than a problem with your \
            \(MuterConfiguration.fileNameWithExtension). Please report that bug at \
            https://github.com/Joseph-Cursio/SwiftMutator/issues and include the log below.
            """
        }

        if let crash = crashThatMayBeAStackOverflow(in: log, mutatedFilePaths: mutatedFilePaths) {
            return """
            SwiftMutator could not establish a baseline because a test process crashed, with no mutant switched on:

              \(crash.line)

            First check that your tests pass in your unmutated project. If they do, \(crash.reason) a stack overflow. \
            Each mutant adds a copy of the code around it, and a debug build gives each copy's local variables their \
            own stack space, so a function can need many times the stack it did, and one that recurses deeply can run \
            out.

            On a Mac, the crash report in ~/Library/Logs/DiagnosticReports says "Thread stack size exceeded" if that's \
            what happened, and the function that repeats at the top of its crashed thread is the one. Leave that \
            function's file out with the "exclude" option in your \(MuterConfiguration.fileNameWithExtension), or \
            put // muter:disable-declaration above the function. A test plan needs making again after that.
            """
        }

        return """
        SwiftMutator noticed that your test suite initially failed to compile or produced a test failure.

        Assuming you have no build errors, this is usually due to misconfiguring the "executable" and \
        "arguments" options inside of your \(MuterConfiguration.fileNameWithExtension).
        Alternatively, it could mean you have a nondeterministic test failure in your test suite.

        We recommend you try your settings out in a terminal prior to using SwiftMutator for the best configuration \
        experience.
        We also recommend removing tests which you know are flaky from the set of tests that SwiftMutator exercises.
        """
    }

    /// The line of a baseline's `log` that shows a crash that running out of stack could have caused, and how sure that
    /// is. Nothing in a log says it was: only a crash report does. xcodebuild doesn't give the signal, and restarts
    /// after a timeout too. nil when SwiftMutator rewrote no file, as nothing then has grown.
    static func crashThatMayBeAStackOverflow(
        in log: String,
        mutatedFilePaths: [String]
    ) -> (line: String, reason: String)? {
        guard !mutatedFilePaths.isEmpty else { return nil }
        if let line = CrashLine.firstMemoryFault(inLog: log) {
            return (line, "the likely reason is")
        }
        let restarted = log.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("Restarting after unexpected exit, crash, or test timeout") }
        return restarted.map { (String($0), "one possible reason is") }
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
