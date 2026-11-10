import Foundation

extension MuterConfiguration {
    /// Tried in order. The last makes a configuration from anything.
    private static let generators: [@Sendable ([URL]) async -> MuterConfiguration?] = [
        generateXcodeProjectConfiguration,
        generateXcodeWorkspaceConfiguration,
        generateSPMConfiguration,
        generateEmptyConfiguration,
    ]

    /// The configuration the first generator that knows the project in `directoryContents` makes. A relative path is
    /// read from `directory`, or from the current folder when there is none, and keeps its relative form, so that
    /// what `XcodebuildTrustCheck` looks for in it is looked for only below the project's folder.
    init(from directoryContents: [FilePath], in directory: FilePath? = nil) async {
        let base = directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let contentURLs = directoryContents.map { URL(fileURLWithPath: $0, relativeTo: base) }
        for generate in Self.generators {
            if let generatedConfiguration = await generate(contentURLs) {
                self = generatedConfiguration
                return
            }
        }
        self = MuterConfiguration(executable: "", arguments: [], excludeList: [])
    }
}

private extension MuterConfiguration {
    static func generateXcodeProjectConfiguration(from directoryContents: [URL]) async -> MuterConfiguration? {
        guard !directoryContainsXcodeWorkspace(directoryContents),
              let index = directoryContents.firstIndex(where: { $0.lastPathComponent.contains(".xcodeproj") }),
              let arguments = await arguments(
                  forProjectFileAt: directoryContents[index],
                  isWorkSpace: false,
                  in: directoryContents
              )
        else {
            return nil
        }

        return await MuterConfiguration(
            executable: executablePath("xcodebuild"),
            arguments: arguments
        )
    }

    static func generateXcodeWorkspaceConfiguration(from directoryContents: [URL]) async -> MuterConfiguration? {
        guard directoryContainsXcodeWorkspace(directoryContents),
              let index = directoryContents.firstIndex(where: { $0.lastPathComponent.contains(".xcodeproj") }),
              let arguments = await arguments(
                  forProjectFileAt: directoryContents[index],
                  isWorkSpace: true,
                  in: directoryContents
              )
        else {
            return nil
        }

        return await MuterConfiguration(
            executable: executablePath("xcodebuild"),
            arguments: arguments
        )
    }

    static func directoryContainsXcodeWorkspace(_ directoryContents: [URL]) -> Bool {
        let indexOfUserGeneratedWorkSpace = directoryContents
            .exclude { $0.absoluteString.contains("project.xcworkspace") }
            .firstIndex { $0.lastPathComponent.contains(".xcworkspace") }

        return indexOfUserGeneratedWorkSpace != nil
    }

    /// The arguments that test the project at `url`. They skip the trust checks the project in `directoryContents`
    /// needs, so that a run with no one at the Mac to trust its plugins and macros, as on CI, still builds.
    static func arguments(
        forProjectFileAt url: URL,
        isWorkSpace: Bool,
        in directoryContents: [URL]
    ) async -> [String]? {
        guard let projectFile = try? String(
            contentsOf: url.appendingPathComponent("project.pbxproj"),
            encoding: .utf8
        ),
            let projectName = url.lastPathComponent.split(separator: ".").first
        else {
            return nil
        }

        let defaultArguments = [
            isWorkSpace ? "-workspace" : "-project",
            isWorkSpace ? "\(projectName).xcworkspace" : "\(projectName).xcodeproj",
            "-scheme",
            "\(projectName)",
        ]

        let destination = projectFile.contains("SDKROOT = iphoneos") ?
            ["-destination", "platform=iOS Simulator,name=\(await iosDestination())"] :
            ["-destination", await macOSDestionation(defaultArguments)]

        let skippedTrustChecks = XcodebuildTrustCheck.needed(by: directoryContents).map(\.skippingArgument)

        return defaultArguments + skippedTrustChecks + destination + ["test"]
    }

    private static func executablePath(_ exec: String) async -> String {
        await current.process().which(exec) ?? ""
    }
}

private extension MuterConfiguration {
    static func generateSPMConfiguration(from directoryContents: [URL]) async -> MuterConfiguration? {
        if directoryContents.contains(where: { $0.lastPathComponent == "Package.swift" }) {
            return await MuterConfiguration(
                executable: executablePath("swift"),
                arguments: ["test"],
                excludeList: swiftPackageManifestFiles(from: directoryContents)
            )
        }

        return nil
    }

    private static func swiftPackageManifestFiles(from directoryContents: [URL]) -> [String] {
        directoryContents
            .include { $0.lastPathComponent.matches("Package@*.swift") }
            .map(\.lastPathComponent)
    }

    static func generateEmptyConfiguration(from _: [URL]) -> MuterConfiguration? {
        MuterConfiguration(executable: "", arguments: [], excludeList: [])
    }
}

private extension MuterConfiguration {
    private struct Simulator: Codable, CustomStringConvertible {
        let isAvailable: Bool
        let name: String
        let deviceTypeIdentifier: String

        var description: String { name }

        static var fallback: Self {
            Self(
                isAvailable: true,
                name: "iPhone SE (3rd generation)",
                deviceTypeIdentifier: ""
            )
        }
    }

    private static func iosDestination() async -> String {
        let process = current.process()
        guard let simulatorsListOutput: Data = await process.runProcess(
            url: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "--json"]
        )
        else {
            return Simulator.fallback.name
        }

        do {
            let simulatorsJson = try (
                JSONSerialization
                    .jsonObject(with: simulatorsListOutput) as? [String: AnyHashable]
            ) ??
                [:]
            let devices = (simulatorsJson["devices"] as? [String: AnyHashable]) ?? [:]
            let newestRuntime = devices.keys.filter { $0.contains("iOS") }.sorted().last ?? ""
            let devicesForRunTime = (devices[newestRuntime] as? [AnyHashable]) ?? []
            let device: Simulator? = try devicesForRunTime
                .compactMap { try JSONSerialization.data(withJSONObject: $0) }
                .compactMap { try JSONDecoder().decode(Simulator.self, from: $0) }
                .filter(\.isAvailable)
                .sorted(by: { $0.deviceTypeIdentifier > $1.deviceTypeIdentifier })
                .first { $0.name.contains("iPhone") }

            return device?.name ?? Simulator.fallback.name
        } catch {
            return Simulator.fallback.name
        }
    }

    private static func macOSDestionation(_ projectArguments: [String]) async -> String {
        let process = current.process()
        guard let destinationsOutput: String = await process.runProcess(
            url: "/usr/bin/xcodebuild",
            arguments: projectArguments + ["-showdestinations"]
        )
        else {
            return ""
        }

        guard let destination = destinationsOutput.firstMatchOf(#"\{\s*([^}]+)\s*\}"#) else {
            return ""
        }

        return destination
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: ", ", with: ",")
            .trimmed
            .replacingOccurrences(of: ":", with: "=")
    }
}
