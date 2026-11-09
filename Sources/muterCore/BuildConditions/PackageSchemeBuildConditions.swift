import Foundation

/// What an xcodebuild test command of a Swift package's scheme compiles with. `-showBuildSettings` reports no settings
/// for one, so they come from the manifest, as for `swift test` (`SwiftPackageBuildConditions`), with the platform and
/// SDK of the `-destination` and the conditions Xcode sets besides: `Xcode`, and `SWIFT_` ones, which are undecided.
/// Built with Xcode 27.2, a package's targets get `-D` flags for the manifest's `.define`s that apply to the
/// destination's platform and the configuration, `DEBUG` in a debug build, `SWIFT_PACKAGE` and `Xcode`.
///
/// It goes by the manifest only where nothing else can set what the build compiles with: the command opens the package
/// itself, with no project or workspace beside it, sets no build setting, and names no `.xcconfig`, and no scheme of
/// the package's own may build another configuration than `-configuration`'s.
enum PackageSchemeBuildConditions {
    static func conditions(
        inProjectAt root: FilePath,
        testedBy configuration: MuterConfiguration,
        process: ProcessFactory,
        fileManager: FileSystemManager,
        environment: [String: String]
    ) async -> Result<ProjectBuildConditions, BuildConditionsUnavailable> {
        let arguments = configuration.testCommandArguments
        guard opensThePackage(at: root, with: arguments, fileManager: fileManager) else {
            return .failure(BuildConditionsUnavailable(reason: "xcodebuild reported no build settings"))
        }
        let reasonItCantTell = whyTheManifestCantTell(arguments, environment: environment)
            ?? (buildConfiguration(in: arguments, root: root, fileManager: fileManager) == nil
                ? "a scheme of the package's own may build another configuration; give it with `-configuration`"
                : nil)
        if let reasonItCantTell {
            return .failure(BuildConditionsUnavailable(
                reason: "xcodebuild reported no build settings for the package's scheme, and \(reasonItCantTell)"
            ))
        }
        guard let swift = await swiftOfXcode(process: process) else {
            return .failure(BuildConditionsUnavailable(
                reason: "xcodebuild reported no build settings for the package's scheme, and `xcrun --find swift` "
                    + "found no `swift` to read its manifest with"
            ))
        }

        let buildConfiguration = buildConfiguration(in: arguments, root: root, fileManager: fileManager) ?? "debug"
        let platform = await platform(ofDestinationIn: arguments, process: process, fileManager: fileManager)
        return await SwiftPackageBuildConditions.conditions(
            inProjectAt: root,
            testedBy: MuterConfiguration(executable: swift, arguments: ["test", "-c", buildConfiguration]),
            process: process,
            fileManager: fileManager,
            environment: environment,
            xcodeScheme: .init(platform: platform, picksAnotherCompiler: arguments.contains("-toolchain"))
        )
    }

