import Foundation

/// What `xcodebuild -list -json` prints: a workspace's or a project's schemes.
private struct XcodebuildListing: Decodable {
    struct Container: Decodable {
        let schemes: [String]?
    }

    let workspace: Container?
    let project: Container?
}

extension MuterConfiguration {
    /// The configuration for the project whose folder `directory` holds `directoryContents`, paths relative to it.
    /// Each path keeps its relative form, so that what `XcodebuildTrustCheck` looks for in it is looked for only below
    /// the project's folder. An Xcode workspace or project at the top of the folder wins, then a `Package.swift`;
    /// otherwise it is empty, to fill in. It throws when there are several workspaces, or no workspace and several
    /// projects.
    static func generated(from directoryContents: [FilePath], in directory: FilePath) async throws
        -> GeneratedConfiguration {
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        let contentURLs = directoryContents.map { URL(fileURLWithPath: $0, relativeTo: base) }
        let topLevel = contentURLs.filter { !$0.relativePath.trimmingCharacters(in: ["/"]).contains("/") }

        if let container = try XcodeContainer.find(among: topLevel),
           let generated = await xcodeConfiguration(for: container, besides: topLevel, in: contentURLs) {
            return generated
        }
        if let configuration = await packageConfiguration(from: topLevel) {
            return GeneratedConfiguration(configuration: configuration, scheme: nil)
        }
        return GeneratedConfiguration(configuration: MuterConfiguration(), scheme: nil)
    }

    /// `xcodebuild` with the container, the scheme `xcodebuild -list` names for it, the trust checks the project in
    /// `directoryContents` needs skipped, so that a run with no one at the Mac to trust its plugins and macros, as on
    /// CI, still builds, and a destination. nil for a project whose `project.pbxproj` can't be read.
    private static func xcodeConfiguration(
        for container: XcodeContainer,
        besides topLevel: [URL],
        in directoryContents: [URL]
    ) async -> GeneratedConfiguration? {
        let projectFiles = container.projectFiles(besides: topLevel).compactMap { project in
            try? String(contentsOf: project.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        }
        if case .project = container, projectFiles.isEmpty {
            return nil
        }

        let scheme = SchemeChoice(listed: await schemes(of: container), containerName: container.name)
        let containerArguments = [container.argument, container.url.lastPathComponent, "-scheme", scheme.chosen]
        let probeArguments = [container.argument, container.url.path, "-scheme", scheme.chosen]
        let destination = projectFiles.contains { $0.contains("SDKROOT = iphoneos") }
            ? "platform=iOS Simulator,name=\(await iosDestination())"
            : await macOSDestination(probeArguments)
        let skippedTrustChecks = XcodebuildTrustCheck.needed(by: directoryContents).map(\.skippingArgument)

        let configuration = await MuterConfiguration(
            executable: executablePath("xcodebuild"),
            arguments: containerArguments + skippedTrustChecks + ["-destination", destination, "test"]
        )
        return GeneratedConfiguration(configuration: configuration, scheme: scheme)
    }

    /// `swift test`. The manifests need no `exclude`: `SourceFileExcludes` always leaves them out.
    private static func packageConfiguration(from topLevel: [URL]) async -> MuterConfiguration? {
        guard topLevel.contains(where: { $0.lastPathComponent == "Package.swift" }) else {
            return nil
        }
        return await MuterConfiguration(executable: executablePath("swift"), arguments: ["test"])
    }

    private static func executablePath(_ exec: String) async -> String {
        await current.process().which(exec) ?? ""
    }
}

extension MuterConfiguration {
    /// The schemes `xcodebuild -list -json` names for the workspace or project, in its order; none when it can't be
    /// run, or prints something else.
    static func schemes(of container: XcodeContainer) async -> [String] {
        guard let output: String = await current.process().runProcess(
            url: "/usr/bin/xcodebuild",
            arguments: [container.argument, container.url.path, "-list", "-json"]
        ) else {
            return []
        }
        return schemes(inListing: output)
    }

    /// The schemes in `xcodebuild -list -json`'s output, which may start with lines that aren't JSON.
    static func schemes(inListing output: String) -> [String] {
        guard let start = output.firstIndex(of: "{"),
              let listing = try? JSONDecoder().decode(XcodebuildListing.self, from: Data(output[start...].utf8))
        else {
            return []
        }
        return listing.workspace?.schemes ?? listing.project?.schemes ?? []
    }

    /// Of `simctl list --json`'s runtimes, the newest iOS one, by version, so iOS 18.2 is newer than iOS 9.3, which a
    /// comparison of the names would put last.
    static func newestIOSRuntime(among runtimes: some Sequence<String>) -> String? {
        runtimes
            .compactMap { runtime -> (runtime: String, version: [Int])? in
                guard let marker = runtime.range(of: "iOS-") else {
                    return nil
                }
                let version = runtime[marker.upperBound...].split(separator: "-").compactMap { Int($0) }
                return (runtime, version)
            }
            .max { $0.version.lexicographicallyPrecedes($1.version) }?
            .runtime
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
            let newestRuntime = newestIOSRuntime(among: devices.keys) ?? ""
            let devicesForRunTime = (devices[newestRuntime] as? [AnyHashable]) ?? []
            let device: Simulator? = try devicesForRunTime
                .compactMap { try JSONSerialization.data(withJSONObject: $0) }
                .compactMap { try JSONDecoder().decode(Simulator.self, from: $0) }
                .filter(\.isAvailable)
                .sorted { $0.deviceTypeIdentifier > $1.deviceTypeIdentifier }
                .first { $0.name.contains("iPhone") }

            return device?.name ?? Simulator.fallback.name
        } catch {
            return Simulator.fallback.name
        }
    }

    private static func macOSDestination(_ projectArguments: [String]) async -> String {
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
