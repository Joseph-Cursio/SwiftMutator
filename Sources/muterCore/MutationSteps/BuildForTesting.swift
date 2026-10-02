import Foundation

struct BuildForTesting: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.notificationCenter)
    private var notificationCenter: NotificationCenter
    @Dependency(\.process)
    private var process: ProcessFactory
    
    private let testContentsFolder = "TestContents"
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
            let buildDirectory = try buildDirectory(state.muterConfiguration)
            try runBuildForTestingCommand(state.muterConfiguration)
            let tempDebugURL = createTestContetsUrl(state.mutatedProjectDirectoryURL)
            try copyBuildArtifactsAtPath(buildDirectory, to: tempDebugURL.path)

            let xcTestRun = try parseXCTestRunAt(tempDebugURL)

            return [.projectXCTestRun(xcTestRun)]
        } catch {
            throw MuterError.literal(reason: "\(error)")
        }
    }

    private func buildDirectory(_ configuration: MuterConfiguration) throws -> String {
        configuration.derivedDataPath
    }

    private func runBuildForTestingCommand(
        _ configuration: MuterConfiguration
    ) throws {
        let buildProcess = process()
        guard let output: String = buildProcess.runProcess(
            url: configuration.testCommandExecutable,
            arguments: configuration.buildForTestingArguments
        ).flatMap(\.nilIfEmpty)
        else {
            throw MuterError.literal(reason: "Could not run test with -build-for-testing argument")
        }

        // Checked only after the output guard: a process that never launched has no exit status, and
        // reading it raises. Without this check a failed build surfaced later as a missing xctestrun.
        guard buildProcess.terminationStatus == 0 else {
            throw MuterError.literal(
                reason: buildFailureReason(output, status: buildProcess.terminationStatus)
            )
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

        guard let replaced = stringContents.replacingOccurrences(
            of: "__TESTROOT__/",
            with: "__TESTROOT__/\(testContentsFolder)/\(buildDirectory)"
        ).data(using: .utf8)
        else {
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
        guard let xctestrun = try fileManager.contents(
            atPath: url.path,
            sortedByDate: .orderedDescending
        ).first(where: { $0.hasSuffix(".xctestrun") })
        else {
            throw MuterError.literal(reason: "Could not find xctestrun file at path: \(url.path)")
        }

        return xctestrun
    }

    private func createTestContetsUrl(_ tempURL: URL) -> URL {
        tempURL.appendingPathComponent(testContentsFolder)
    }
}

private struct XCTestBuildRequest: Codable {
    var buildProductsPath: String {
        parameters.arenaInfo.buildProductsPath
    }

    private let parameters: Parameters
}

extension XCTestBuildRequest {
    struct Parameters: Codable {
        let arenaInfo: ArenaInfo
    }
}

extension XCTestBuildRequest.Parameters {
    struct ArenaInfo: Codable {
        let buildProductsPath: String
    }
}
