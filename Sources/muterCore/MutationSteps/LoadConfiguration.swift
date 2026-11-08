import Foundation

struct LoadConfiguration: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.process)
    private var process: ProcessFactory

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        let configurationPath = configurationPath(state.runOptions)
        do {
            let hasJSON = hasJsonInProjectAtPath(configurationPath)
            let hasYAML = hasYamlInProjectAtPath(configurationPath)
            // A YAML file wins over a legacy file beside it, which migrating would overwrite. A `.yml` that
            // `--configuration` names is the one file it means, there or not.
            let namesItsFile = state.runOptions.configurationURL?.path.pathContainsConfigExtension == true
            let isLegacy = hasJSON && !hasYAML && !namesItsFile

            guard hasYAML || isLegacy,
                  let configurationData = loadConfigurationDataAtPath(
                      configurationPath,
                      legacy: isLegacy
                  )
            else {
                throw MuterError.configurationParsingError(
                    reason: "Could not find \(MuterConfiguration.fileName) at path \(configurationPath)"
                )
            }

            let configuration = try MuterConfiguration(from: configurationData)

            if isLegacy {
                try migrateToYAMLAtPath(configurationPath, configuration)
            }

            // YAML reads an unquoted `- !/Stubs/` as a tag on an empty value.
            if configuration.excludeFileList.contains(where: \.isEmpty) {
                throw MuterError.configurationParsingError(
                    reason: "An `exclude` entry is empty. One that starts with ! must be quoted, as - \"!/Stubs/\"."
                )
            }

            guard isConfigurationValid(configuration) else {
                throw MuterError.configurationParsingError(
                    reason: "Please provide a valid `-destination` argument for your project"
                )
            }

            let resolved = try await withResolvedExecutable(configuration)
                .overriding(
                    workers: state.runOptions.workers,
                    timeout: state.runOptions.timeout,
                    buildTimeout: state.runOptions.buildTimeout,
                    failUnder: state.runOptions.failUnder,
                    propertyTests: state.runOptions.propertyTests,
                    exclude: state.runOptions.exclude
                )
            // As `--build-timeout` is, which takes its place: 0 would stop every build at once, and a limit past a day
            // is a mistake.
            if let buildTimeout = resolved.buildTimeout,
               !(buildTimeout > 0 && buildTimeout <= TestingArguments.longestTimeout) {
                throw MuterError.configurationParsingError(
                    reason: "buildTimeout must be a number of seconds above 0, and at most a day (86400), "
                        + "not \(String(format: "%g", buildTimeout))."
                )
            }
            if let reason = resolved.propertyRerunsUnsupportedReason {
                throw MuterError.configurationParsingError(reason: reason)
            }
            // Now, not when the report is made: a typo shouldn't wait for the end of a long run.
            _ = try TriageFile.load(
                at: TriageFile.path(in: fileManager.currentDirectoryPath),
                using: fileManager
            )
            let operators = try state.runOptions.chosenOperators(given: resolved)
            return [
                .projectDirectoryUrlDiscovered(URL(fileURLWithPath: fileManager.currentDirectoryPath)),
                .configurationParsed(resolved),
            ] + (operators.map { [.operatorsChosen($0)] } ?? [])
        } catch let error as MuterError {
            throw error
        } catch {
            throw MuterError.configurationParsingError(reason: "\(error)")
        }
    }

    /// Turns a bare command name in `executable` into the absolute path it resolves to on `PATH`.
    ///
    /// A name with no path separator — `swift`, `xcodebuild` — only means anything to a shell, which
    /// searches `PATH` for it. Muter spawns the test command with `Process`, and `Process.executableURL`
    /// resolves a name that isn't an absolute path against the *current working directory*. Later steps
    /// run from the mutated copy of the project, where no such file exists, so the test process fails to
    /// spawn before it can emit a single line. Resolving here — while the working directory is still the
    /// project root — gives every later step an executable it can actually launch.
    private func withResolvedExecutable(
        _ configuration: MuterConfiguration
    ) async throws -> MuterConfiguration {
        let executable = configuration.testCommandExecutable
        guard !executable.contains("/") else {
            return configuration
        }

        // Reported verbatim rather than as a `configurationParsingError`: the file parsed fine, so framing
        // this as a parsing or FileManager problem would send the user looking in the wrong place.
        guard let resolved = await process().which(executable) else {
            throw MuterError.literal(
                reason: """
                SwiftMutator could not find "\(executable)" on your PATH.

                The "executable" option in \(MuterConfiguration.fileNameWithExtension) must name a command \
                that exists on your PATH, or be an absolute path such as "/usr/bin/\(executable)".
                """
            )
        }

        return configuration.withExecutable(resolved)
    }

    private func configurationPath(_ options: Run.Options) -> String {
        Self.configurationPath(options, in: fileManager.currentDirectoryPath)
    }

    /// The configuration file a run with `options` loads: `--configuration`'s, if it names a `.yml` file, or else
    /// `muter.conf.yml` in the folder it names, or in `currentDirectoryPath` without one.
    static func configurationPath(_ options: Run.Options, in currentDirectoryPath: String) -> String {
        let path = options.configurationURL?.path ?? currentDirectoryPath
        if path.pathContainsConfigExtension {
            return path
        }

        return "\(path)/\(MuterConfiguration.fileNameWithExtension)"
    }

    private func hasJsonInProjectAtPath(_ path: String) -> Bool {
        fileManager.fileExists(atPath: "\(path.pathWithoutFileName)/\(MuterConfiguration.legacyFileNameWithExtension)")
    }

    private func hasYamlInProjectAtPath(_ path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    private func isConfigurationValid(_ configuration: MuterConfiguration) -> Bool {
        guard configuration.testCommandExecutable.contains("xcodebuild") else {
            return true
        }

        return configuration.testCommandArguments.contains("-destination")
    }

    private func loadConfigurationDataAtPath(
        _ path: String,
        legacy: Bool
    ) -> Data? {
        fileManager.contents(
            atPath: legacy
                ? "\(path.pathWithoutFileName)/\(MuterConfiguration.legacyFileNameWithExtension)"
                : path
        )
    }

    /// Writes `configuration` as YAML beside the legacy file, then removes that file. If the write fails, the legacy
    /// file stays, so the settings aren't lost and the next run tries again.
    private func migrateToYAMLAtPath(
        _ path: String,
        _ configuration: MuterConfiguration
    ) throws {
        let wrote = fileManager.createFile(
            atPath: "\(path.pathWithoutFileName)/\(MuterConfiguration.fileNameWithExtension)",
            contents: try configuration.asData,
            attributes: nil
        )
        guard wrote else { return }

        try fileManager
            .removeItem(atPath: "\(path.pathWithoutFileName)/\(MuterConfiguration.legacyFileNameWithExtension)")
    }

    private func legacyPath(_ path: String) -> String {
        path
    }
}

private extension String {
    var pathContainsConfigExtension: Bool {
        hasSuffix(MuterConfiguration.extension)
    }

    var pathWithoutFileName: String {
        pathContainsConfigExtension ? NSString(string: self).deletingLastPathComponent : self
    }
}
