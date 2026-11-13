/// An xcodebuild test command's arguments, read one at a time: each action, such as `test`, each option with its value,
/// if it takes one, and anything else, such as a build setting. An option takes the argument after it as its value only
/// if xcodebuild takes a value for it (`optionsWithAValue`), so in `-scheme test` the `test` is a value, not an action.
/// An option it doesn't list is taken to stand alone, so that a wrapper script's own flag and its value are both kept
/// wherever they are.
struct XcodebuildArguments: Equatable {
    /// What an `Argument` is.
    enum ArgumentKind: Equatable {
        case action
        case option
        /// A build setting, as `SWIFT_TREAT_WARNINGS_AS_ERRORS=NO`, or anything else that is neither.
        case other
    }

    /// One action, option or other argument, as the test command gives it.
    struct Argument: Equatable {
        let kind: ArgumentKind
        /// The action, or the option's name, as `-only-testing` for `-only-testing:AppTests`; any other argument as it
        /// is written.
        let name: String
        /// The argument as written, then its value if it takes one.
        let written: [String]
    }

    let arguments: [Argument]

    init(_ written: [String]) {
        var parsed: [Argument] = []
        var index = 0
        while index < written.count {
            let argument = written[index]
            if Self.actions.contains(argument) {
                parsed.append(Argument(kind: .action, name: argument, written: [argument]))
            } else if argument.hasPrefix("-") {
                let name = argument.split(separator: ":", maxSplits: 1).first.map(String.init) ?? argument
                let takesAValue = name == argument && Self.optionsWithAValue.contains(name) && index + 1 < written.count
                parsed.append(Argument(
                    kind: .option,
                    name: name,
                    written: takesAValue ? [argument, written[index + 1]] : [argument]
                ))
                index += takesAValue ? 1 : 0
            } else {
                parsed.append(Argument(kind: .other, name: argument, written: [argument]))
            }
            index += 1
        }
        self.arguments = parsed
    }

    /// The arguments as written, less those `isLeftOut` picks, each with its value.
    func leavingOut(_ isLeftOut: (Argument) -> Bool) -> [String] {
        arguments.filter { !isLeftOut($0) }.flatMap(\.written)
    }

    /// xcodebuild's actions, as its man page lists them.
    static let actions: Set = [
        "build", "build-for-testing", "analyze", "archive", "test", "test-without-building", "docbuild", "installsrc",
        "install", "clean",
    ]

    /// The options that take a value, as xcodebuild's `-help` and man page describe them in Xcode 27.2, less those that
    /// only start another kind of run than a build or a test, such as `-exportArchive`'s. `-help` writes no value for
    /// some of them, such as `-xctestrun` and `-testPlan`, though they take one. `-only-testing` and `-skip-testing`
    /// take one too when written without the `:`, as `-only-testing AppTests` or `-only-testing @tests.txt`.
    static let optionsWithAValue: Set = [
        "-project", "-target", "-workspace", "-scheme", "-configuration", "-xcconfig", "-arch", "-sdk", "-toolchain",
        "-destination", "-destination-timeout", "-jobs", "-maximum-concurrent-test-device-destinations",
        "-maximum-concurrent-test-simulator-destinations", "-parallel-testing-enabled",
        "-parallel-testing-worker-count", "-maximum-parallel-testing-workers", "-enableAddressSanitizer",
        "-enableThreadSanitizer",
        "-enableUndefinedBehaviorSanitizer", "-resultBundlePath", "-resultStreamPath", "-resultBundleVersion",
        "-clonedSourcePackagesDirPath", "-derivedDataPath", "-archivePath", "-enableCodeCoverage",
        "-enableCodesizeProfile", "-codesizeProfileOutputDir", "-xctestrun", "-testProductsPath",
        "-enablePerformanceTestsDiagnostics", "-testPlan", "-only-testing", "-skip-testing", "-test-timeouts-enabled",
        "-default-test-execution-time-allowance", "-maximum-test-execution-time-allowance", "-test-iterations",
        "-test-repetition-relaunch-enabled", "-only-test-configuration", "-skip-test-configuration",
        "-collect-test-diagnostics", "-testLanguage", "-testRegion", "-test-enumeration-style",
        "-test-enumeration-format", "-test-enumeration-output-path", "-packageCachePath",
        "-packageAuthorizationProvider", "-defaultPackageRegistryURL", "-packageDependencySCMToRegistryTransformation",
        "-packageFingerprintPolicy", "-packageSigningEntityPolicy", "-authenticationKeyPath", "-authenticationKeyID",
        "-authenticationKeyIssuerID", "-scmProvider",
    ]

    /// The options that set xcodebuild's parallel testing, which a worker that tests one test at a time leaves out:
    /// xcodebuild refuses a second `-parallel-testing-enabled`, and the others tune what that turns off.
    static let parallelTestingOptions: Set = [
        "-parallel-testing-enabled", "-parallel-testing-worker-count", "-maximum-parallel-testing-workers",
        "-parallelize-tests-among-destinations",
    ]

