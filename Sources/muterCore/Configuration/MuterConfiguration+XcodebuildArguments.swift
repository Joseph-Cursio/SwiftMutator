import Foundation
import Yams

extension MuterConfiguration {
    /// Coverage counts each run of a piece of code by loading its counter and storing one more, so code that runs on
    /// two threads at once loses runs: Swift Testing runs tests in parallel, and a test can run code concurrently
    /// itself. A count worked out from two others, such as the code after a `guard`, then reads 0 though the code ran,
    /// and its mutants are left out. Atomic counters keep every run. On SwiftProjectLint they made the coverage run's
    /// tests take 9.3 s rather than 7.2 s; running the tests one at a time took 11.4 s and still lost counts.
    static let atomicCoverageCountersFlags = ["-Xllvm", "-instrprof-atomic-counter-update-all"]

    var enableCoverageArguments: [String] {
        var arguments = testCommandArguments

        switch buildSystem {
        case .xcodebuild:
            arguments = XcodebuildArguments(arguments).forTheCoverageRun
            // A setting given twice takes the second, so a project's own `OTHER_SWIFT_FLAGS=…` gets the flags added.
            let flags = Self.atomicCoverageCountersFlags.joined(separator: " ")
            if let index = arguments.firstIndex(where: { $0.hasPrefix("OTHER_SWIFT_FLAGS=") }) {
                arguments[index] += " " + flags
            } else {
                arguments.append("OTHER_SWIFT_FLAGS=$(inherited) " + flags)
            }
            return arguments + ["-enableCodeCoverage", "YES"]

        case .swift:
            return arguments + ["--enable-code-coverage"]
                + Self.atomicCoverageCountersFlags.flatMap { ["-Xswiftc", $0] }

        case .unknown:
            return arguments
        }
    }

    var buildForTestingArguments: [String] {
        let arguments = testCommandArguments

        switch buildSystem {
        case .xcodebuild:
            return testArgumentsWithDerivedData() + ["clean", "build-for-testing"]

        case .swift,
             .unknown:
            return arguments
        }
    }

    /// `buildForTestingArguments` for a build after one that failed, which only what changed needs: without the `clean`
    /// that adds, and any argument of the test command's own that says the same is left alone.
    var rebuildForTestingArguments: [String] {
        Array(buildForTestingArguments.dropLast(2)) + ["build-for-testing"]
    }

    var derivedDataPath: String {
        guard let index = derivedDataArgumentIndex() else {
            return defaultDerivedData
        }

        return testCommandArguments[index + 1]
    }

    private var defaultDerivedData: String { "DerivedData" }

    /// The test command's arguments for a run on the build the baseline made: a mutant's, or the one that times them
    /// with no mutant on. For SwiftPM they skip the build, and add `--quiet` unless `arguments` already set how much
    /// to print. `swift test` passes it on to Swift Testing, as the direct runs' script passes it to its helper (see
    /// `DirectTestRun`), which then prints no line for each test or suite that starts or passes: on SwiftProjectLint,
    /// more than 10,000 of a surviving mutant's 12,500 lines. It still prints every line SwiftMutator reads: each
    /// recorded issue, the run's summary, the tests' own output, and SwiftPM's lines for a crash. XCTest's output
    /// doesn't change. For xcodebuild they test from `testRunFile` on the first `-destination`, unless `xcodeWorker`
    /// names another file or destination, with the test command's own arguments that such a run keeps
    /// (`XcodebuildArguments.forARunFromTheTestRunFile(worker:filtered:)`), then the worker's own.
    func testWithoutBuildArguments(with testRunFile: String) -> [String] {
        let arguments = testCommandArguments
        switch buildSystem {
        case .xcodebuild:
            guard let destination = xcodeWorker?.destination ?? firstDestination else {
                return arguments
            }
            let kept = XcodebuildArguments(arguments).forARunFromTheTestRunFile(
                worker: xcodeWorker,
                filtered: !testFilterArguments.isEmpty
            )
            return [
                "test-without-building",
                "-destination",
                destination,
                "-xctestrun",
                xcodeWorker?.testRunFile ?? testRunFile,
            ] + kept + (xcodeWorker?.arguments ?? []) + testFilterArguments

        case .swift:
            let setsVerbosity = arguments.contains { Self.verbosityOptions.contains($0) }
            return arguments + ["--skip-build"] + (setsVerbosity ? [] : ["--quiet"]) + testFilterArguments

        case .unknown:
            return arguments
        }
    }

    /// The value of the test command's first `-destination`, or nil if it gives none.
    var firstDestination: String? {
        indexOfArgument("-destination").flatMap { index in
            index + 1 < testCommandArguments.count ? testCommandArguments[index + 1] : nil
        }
    }

    /// `swift test`'s options that say how much it, and Swift Testing, print.
    private static let verbosityOptions: Set = ["-q", "--quiet", "-v", "--verbose", "--very-verbose", "--vv"]

    private func indexOfArgument(_ arg: String) -> Int? {
        testCommandArguments.firstIndex(of: arg)
    }

    private func derivedDataArgumentIndex() -> Int? {
        indexOfArgument("-derivedDataPath")
    }

    /// The test command's arguments for the build for testing, before its actions: all but `test`, whether or not
    /// they give a `-derivedDataPath`, as `test` would build and run every test in the build's place, and with
    /// `-derivedDataPath DerivedData` when they give none, which `derivedDataPath` then names.
    private func testArgumentsWithDerivedData() -> [String] {
        let arguments = XcodebuildArguments(testCommandArguments).forTheBuild
        guard derivedDataArgumentIndex() == nil else {
            return arguments
        }
        return arguments + ["-derivedDataPath", defaultDerivedData]
    }
}
