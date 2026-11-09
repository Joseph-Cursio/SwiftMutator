import Foundation

/// What an xcodebuild test command of a Swift package's scheme compiles with. `-showBuildSettings` reports no settings
/// for one, so they come from the manifest, as for `swift test` (`SwiftPackageBuildConditions`), with the platform and
/// SDK of the `-destination` and the conditions Xcode sets besides: `Xcode`, and `SWIFT_` ones, which are undecided.
/// Built with Xcode 27.2, a package's targets get `-D` flags for the manifest's `.define`s that apply to the
/// destination's platform and the configuration, `DEBUG` in a debug build, `SWIFT_PACKAGE` and `Xcode`.
///
/// It goes by the manifest only where nothing else can set what the build compiles with: the command runs xcodebuild
/// itself, not a script that runs it, opens the package, with no project or workspace beside it, sets no build setting,
/// names no `.xcconfig`, and gives the configuration, which a scheme's test action, of the package's own or of a local
/// package it depends on, can set otherwise; and the environment sets none of the build settings that change what Swift
/// compiles with.
enum PackageSchemeBuildConditions {
    static func conditions(
        inProjectAt root: FilePath,
        testedBy configuration: MuterConfiguration,
        process: ProcessFactory,
        fileManager: FileSystemManager,
        environment: [String: String]
    ) async -> Result<ProjectBuildConditions, BuildConditionsUnavailable> {
        let arguments = configuration.testCommandArguments
        guard (configuration.testCommandExecutable as NSString).lastPathComponent == "xcodebuild",
              opensThePackage(at: root, with: arguments, fileManager: fileManager)
        else {
            return .failure(BuildConditionsUnavailable(reason: "xcodebuild reported no build settings"))
        }
        let xcode = xcode(of: configuration.testCommandExecutable)
        let reasonItCantTell = whyTheManifestCantTell(arguments, environment: environment)
            ?? (buildConfiguration(in: arguments) == nil
                ? "a scheme may build another configuration than Debug; give it with `-configuration`"
                : nil)
            ?? (xcode == nil
                ? "SwiftMutator can't tell which Xcode \(configuration.testCommandExecutable) is, to read the "
                    + "manifest with its `swift`"
                : nil)
        if let reasonItCantTell {
            return .failure(BuildConditionsUnavailable(
                reason: "xcodebuild reported no build settings for the package's scheme, and \(reasonItCantTell)"
            ))
        }
        guard let xcode, let buildConfiguration = buildConfiguration(in: arguments),
              let swift = await xcrun(["--find", "swift"], in: xcode, process: process)
        else {
            return .failure(BuildConditionsUnavailable(
                reason: "xcodebuild reported no build settings for the package's scheme, and `xcrun --find swift` "
                    + "found no `swift` to read its manifest with"
            ))
        }

        let platform = await platform(
            ofDestinationIn: arguments,
            xcode: xcode,
            process: process,
            fileManager: fileManager
        )
        let picksAnotherCompiler = arguments.contains("-toolchain")
            || environment["SWIFT_EXEC"] != nil
            || environment["TOOLCHAINS"].map { $0 != "com.apple.dt.toolchain.XcodeDefault" } == true
        return await SwiftPackageBuildConditions.conditions(
            inProjectAt: root,
            testedBy: MuterConfiguration(executable: swift, arguments: ["test", "-c", buildConfiguration]),
            process: process,
            fileManager: fileManager,
            environment: environment,
            xcodeScheme: .init(platform: platform, picksAnotherCompiler: picksAnotherCompiler)
        )
    }

    /// Which Xcode an xcodebuild is, for `xcrun` to find the same Xcode's tools.
    enum Xcode: Equatable {
        /// The one `DEVELOPER_DIR` or `xcode-select` picks, which `/usr/bin/xcodebuild` runs, as `xcrun` does.
        case selected
        /// The one whose Developer folder this is, which its own xcodebuild runs whatever `DEVELOPER_DIR` says.
        case developer(FilePath)
    }

    /// The Xcode `executable` is: `/usr/bin/xcodebuild`, or the xcodebuild in an Xcode's Developer folder. Nil for any
    /// other, which SwiftMutator can't tell.
    static func xcode(of executable: String) -> Xcode? {
        if executable == "/usr/bin/xcodebuild" {
            return .selected
        }
        let tool = "/usr/bin/xcodebuild"
        guard executable.hasSuffix("/Contents/Developer" + tool) else { return nil }
        return .developer(String(executable.dropLast(tool.count)))
    }

    /// What `xcrun` with `arguments` prints for `xcode`, trimmed; nil if it fails or prints nothing.
    private static func xcrun(_ arguments: [String], in xcode: Xcode, process: ProcessFactory) async -> String? {
        let result = switch xcode {
        case .selected:
            await process().runCommand(url: "/usr/bin/xcrun", arguments: arguments)
        case let .developer(folder):
            await process().runCommand(
                url: "/usr/bin/env",
                arguments: ["DEVELOPER_DIR=\(folder)", "/usr/bin/xcrun"] + arguments
            )
        }
        guard let result, result.succeeded else { return nil }
        let output = result.output.trimmed
        return output.isEmpty ? nil : output
    }

    /// Build settings xcodebuild takes from the environment, as it takes `NAME=value` arguments, that can change which
    /// conditions Swift compiles a package's targets with, its language mode, or its platform and architectures.
    /// Matched as they are and with a suffix, as `OTHER_SWIFT_FLAGS_Debug`.
    private static let settingsFromTheEnvironment = [
        "OTHER_SWIFT_FLAGS", "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "SWIFT_VERSION", "ARCHS", "SDKROOT",
    ]

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
    /// such as `OTHER_SWIFT_FLAGS=-DFOO`, or the environment does, or `-xcconfig` or `XCODE_XCCONFIG_FILE` names a file
    /// of them.
    private static func whyTheManifestCantTell(_ arguments: [String], environment: [String: String]) -> String? {
        let setsBuildSettings = XcodebuildArguments(arguments).arguments.contains {
            $0.kind == .other && $0.name.contains("=")
        }
        if setsBuildSettings {
            return "the command sets build settings, which SwiftMutator doesn't follow for one"
        }
        let fromTheEnvironment = environment.keys.sorted().first { name in
            settingsFromTheEnvironment.contains { name == $0 || name.hasPrefix($0 + "_") }
        }
        if let fromTheEnvironment {
            return "the environment sets \(fromTheEnvironment), which SwiftMutator doesn't follow for one"
        }
        if arguments.contains("-xcconfig") || environment["XCODE_XCCONFIG_FILE"] != nil {
            return "an `.xcconfig` may set build settings, which SwiftMutator doesn't follow for one"
        }
        return nil
    }

    /// `-configuration`'s value as SwiftPM writes it, `debug` or `release`; nil for any other, or none. Without one,
    /// the scheme's test action picks it, and a scheme of the package's own, or of any local package it depends on,
    /// in or out of the project, can pick Release.
    static func buildConfiguration(in arguments: [String]) -> String? {
        guard let index = arguments.lastIndex(of: "-configuration"), index + 1 < arguments.count else { return nil }
        return ["Debug": "debug", "Release": "release"][arguments[index + 1]]
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
        xcode: Xcode,
        process: ProcessFactory,
        fileManager: FileSystemManager
    ) async -> BuildConditions.Platform? {
        guard let destination = destination(in: arguments) else { return nil }
        let sdkPath = await xcrun(["--sdk", destination.sdk, "--show-sdk-path"], in: xcode, process: process)
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