    /// The test command's arguments for an xcodebuild run from an `.xctestrun`, a mutant's, beside the
    /// `test-without-building`, `-destination` and `-xctestrun` the run is given, `worker`'s own arguments and the
    /// `-only-testing:` of a test filter, when `filtered`. So the options that say which tests run and how, such as
    /// `-only-testing`, `-skip-testing`, `-test-iterations` and `-parallel-testing-worker-count`, hold for every
    /// mutant as they did for the baseline. Left out, each with its value:
    ///
    /// - every action, as the run's own is `test-without-building`, which xcodebuild won't take with `clean`;
    /// - `-project`, `-workspace` and `-scheme`, which xcodebuild refuses with `-xctestrun`, and `-testPlan`, which
    ///   the `.xctestrun` already holds, as the build for testing had it;
    /// - every `-destination`, as the run tests on the one it is given;
    /// - `-quiet`, which hides the lines that tell a failed test from a crash, so a kill would read as a runtime error;
    /// - `-resultStreamPath`, so each run doesn't write over the baseline's stream;
    /// - `-enableCodeCoverage`, as gathering coverage would slow every run, and the build for testing already had it;
    /// - what `LoadConfiguration` refuses, should a configuration it didn't load have it: `-xctestrun`,
    ///   `-testProductsPath`, `-resultBundlePath` and `-enumerate-tests`;
    /// - `-derivedDataPath`, `-collect-test-diagnostics` and the parallel testing options, when `worker` sets them
    ///   itself, as xcodebuild takes `-derivedDataPath` and `-parallel-testing-enabled` only once;
    /// - `-only-testing`, when `filtered`: xcodebuild runs every test any `-only-testing` names, so a broader one would
    ///   undo the filter. `-skip-testing` still holds, as xcodebuild leaves out what it names from the rest.
    ///
    /// Build settings, and options that only a build reads, such as `-configuration`, are kept: xcodebuild takes them
    /// on such a run and ignores them, and a wrapper script may read them.
    func forARunFromTheTestRunFile(worker: MuterConfiguration.XcodeWorker?, filtered: Bool) -> [String] {
        leavingOut { argument in
            switch (argument.kind, argument.name) {
            case (.action, _):
                return true

            case (.option, "-derivedDataPath"):
                return worker != nil

            case (.option, "-collect-test-diagnostics"):
                return worker?.testDiagnosticsOff == true

            case let (.option, name) where Self.parallelTestingOptions.contains(name):
                return worker?.parallelTestingOff == true

            case (.option, "-only-testing"):
                return filtered

            case let (.option, name):
                return Self.leftOutOfARunFromTheTestRunFile.contains(name)

            case (.other, _):
                return false
            }
        }
    }

    /// The options `forARunFromTheTestRunFile(worker:filtered:)` always leaves out.
    private static let leftOutOfARunFromTheTestRunFile: Set = [
        "-project", "-workspace", "-scheme", "-testPlan", "-destination", "-quiet", "-resultStreamPath", "-xctestrun",
        "-testProductsPath", "-resultBundlePath", "-enableCodeCoverage", "-enumerate-tests",
    ]

    /// The test command's arguments for SwiftMutator's build for testing, before its own actions: all of them but
    /// `test`, which would test the whole project in the build's place, and `build`, which would build it a second
    /// time for nothing.
    var forTheBuild: [String] {
        leavingOut { $0.kind == .action && ($0.name == "test" || $0.name == "build") }
    }

    /// The test command's arguments for SwiftMutator's coverage run, before it adds `-enableCodeCoverage YES`: all of
    /// them but their own `-enableCodeCoverage`, with its value, as xcodebuild takes the option only once. The build
    /// for testing and the baseline still have it, so a `-enableCodeCoverage NO` still builds the `.xctestrun` that
    /// every mutant runs from without coverage.
    var forTheCoverageRun: [String] {
        leavingOut { $0.kind == .option && $0.name == "-enableCodeCoverage" }
    }

    /// Why SwiftMutator can't make its own xcodebuild calls with these arguments, or nil when it can: the coverage run
    /// and the build for testing add actions and options of their own to them, the baseline runs them as they are, and
    /// a mutant's run tests with `test-without-building` from an `.xctestrun`. Only `test`, `clean` and `build` are
    /// taken as actions: `clean test` cleans before the baseline as before, and the build for testing starts with a
    /// `clean` anyway; `build test` builds before the baseline, and the build for testing leaves `build` out.
    var refusal: String? {
        for argument in arguments {
            if let reason = Self.refusal(of: argument) {
                return reason
            }
        }
        return nil
    }

    private static func refusal(of argument: Argument) -> String? {
        let name = argument.name
        switch (argument.kind, name) {
        case (.action, "test"),
             (.action, "clean"),
             (.action, "build"):
            return nil

        case (.action, "build-for-testing"),
             (.action, "test-without-building"):
            return "`\(name)` in `arguments` is an action SwiftMutator runs itself: it builds once with "
                + "`build-for-testing`, then tests each mutant with `test-without-building`. Give `test` as the action "
                + "instead."

        case (.action, _):
            return "`\(name)` in `arguments` isn't an action SwiftMutator can test with: it runs your tests with "
                + "`test`, and builds them with `build-for-testing` itself. Give `test` as the action instead."

        case (.option, "-xctestrun"):
            return "`-xctestrun` in `arguments` names what SwiftMutator tests each mutant from itself, the "
                + "`.xctestrun` its build for testing writes. Leave it out, and name the project or workspace and the "
                + "scheme to build, with `-project` or `-workspace` and `-scheme`."

        case (.option, "-testProductsPath"):
            return "`-testProductsPath` in `arguments` can't be used: each mutant's run tests from the `.xctestrun` "
                + "SwiftMutator's build for testing writes, which xcodebuild won't take with it. Leave it out."

        case (.option, "-resultBundlePath"):
            return "`-resultBundlePath` in `arguments` would have SwiftMutator's coverage run, build for testing and "
                + "baseline write one result bundle, and xcodebuild fails a run whose bundle is already there. Leave "
                + "it out."

        case (.option, "-enumerate-tests"):
            return "`-enumerate-tests` in `arguments` lists the tests without running them, so every mutant would "
                + "survive. Leave it out."

        default:
            return nil
        }
    }
}
