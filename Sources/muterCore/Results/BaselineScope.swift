import Foundation

/// What a baseline file records of the run it was written from, and `--baseline` compares with the run that checks it:
/// the operators, `skipCoverage`, and the configuration keys a resume compares (`ResumeCheck`), but for `executable`,
/// an absolute path that differs between machines. Two runs that differ in any of these discover different mutants, or
/// judge them differently, so their survivors can't be compared. Not what `--since`, `--shard`, `--sample` or
/// `--files-to-mutate` choose: a run limited so is compared only on the mutants it tested.
struct BaselineScope: Equatable {
    /// The operators by name, sorted, once each.
    let operators: [String]
    let skipCoverage: Bool
    let configuration: Configuration

    /// The configuration keys compared, under their own names.
    struct Configuration: Codable, Equatable {
        let arguments: [String]
        /// `buildSystem:` as written; nil when it isn't set.
        let buildSystem: String?
        let coverageThreshold: Double
        /// Sorted, once each, as `--exclude`'s entries come after the file's.
        let exclude: [String]
        let excludeCalls: [String]
        /// nil when it isn't set: the default comes from the baseline run's time.
        let mutationTestTimeout: Double?

        init(
            arguments: [String] = [],
            buildSystem: String? = nil,
            coverageThreshold: Double = 0,
            exclude: [String] = [],
            excludeCalls: [String] = [],
            mutationTestTimeout: Double? = nil
        ) {
            self.arguments = arguments
            self.buildSystem = buildSystem
            self.coverageThreshold = coverageThreshold
            self.exclude = Set(exclude).sorted()
            self.excludeCalls = excludeCalls
            self.mutationTestTimeout = mutationTestTimeout
        }

        /// `configuration`'s keys that are compared, after the flags that override them.
        init(_ configuration: MuterConfiguration) {
            self.init(
                arguments: configuration.testCommandArguments,
                buildSystem: configuration.explicitBuildSystem?.rawValue,
                coverageThreshold: configuration.coverageThreshold,
                exclude: configuration.excludeFileList,
                excludeCalls: configuration.excludeCallList,
                mutationTestTimeout: configuration.testSuiteTimeout
            )
        }

        /// A configuration with these keys, and every other as no file sets it, which `ResumeCheck` compares.
        var asMuterConfiguration: MuterConfiguration {
            MuterConfiguration(
                arguments: arguments,
                excludeList: exclude,
                excludeCallList: excludeCalls,
                coverageThreshold: coverageThreshold,
                testSuiteTimeOut: mutationTestTimeout,
                // Never `unknown`, which an earlier version wrote for any value but these, and then ignored.
                buildSystem: buildSystem.flatMap(BuildSystem.init(written:))
            )
        }
    }

    init(operators: [String], skipCoverage: Bool, configuration: Configuration) {
        self.operators = Set(operators).sorted()
        self.skipCoverage = skipCoverage
        self.configuration = configuration
    }

    /// What a run with `configuration`, after its flags, `operators` and `skipCoverage` records.
    init(configuration: MuterConfiguration, operators: [MutationOperator.Id], skipCoverage: Bool) {
        self.init(
            operators: operators.map(\.rawValue),
            skipCoverage: skipCoverage,
            configuration: Configuration(configuration)
        )
    }

    /// What `header`'s session recorded.
    init(header: ResultsHeader) {
        self.init(
            operators: header.operators,
            skipCoverage: header.skipCoverage,
            configuration: Configuration(header.configuration)
        )
    }

    /// How this scope differs from the `recorded` one, a baseline file's, by name: the operators, `skipCoverage`, then
    /// each configuration key that differs, by name, as a resume says them (`ResumeCheck.configurationDifferences`).
    /// Empty when they're the same.
    func differences(from recorded: Self) -> [ResumeCheck.Difference] {
        var differences: [ResumeCheck.Difference] = []
        if operators != recorded.operators {
            differences.append(
                .init(name: "operators", was: Self.json(recorded.operators), isNow: Self.json(operators))
            )
        }
        if skipCoverage != recorded.skipCoverage {
            differences.append(
                .init(name: "skipCoverage", was: "\(recorded.skipCoverage)", isNow: "\(skipCoverage)")
            )
        }
        return differences + ResumeCheck.configurationDifferences(
            recorded.configuration.asMuterConfiguration,
            configuration.asMuterConfiguration
        )
    }

    /// `values` as JSON on one line: `["RelationalBoundary","SwapTernary"]`.
    private static func json(_ values: [String]) -> String {
        (try? JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes]))
            .map { String(lossyUTF8: $0) } ?? "\(values)"
    }
}
