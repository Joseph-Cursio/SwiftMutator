import Yams

/// The text of the `muter.conf.yml` that `init` writes: every configuration key, each under a comment that says what
/// it does and its default. `executable`, `arguments` and any key the configuration sets to other than its default are
/// written as YAML; every other is commented out, with its default or an example, so that removing the `# ` sets it.
enum ConfigurationFileText {
    struct Entry {
        let key: MuterConfiguration.CodingKeys
        /// What the key does, ending with its default.
        let comment: String
        /// The key with its default or an example, as YAML.
        let example: [String]
    }

    /// The keys in the order of README's Configuration table.
    static let entries: [Entry] = [
        Entry(
            key: .testCommandExecutable,
            comment: "The program that runs your tests, such as /usr/bin/swift or /usr/bin/xcodebuild, or a "
                + "script that runs them. It must be set.",
            example: ["executable: /usr/bin/swift"]
        ),
        Entry(
            key: .testCommandArguments,
            comment: "What executable is given to run the tests. With xcodebuild they must include -destination, "
                + "unless the destination key gives it, and mutants are tested on the first one; the workspace, "
                + "project, scheme and destination keys are added to them. They must be set.",
            example: ["arguments:", "- test"]
        ),
        Entry(
            key: .explicitBuildSystem,
            comment: "swift or xcodebuild, for an executable whose file name is neither, such as a wrapper script. "
                + "Default: from executable's file name.",
            example: ["buildSystem: xcodebuild"]
        ),
        Entry(
            key: .workspace,
            comment: "The Xcode workspace xcodebuild opens, relative to the project's folder, added to arguments as "
                + "-workspace; not with project. Default: what arguments give.",
            example: ["workspace: MyApp.xcworkspace"]
        ),
        Entry(
            key: .project,
            comment: "The Xcode project xcodebuild opens, relative to the project's folder, added to arguments as "
                + "-project; not with workspace. Default: what arguments give.",
            example: ["project: MyApp.xcodeproj"]
        ),
        Entry(
            key: .scheme,
            comment: "The scheme xcodebuild builds and tests, added to arguments as -scheme; arguments may name the "
                + "same one, not another. Default: what arguments give.",
            example: ["scheme: MyApp"]
        ),
        Entry(
            key: .destination,
            comment: "Where xcodebuild tests, as -destination takes it, or a list of them, added to arguments; "
                + "mutants are tested on the first. Default: the -destination in arguments.",
            example: ["destination: platform=iOS Simulator,name=iPhone 17 Pro"]
        ),
        Entry(
            key: .excludeFileList,
            comment: "Paths, path fragments and globs of files not to mutate, besides the defaults; an entry that "
                + "starts with ! keeps what it matches. Default: none besides the defaults.",
            example: ["exclude:", "- Sources/Generated"]
        ),
        Entry(
            key: .excludeCallList,
            comment: "Functions whose calls RemoveSideEffects never removes, such as a logging function. "
                + "Default: none.",
            example: ["excludeCalls:", "- log"]
        ),
        Entry(
            key: .coverageThreshold,
            comment: "A percent from 0 to 100: a file whose share of lines the tests ran is at or below it isn't "
                + "mutated. Default: 0, which leaves out only the files no test runs.",
            example: ["coverageThreshold: 0"]
        ),
        Entry(
            key: .operators,
            comment: "The operators to mutate with, at least one. Default: all of them, which are these.",
            example: ["operators:"] + MutationOperator.Id.allCases.map { "- \($0.rawValue)" }
        ),
        Entry(
            key: .skipOperators,
            comment: "The operators to leave out. Default: none.",
            example: ["skipOperators:", "- \(MutationOperator.Id.removeSideEffects.rawValue)"]
        ),
        Entry(
            key: .testSuiteTimeout,
            comment: "Seconds, above 0 and at most a day, before a mutant's test run is stopped. Default: from a "
                + "timed run of the tests with no mutant on.",
            example: ["mutationTestTimeout: 60"]
        ),
        Entry(
            key: .buildTimeout,
            comment: "Seconds, above 0 and at most a day, before each build or test run ahead of the first mutant "
                + "is stopped. Default: no limit.",
            example: ["buildTimeout: 1800"]
        ),
        Entry(
            key: .stopAtFirstFailure,
            comment: "Whether a mutant's test run stops at its first failed test, which already decides that it is "
                + "killed. SwiftPM, and xcodebuild on a simulator. Default: true.",
            example: ["stopAtFirstFailure: true"]
        ),
        Entry(
            key: .mutationTestWorkers,
            comment: "How many mutants to test at once, at least 1. Default: for SwiftPM, half the processors, at "
                + "most 4; for xcodebuild on a simulator, 2 on a Mac with 4 or more processors and 32 GB or more, "
                + "and 50 or more mutants; otherwise 1.",
            example: ["mutationTestWorkers: 2"]
        ),
        Entry(
            key: .workersShareBuild,
            comment: "Whether SwiftPM workers may test from one build when the tests write nothing in the project; "
                + "false gives each worker a copy of its own. Default: true.",
            example: ["workersShareBuild: true"]
        ),
        Entry(
            key: .oneWorkerSimulator,
            comment: "Whether one xcodebuild worker tests on a simulator SwiftMutator makes: true whenever the "
                + "destination is a simulator, false never, which also keeps the default count of xcodebuild "
                + "workers at 1. Default: when the project and its baseline show it is faster.",
            example: ["oneWorkerSimulator: true"]
        ),
        Entry(
            key: .keepAllLogs,
            comment: "Whether to keep the log of every mutant's test run. Default: false, which keeps only those "
                + "the results file can't stand in for.",
            example: ["keepAllLogs: false"]
        ),
        Entry(
            key: .keepLogFolders,
            comment: "How many runs' log folders to keep, this run's included, at least 2. Default: all of them.",
            example: ["keepLogFolders: 5"]
        ),
        Entry(
            key: .keepSwiftLintPhases,
            comment: "Whether SwiftLint build phases keep running in the copy of an Xcode project. Default: false, "
                + "which turns them off in the copy, never in your project.",
            example: ["keepSwiftLintPhases: false"]
        ),
        Entry(
            key: .failUnder,
            comment: "A percent from 0 to 100: a finished run whose score is below it exits with status 2. "
                + "Default: no score is checked.",
            example: ["failUnder: 80"]
        ),
        Entry(
            key: .baseline,
            comment: "A baseline file, which --write-baseline saves, relative to the project's folder: a finished run "
                + "with more new survivors than maxNewSurvivors allows exits with status 2. Every run that tests reads "
                + "it, and exits with status 8 if it can't, so commit it with this key. Default: none.",
            example: ["baseline: muter.baseline.yml"]
        ),
        Entry(
            key: .maxNewSurvivors,
            comment: "How many new survivors pass, against the baseline file, 0 or more. Needs baseline. Default: 0.",
            example: ["maxNewSurvivors: 0"]
        ),
        Entry(
            key: .maxScoreDrop,
            comment: "How many points, from 0 to 100, a finished whole run's score may fall below the baseline "
                + "file's before it exits with status 2. Needs baseline. Default: the score isn't compared.",
            example: ["maxScoreDrop: 2"]
        ),
        Entry(
            key: .maxDoubtfulKills,
            comment: "How many kills may be in doubt, 0 or more, before a finished run exits with status 2: those "
                + "only suspect tests made, and those whose code never ran. Default: none are counted.",
            example: ["maxDoubtfulKills: 5"]
        ),
        Entry(
            key: .suspectTestFilePercent,
            comment: "The share of the files with a killed mutant, from 1 to 100, that a test must have failed for "
                + "mutants in to be suspect. Default: \(SuspectTestThresholds.standard.filePercent).",
            example: ["suspectTestFilePercent: \(SuspectTestThresholds.standard.filePercent)"]
        ),
        Entry(
            key: .suspectTestMinimumFiles,
            comment: "How many such files there must be, at least 1, before a test can be suspect. "
                + "Default: \(SuspectTestThresholds.standard.minimumFiles).",
            example: ["suspectTestMinimumFiles: \(SuspectTestThresholds.standard.minimumFiles)"]
        ),
        Entry(
            key: .controlRunEvery,
            comment: "How many mutants to test for each run with no mutant on, whose failed tests are flaky; 0 for "
                + "none. Default: \(MuterConfiguration.defaultMutantsPerControlRun).",
            example: ["controlRunEvery: \(MuterConfiguration.defaultMutantsPerControlRun)"]
        ),
        Entry(
            key: .suspectKillReruns,
            comment: "How many kills to test again alone because only suspect tests failed for them; 0 for none. "
                + "Default: \(MuterConfiguration.defaultSuspectKillReruns).",
            example: ["suspectKillReruns: \(MuterConfiguration.defaultSuspectKillReruns)"]
        ),
        Entry(
            key: .propertyTests,
            comment: "Globs that pick out property tests, by name or by file, so the reports split each kill "
                + "between example tests and property tests. Default: none.",
            example: ["propertyTests:", "- \"*Properties*\""]
        ),
        Entry(
            key: .propertyTestFilter,
            comment: "Test filters that select the property tests alone, as swift test --filter or xcodebuild's "
                + "-only-testing: takes them, to test kills by examples alone again with only them and, under "
                + "SwiftPM, kills by properties alone again with every test but them, at the cost of a run close to "
                + "a whole test run. Needs propertyTests. Default: none.",
            example: ["propertyTestFilter:", "- MyPackageTests.Properties"]
        ),
        Entry(
            key: .propertySurvivorReruns,
            comment: "How many times to test each survivor again with only the property tests propertyTestFilter "
                + "selects, stopping at the first run that doesn't pass, as a property tries a sample of inputs; 0 for "
                + "none. It changes no result. Needs propertyTestFilter. Default: none.",
            example: ["propertySurvivorReruns: 10"]
        ),
        Entry(
            key: .propertySurvivorRerunLimit,
            comment: "How many survivors to test again with the property tests, in a whole run; 0 for none. "
                + "Default: \(MuterConfiguration.defaultPropertySurvivorRerunLimit).",
            example: ["propertySurvivorRerunLimit: \(MuterConfiguration.defaultPropertySurvivorRerunLimit)"]
        ),
        Entry(
            key: .reports,
            comment: "More reports for a run to save, each format:path. Default: none.",
            example: ["reports:", "- markdown:mutation-report.md"]
        ),
    ]

    static let header = [
        "# SwiftMutator's configuration, written by `swift-mutator init`. Keep it at the project's root, and",
        "# commit it. A key commented out is at its default: remove its `# ` to set it. SwiftMutator's README",
        "# says more of each key, in Configuration.",
    ]

    static let width = 100

    static func text(for configuration: MuterConfiguration) throws -> String {
        let written = try values(of: configuration)
        let defaults = try values(of: MuterConfiguration())
        var lines = header
        for entry in entries {
            let name = entry.key.rawValue
            lines.append("")
            lines += wrapped(entry.comment, width: width - 2).map { "# \($0)" }
            let isAlwaysWritten = entry.key == .testCommandExecutable || entry.key == .testCommandArguments
            if let value = written[name], isAlwaysWritten || value != defaults[name] {
                // Only the final line break goes: a blank line inside a value is part of it, as a line break in a
                // quoted string is written.
                var yaml = try Yams.serialize(node: Node([(Node(name), value)]))
                if yaml.hasSuffix("\n") {
                    yaml.removeLast()
                }
                lines += yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            } else {
                lines += entry.example.map { "# \($0)" }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
