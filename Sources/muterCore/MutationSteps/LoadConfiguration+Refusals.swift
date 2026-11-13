extension LoadConfiguration {
    /// Why one of `configuration`'s values can't be used, the run's flags already in, or nil. Checked here rather than
    /// in decoding, as a results file's header holds what an earlier version took, which a resume must still read.
    static func valueOutOfRange(in configuration: MuterConfiguration) -> String? {
        // As `--timeout` and `--build-timeout` are, which take their place: 0 would stop every run at once, below 0
        // traps, and a limit past a day is a mistake.
        let timeouts = [
            ("mutationTestTimeout", configuration.testSuiteTimeout),
            ("buildTimeout", configuration.buildTimeout),
        ]
        let longest = TestingArguments.longestTimeout
        for case let (key, seconds?) in timeouts where !(seconds > 0 && seconds <= longest) {
            return "\(key) must be a number of seconds above 0, and at most a day (86400), not \(Self.shown(seconds))."
        }
        // As `--workers` is: an earlier version took 0 or less as 1.
        if let workers = configuration.mutationTestWorkers, workers < 1 {
            return "mutationTestWorkers must be a whole number, at least 1, not \(workers)."
        }
        if !(0 ... 100).contains(configuration.coverageThreshold) {
            return "coverageThreshold must be a percentage from 0 to 100, "
                + "not \(Self.shown(configuration.coverageThreshold))."
        }
        return nil
    }

    /// Why an xcodebuild test command's `arguments` would break SwiftMutator's own calls of it, or nil
    /// (`XcodebuildArguments.refusal`): an `executable` that is a wrapper script with `buildSystem: xcodebuild` is
    /// given the same arguments, so it is checked too. Another build system's arguments aren't xcodebuild's.
    static func argumentRefused(in configuration: MuterConfiguration) -> String? {
        guard configuration.buildSystem == .xcodebuild else { return nil }
        return XcodebuildArguments(configuration.testCommandArguments).refusal
    }

    /// `value` in plain decimal digits, as written, so a refusal never names a rounded value that is in range, as
    /// `%g` shows 86400.01 as 86400.
    private static func shown(_ value: Double) -> String {
        ScoreGate.shown(value)
    }

    /// Why `generated`, from a folder with a Package.swift, an Xcode workspace or an Xcode project at its top, has no
    /// test command: the project's `project.pbxproj` can't be read, or `which` found no `swift` or `xcodebuild`.
    static func noTestCommand(in generated: GeneratedConfiguration, missing: String) -> String {
        guard !generated.configuration.testCommandArguments.isEmpty else {
            return "\(missing), and SwiftMutator can't read the project.pbxproj of the Xcode project at the top of the "
                + "project's folder to work out a test command from."
        }
        let tool = generated.scheme == nil ? "swift" : "xcodebuild"
        return "\(missing), and SwiftMutator could not find \"\(tool)\" on your PATH to run the project's tests with."
    }
}
