import Foundation

struct LoadConfiguration: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.process)
    private var process: ProcessFactory
    @Dependency(\.events)
    private var events: RunEvents

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        let configurationPath = configurationPath(state.runOptions)
        do {
            let configuration = try checked(try await readOrWorkOutConfiguration(at: configurationPath, state: state))
            let resolved = try await withResolvedExecutable(configuration)
                .overriding(
                    workers: state.runOptions.workers,
                    timeout: state.runOptions.timeout,
                    buildTimeout: state.runOptions.buildTimeout,
                    failUnder: state.runOptions.failUnder,
                    propertyTests: state.runOptions.propertyTests,
                    reports: state.runOptions.reports,
                    exclude: state.runOptions.exclude
                )
            if let reason = Self.valueOutOfRange(in: resolved) {
                throw MuterError.configurationParsingError(reason: reason)
            }
            try checkWhatTheRunSaves(with: resolved, state: state)
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

    /// The configuration at `configurationPath`, or in the legacy file beside it, or, when there is neither and no
    /// `--configuration` names one, what `init` would write in the project's folder.
    private func readOrWorkOutConfiguration(
        at configurationPath: String,
        state: AnyMutationTestState
    ) async throws -> MuterConfiguration {
        if let configuration = try readConfiguration(at: configurationPath, state: state) {
            return configuration
        }
        guard state.runOptions.configurationURL == nil else {
            throw MuterError.configurationParsingError(
                reason: "Could not find \(MuterConfiguration.fileName) at path \(configurationPath)"
            )
        }
        return try await workedOutConfiguration(missing: configurationPath)
    }

    /// What `init` would write in the project's folder, which it says, with the scheme it guessed and the trust checks
    /// it skips. Refused, as a missing file was, when there is nothing to work a test command out from, or more than
    /// one workspace or project to choose between.
    private func workedOutConfiguration(missing configurationPath: String) async throws -> MuterConfiguration {
        let folder = fileManager.currentDirectoryPath
        let missing = "Could not find \(MuterConfiguration.fileName) at path \(configurationPath)"
        // The folder's top first, so that a run from the wrong folder, as a home folder, is refused at once, without
        // listing everything below it.
        let topLevel = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
        let hasAnXcodeContainer = topLevel.contains { $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".xcodeproj") }
        guard hasAnXcodeContainer || topLevel.contains("Package.swift") else {
            throw MuterError.configurationParsingError(
                reason: "\(missing), and the project's folder has no Package.swift, Xcode workspace or Xcode project "
                    + "at its top to work out a test command from."
            )
        }
        let generated: GeneratedConfiguration
        do {
            // Only the trust checks of an Xcode project look below the top.
            let contents = hasAnXcodeContainer ? fileManager.subpaths(atPath: folder) ?? topLevel : topLevel
            generated = try await MuterConfiguration.generated(from: contents, in: folder)
        } catch {
            throw MuterError.configurationParsingError(reason: "\(missing). \(error)")
        }
        guard !generated.configuration.testCommandExecutable.isEmpty else {
            throw MuterError.configurationParsingError(reason: Self.noTestCommand(in: generated, missing: missing))
        }
        // Without `--configuration`, the file missing is the project's own.
        events.send(.configurationWorkedOut(generated, missing: MuterConfiguration.fileNameWithExtension))
        return generated.configuration.workedOutFromTheProject()
    }

    /// The configuration at `configurationPath`, or in the legacy file beside it, which is migrated, or nil when
    /// there is neither: its unknown keys are said.
    private func readConfiguration(
        at configurationPath: String,
        state: AnyMutationTestState
    ) throws -> MuterConfiguration? {
        let hasJSON = hasJsonInProjectAtPath(configurationPath)
        let hasYAML = hasYamlInProjectAtPath(configurationPath)
        // A YAML file wins over a legacy file beside it, which migrating would overwrite. A `.yml` that
        // `--configuration` names is the one file it means, there or not.
        let namesItsFile = state.runOptions.configurationURL?.path.pathContainsConfigExtension == true
        let isLegacy = hasJSON && !hasYAML && !namesItsFile

        guard hasYAML || isLegacy else {
            return nil
        }
        guard let configurationData = loadConfigurationDataAtPath(configurationPath, legacy: isLegacy) else {
            throw MuterError.configurationParsingError(
                reason: "Could not find \(MuterConfiguration.fileName) at path \(configurationPath)"
            )
        }

        // Before decoding, so a misspelled `executable` or `arguments` that it then misses gets its key named too.
        let unknownKeys = UnknownConfigurationKey.found(in: configurationData)
        if !unknownKeys.isEmpty {
            let file = isLegacy
                ? "\(configurationPath.pathWithoutFileName)/\(MuterConfiguration.legacyFileNameWithExtension)"
                : configurationPath
            events.send(.configurationKeysUnknown(unknownKeys, file: shown(file)))
        }
        let configuration = try MuterConfiguration(from: configurationData)

        // Not while it has a key SwiftMutator doesn't know: the YAML file holds only those it does, so the key the
        // warning names would be gone, and the next run would say nothing of it.
        if isLegacy, unknownKeys.isEmpty {
            try migrateToYAMLAtPath(configurationPath, configuration)
        }
        return configuration
    }

    /// `configuration`, once checked: an empty `exclude` entry, a missing destination or a refused argument stops the
    /// run.
    private func checked(_ configuration: MuterConfiguration) throws -> MuterConfiguration {
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
        if let reason = Self.argumentRefused(in: configuration) {
            throw MuterError.configurationParsingError(reason: reason)
        }
        return configuration
    }

    /// Stops a run whose `resolved` configuration, the run's flags already in, would save two reports to one file, a
    /// report over a folder, or ask for property reruns it can't run, or whose triage file can't be read.
    private func checkWhatTheRunSaves(with resolved: MuterConfiguration, state: AnyMutationTestState) throws {
        // As `--report`'s are, which take their place: each saved report needs a file of its own.
        let outputs = Self.outputs(of: state.runOptions, resolved, in: fileManager)
        if let clash = ReportRequest.clash(among: outputs, ofARun: true) {
            throw MuterError.configurationParsingError(reason: "\(clash): give each report a path of its own.")
        }
        // Saving replaces whatever is at the path, a folder and everything in it too, as `report` refuses: now,
        // not when the run ends.
        if let folder = outputs.first(where: { fileManager.isDirectory(atPath: $0.path) }) {
            throw MuterError.configurationParsingError(
                reason: "\(folder.path) is a folder: name the file to save the report to, in \(folder.option)."
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
    }

    /// The reports a run with `options` and `configuration` saves, by how a refusal names each: `-o`'s, then those of
    /// `--report`, or else of `reports:`, resolved against the project's folder, the current one, then
    /// `--write-baseline`'s file.
    private static func outputs(
        of options: Run.Options,
        _ configuration: MuterConfiguration,
        in fileManager: FileSystemManager
    ) -> [ReportRequest.Output] {
        let option = options.reports == nil ? "reports:" : "--report"
        let folder = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        // Appended one at a time: as one sum of optional arrays of tuples, Xcode 26's compiler can give up on it.
        var outputs: [ReportRequest.Output] = []
        if let path = options.reportOptions.path {
            outputs.append(("-o \(path)", path))
        }
        outputs += configuration.reportRequests(in: folder).map { ("\(option) \($0)", $0.path) }
        if let writeBaseline = options.writeBaseline {
            outputs.append(("--write-baseline \(writeBaseline)", URL.expandingTilde(writeBaseline)))
        }
        return outputs
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

    /// `path` as a warning names it: relative to the current folder when it is in it, as `muter.conf.yml` or
    /// `ci/muter.conf.yml`, and else in full, so a file `--configuration` chose isn't taken for the project's own.
    private func shown(_ path: String) -> String {
        let folder = fileManager.currentDirectoryPath.standardizingPath + "/"
        let standardized = path.standardizingPath
        return standardized.hasPrefix(folder) ? String(standardized.dropFirst(folder.count)) : standardized
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
}

private extension String {
    var pathContainsConfigExtension: Bool {
        hasSuffix(MuterConfiguration.extension)
    }

    var pathWithoutFileName: String {
        pathContainsConfigExtension ? self.deletingLastPathComponent : self
    }
}
