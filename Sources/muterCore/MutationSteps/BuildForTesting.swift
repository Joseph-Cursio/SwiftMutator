import Foundation

private struct XCTestArenaInfo: Codable {
    let buildProductsPath: String
}

private struct XCTestBuildParameters: Codable {
    let arenaInfo: XCTestArenaInfo
}

private struct XCTestBuildRequest: Codable {
    var buildProductsPath: String {
        parameters.arenaInfo.buildProductsPath
    }

    private let parameters: XCTestBuildParameters
}

struct BuildForTesting: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.process)
    private var process: ProcessFactory
    @Dependency(\.events)
    private var events: RunEvents

    /// The folder in the project's copy that the build is copied to, which the tests run from.
    static let testContentsFolder = "TestContents"
    private let buildDirectory = "Build/Products/"

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        guard state.muterConfiguration.buildSystem == .xcodebuild else {
            return []
        }

        let currentDirectoryPath = fileManager.currentDirectoryPath

        defer {
            fileManager.changeCurrentDirectoryPath(currentDirectoryPath)
        }

        fileManager.changeCurrentDirectoryPath(state.mutatedProjectDirectoryURL.path)

        do {
            let directory = try buildDirectory(state.muterConfiguration)
            let leftOut = try await buildLeavingOutMutants(state: state)
            let tempDebugURL = createTestContetsUrl(state.mutatedProjectDirectoryURL)
            try copyBuildArtifactsAtPath(directory, to: tempDebugURL.path)

            let xcTestRun = try parseXCTestRunAt(tempDebugURL)
            let canTurnOffTestDiagnostics = await takesNoTestDiagnostics(state.muterConfiguration)

            return [
                .projectXCTestRun(xcTestRun),
                .testDiagnosticsOptionChecked(canBeTurnedOff: canTurnOffTestDiagnostics),
            ] + (leftOut.isEmpty ? [] : [.mutantsLeftOutOfTheBuild(leftOut)])
        } catch let error as MuterError {
            // A failed or stopped build's abort, which exits as a failed baseline does.
            throw error
        } catch {
            throw MuterError.literal(reason: "\(error)")
        }
    }

    private func buildDirectory(_ configuration: MuterConfiguration) throws -> String {
        configuration.derivedDataPath
    }

    /// Builds for testing, with any mutant that fails the build taken out of the code, until it no longer fails on
    /// one (`CompileRecovery`), and gives those mutants. Each failed build's log is kept, the one that stops the run
    /// too, as only the build's output has it. Later builds aren't clean ones: only what changed needs building again.
    /// A build a stop killed is never read. Each build may run for `buildTimeout`: one stopped there stops the run,
    /// as a failed build with no mutant to blame does, and its compile errors, cut short, blame none.
    private func buildLeavingOutMutants(state: AnyMutationTestState) async throws -> [String: LeftOutMutant] {
        var recovery = CompileRecovery(of: state)
        var arguments = state.muterConfiguration.buildForTestingArguments
        while true {
            guard let failure = try await runBuildForTestingCommand(state.muterConfiguration, arguments) else {
                return recovery?.leftOut ?? [:]
            }
            let buildLog = MutationTestLog.failedBuildFileName((recovery?.failedBuilds ?? 0) + 1)
            guard !Task.isCancelled else { throw failure }
            let logPath = fileManager.keepLog(failure.output, named: buildLog, state: state)
            if let seconds = failure.timedOutAfter {
                throw MuterError.mutationTestingAborted(reason: .buildTimeoutReached(
                    step: .buildForTesting, seconds: seconds, output: failure.output, log: logPath
                ))
            }
            guard var trying = recovery,
                  let count = try await trying.takeOutMutants(failing: failure.output, keptAs: buildLog)
            else {
                if recovery?.stopsAtTheMostBuilds == true {
                    events.send(.stoppedTakingOutMutants(afterBuilds: CompileRecovery.maximumBuilds))
                }
                throw MuterError.mutationTestingAborted(
                    reason: .buildForTestingFailed(description: failure.description, log: logPath)
                )
            }
            recovery = trying
            if count > 0 { events.send(.buildingAgainWithoutMutants(count: count)) }
            if trying.switchedInAClosure > 0 {
                events.send(.buildingAgainWithSwitchesInAClosure(count: trying.switchedInAClosure))
            }
            arguments = state.muterConfiguration.rebuildForTestingArguments
        }
    }

    /// A build that failed: what it wrote, standard output then standard error, why it stops the run, and the
    /// seconds it ran for if `buildTimeout` stopped it.
    private struct FailedBuild: Error, CustomStringConvertible {
        let output: String
        let description: String
        var timedOutAfter: TimeInterval?
    }

    /// Runs the build, for at most `buildTimeout` seconds, and says how it failed, if it did.
    private func runBuildForTestingCommand(
        _ configuration: MuterConfiguration,
        _ arguments: [String]
    ) async throws -> FailedBuild? {
        let build = await process().runCommand(
            url: configuration.testCommandExecutable,
            arguments: arguments,
            timeLimit: configuration.buildTimeout
        )
        guard let build else {
            throw MuterError.literal(reason: "Could not run test with -build-for-testing argument")
        }
        let output = build.printed
        // Before anything else: killed at its limit, it would read as ended by a signal, and may have printed nothing.
        if build.timedOut, let seconds = configuration.buildTimeout {
            let limit = String(format: "%g", seconds)
            return FailedBuild(
                output: output,
                description: "xcodebuild build-for-testing didn't end within \(limit) s (buildTimeout)",
                timedOutAfter: seconds
            )
        }
        guard !output.isEmpty else {
            throw MuterError.literal(reason: "Could not run test with -build-for-testing argument")
        }
        guard build.succeeded else {
            return FailedBuild(output: output, description: buildFailureReason(output, status: build.status))
        }
        return nil
    }

    /// How long `takesNoTestDiagnostics` waits for the test command's `-help`, in seconds. xcodebuild's takes
    /// about 0.3 s.
    static let helpTimeLimit: TimeInterval = 30

    /// Whether the test command takes `-collect-test-diagnostics never`, as its `-help` says. Asked once per run, here,
    /// where xcodebuild has just run. xcodebuild refuses an option it doesn't know, so an Xcode without this one, or a
    /// wrapper `executable` that doesn't pass it on, would fail every mutant's run, and kill every mutant. False
    /// whenever the answer isn't clear: the option only saves time.
    private func takesNoTestDiagnostics(_ configuration: MuterConfiguration) async -> Bool {
        guard let help = await process().runCommand(
            url: configuration.testCommandExecutable,
            arguments: ["-help"],
            timeLimit: Self.helpTimeLimit
        ), !help.timedOut
        else {
            return false
        }
        // xcodebuild writes its help to standard error.
        return Self.listsNoTestDiagnostics(help.output + "\n" + help.errors)
    }

    /// Whether `help`, a test command's `-help`, has xcodebuild's line for `-collect-test-diagnostics` with `never`
    /// among its values: `-collect-test-diagnostics on-failure|never`.
    static func listsNoTestDiagnostics(_ help: String) -> Bool {
        help.split(whereSeparator: \.isNewline).contains { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count > 1, words[0] == "-collect-test-diagnostics" else { return false }
            return words[1].split(separator: "|").contains("never")
        }
    }

    private func buildFailureReason(_ output: String, status: Int32) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        let errorLines = lines.filter { $0.contains("error:") }
        let details = errorLines.isEmpty ? lines.suffix(10) : errorLines[...]

        return """
        xcodebuild build-for-testing failed with exit code \(status):
        \(details.joined(separator: "\n"))
        """
    }

    private func parseBuildRequest(_ path: String) throws -> XCTestBuildRequest {
        guard let jsonContent = fileManager.contents(atPath: path) else {
            throw MuterError.literal(reason: "Could not parse build request json at path: \(path)")
        }

        return try JSONDecoder().decode(XCTestBuildRequest.self, from: jsonContent)
    }

    private func copyBuildArtifactsAtPath(_ buildPath: String, to destination: String) throws {
        try? fileManager.removeItem(
            atPath: destination
        )

        try fileManager.copyItem(
            atPath: buildPath,
            toPath: destination
        )
    }

    private func parseXCTestRunAt(_ url: URL) throws -> XCTestRun {
        let xcTestRunPath = try findMostRecentXCTestRunAtURL(url)
        guard let contents = fileManager.contents(atPath: xcTestRunPath),
              let stringContents = String(data: contents, encoding: .utf8)
        else {
            throw MuterError.literal(reason: "Could not parse xctestrun at path: \(xcTestRunPath)")
        }

        let rooted = stringContents.replacingOccurrences(
            of: "__TESTROOT__/",
            with: "__TESTROOT__/\(Self.testContentsFolder)/\(buildDirectory)"
        )
        guard let replaced = rooted.data(using: .utf8) else {
            throw MuterError.literal(reason: "Error error")
        }

        guard let plist = try PropertyListSerialization.propertyList(
            from: replaced,
            format: nil
        ) as? [String: AnyHashable]
        else {
            throw MuterError.literal(reason: "Could not parse xctestrun as plist at path: \(xcTestRunPath)")
        }

        return XCTestRun(plist)
    }

    private func findMostRecentXCTestRunAtURL(_ url: URL) throws -> String {
        let contents = try fileManager.contents(
            atPath: url.path,
            sortedByDate: .orderedDescending
        )
        guard let xctestrun = contents.first(where: { $0.hasSuffix(".xctestrun") }) else {
            throw MuterError.literal(reason: "Could not find xctestrun file at path: \(url.path)")
        }

        return xctestrun
    }

    private func createTestContetsUrl(_ tempURL: URL) -> URL {
        tempURL.appendingPathComponent(Self.testContentsFolder)
    }
}