    /// Whether xcodebuild, run in `root` with `arguments`, opens the package there: it opens a project or workspace
    /// there before a package, and the one `-project` or `-workspace` names.
    private static func opensThePackage(
        at root: FilePath,
        with arguments: [String],
        fileManager: FileSystemManager
    ) -> Bool {
        guard !arguments.contains("-project"), !arguments.contains("-workspace") else { return false }
        let entries = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
        return entries.contains("Package.swift")
            && !entries.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    /// Why the manifest can't say what the build compiles with, or nil if it can: the command sets build settings,
    /// such as `OTHER_SWIFT_FLAGS=-DFOO`, or `-xcconfig` or `XCODE_XCCONFIG_FILE` names a file of them.
    private static func whyTheManifestCantTell(_ arguments: [String], environment: [String: String]) -> String? {
        let setsBuildSettings = XcodebuildArguments(arguments).arguments.contains {
            $0.kind == .other && $0.name.contains("=")
        }
        if setsBuildSettings {
            return "the command sets build settings, which SwiftMutator doesn't follow for one"
        }
        if arguments.contains("-xcconfig") || environment["XCODE_XCCONFIG_FILE"] != nil {
            return "an `.xcconfig` may set build settings, which SwiftMutator doesn't follow for one"
        }
        return nil
    }

    /// `-configuration`'s value as SwiftPM writes it, `debug` or `release`, or `debug`, a package scheme's default.
    /// Nil for any other, or when no `-configuration` is given and a scheme of the package's own, in
    /// `.swiftpm/xcode`, may give its test action another.
    static func buildConfiguration(in arguments: [String], root: FilePath, fileManager: FileSystemManager) -> String? {
        if let index = arguments.lastIndex(of: "-configuration"), index + 1 < arguments.count {
            return ["Debug": "debug", "Release": "release"][arguments[index + 1]]
        }
        let schemes = fileManager.subpaths(atPath: root + "/.swiftpm/xcode") ?? []
        return schemes.contains { $0.hasSuffix(".xcscheme") } ? nil : "debug"
    }

    /// The `swift` of the Xcode, and the toolchain, that xcodebuild builds with, as `xcrun` finds it.
    private static func swiftOfXcode(process: ProcessFactory) async -> String? {
        guard let found = await process().runCommand(url: "/usr/bin/xcrun", arguments: ["--find", "swift"]),
              found.succeeded
        else {
            return nil
        }
        let path = found.output.trimmed
        return path.isEmpty ? nil : path
    }

    /// A destination's platform, as `os(…)`, `targetEnvironment(…)` and the SDK name it, for each `platform=` value.
    private static let platforms: [String: (system: String, environment: String?, sdk: String)] = [
        "macOS": ("macOS", nil, "macosx"),
        "iOS": ("iOS", nil, "iphoneos"),
        "iOS Simulator": ("iOS", "simulator", "iphonesimulator"),
        "tvOS": ("tvOS", nil, "appletvos"),
        "tvOS Simulator": ("tvOS", "simulator", "appletvsimulator"),
        "watchOS": ("watchOS", nil, "watchos"),
        "watchOS Simulator": ("watchOS", "simulator", "watchsimulator"),
        "visionOS": ("visionOS", nil, "xros"),
        "visionOS Simulator": ("visionOS", "simulator", "xrsimulator"),
    ]

    /// The platform of the command's one `-destination`, with the modules of its SDK; nil if it gives none, several,
    /// or one SwiftMutator can't read, as one by `id=` alone, or a Mac Catalyst or "Designed for iPad" variant.
    private static func platform(
        ofDestinationIn arguments: [String],
        process: ProcessFactory,
        fileManager: FileSystemManager
    ) async -> BuildConditions.Platform? {
        guard let destination = destination(in: arguments) else { return nil }
        let sdk = await process().runCommand(
            url: "/usr/bin/xcrun",
            arguments: ["--sdk", destination.sdk, "--show-sdk-path"]
        )
        let sdkPath = sdk.flatMap { $0.succeeded ? $0.output.trimmed : nil }
        return BuildConditions.Platform(
            system: destination.system,
            environment: destination.environment,
            architectures: destination.architectures,
            modules: sdkPath.flatMap { BuildConditions.SDKModules(sdk: $0, fileManager: fileManager) }
        )
    }

    /// What the command's one `-destination` says of the platform. Its architectures only if it names one with
    /// `arch=`: which ones the build compiles for otherwise goes by settings xcodebuild doesn't report here.
    static func destination(
        in arguments: [String]
    ) -> (system: String, environment: String?, sdk: String, architectures: Set<String>?)? {
        let values = arguments.indices.dropLast().filter { arguments[$0] == "-destination" }.map { arguments[$0 + 1] }
        guard values.count == 1 else { return nil }
        var fields: [String: String] = [:]
        for field in values[0].split(separator: ",") {
            let parts = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return nil }
            fields[parts[0]] = parts[1]
        }
        guard fields["variant"] == nil,
              let name = fields["platform"] ?? fields["generic/platform"],
              let platform = platforms[name]
        else {
            return nil
        }
        return (platform.system, platform.environment, platform.sdk, fields["arch"].map { [$0] })
    }
}
