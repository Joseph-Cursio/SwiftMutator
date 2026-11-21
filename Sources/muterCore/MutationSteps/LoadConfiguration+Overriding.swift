extension LoadConfiguration {
    /// `configuration`, as the file gives it, or as it is worked out, unless an `exclude` entry is empty, which stops
    /// the run. YAML reads an unquoted `- !/Stubs/` as a tag on an empty value. `--exclude`'s entries aren't checked.
    static func refusingAnEmptyExclude(_ configuration: MuterConfiguration) throws -> MuterConfiguration {
        if configuration.excludeFileList.contains(where: \.isEmpty) {
            throw MuterError.configurationParsingError(
                reason: "An `exclude` entry is empty. One that starts with ! must be quoted, as - \"!/Stubs/\"."
            )
        }
        return configuration
    }

    /// `configuration` with the flags of `options` in, each in place of its key, `--exclude`'s and `--exclude-calls`'
    /// entries added to theirs, and `gates`, the keys' with the gate flags in (`MuterConfiguration.overriding(...)`).
    static func overridden(
        _ configuration: MuterConfiguration,
        by options: Run.Options,
        gates: RunGates
    ) -> MuterConfiguration {
        configuration.overriding(
            workers: options.workers,
            timeout: options.timeout,
            buildTimeout: options.buildTimeout,
            failUnder: options.failUnder,
            gates: gates,
            propertyTests: options.propertyTests,
            reports: options.reports,
            exclude: options.exclude,
            keys: options.keyFlags
        )
    }
}
