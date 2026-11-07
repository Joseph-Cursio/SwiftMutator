import Foundation

/// What an xcodebuild test command compiles with, from `xcodebuild -showBuildSettings`, which follows its
/// `-destination`.
enum XcodeBuildConditions {
    /// `-showBuildSettings` reports the targets of an action: for `test`, the test bundles and not the app they test;
    /// with no action, the scheme's own. So it is asked both ways, the second for the configuration the first reports,
    /// which a scheme's test action can set apart from the project's default.
    ///
    /// It reports no target that a scheme's targets only depend on, and no local package's, so a condition no reported
    /// target sets is left undecided if a build file in the project names it. A Swift package's scheme has no settings
    /// at all, which is a failure here: its `#if`s are left to coverage.
    static func conditions(
        inProjectAt root: FilePath,
        testedBy configuration: MuterConfiguration,
        process: ProcessFactory,
        fileManager: FileSystemManager
    ) async -> Result<ProjectBuildConditions, BuildConditionsUnavailable> {
        let arguments = configuration.testCommandArguments
        var targets = await settings(for: arguments, configuration, process: process)
        guard let first = targets.first else {
            return .failure(BuildConditionsUnavailable(reason: "xcodebuild reported no build settings"))
        }
        let withoutActions = argumentsWithoutActions(arguments)
        if withoutActions != arguments {
            let setsConfiguration = arguments.contains("-configuration")
            let testConfiguration = setsConfiguration ? nil : first["CONFIGURATION"]
            targets += await settings(
                for: withoutActions + (testConfiguration.map { ["-configuration", $0] } ?? []),
                configuration,
                process: process
            )
        }

        return .success(ProjectBuildConditions(everyTarget: BuildConditions(
            platform: platform(of: targets, in: arguments, fileManager: fileManager),
            customConditions: targets.map(customConditions(of:)),
            undecidedConditions: namesInBuildFiles(inProjectAt: root, fileManager: fileManager)
        )))
    }

    private typealias Settings = [String: String]

    private struct Target: Decodable {
        let buildSettings: Settings
    }

    private static func settings(
        for arguments: [String],
        _ configuration: MuterConfiguration,
        process: ProcessFactory
    ) async -> [Settings] {
        guard let result = await process().runCommand(
            url: configuration.testCommandExecutable,
            arguments: arguments + ["-showBuildSettings", "-json"]
        ), result.succeeded,
            let targets = try? JSONDecoder().decode([Target].self, from: Data(result.output.utf8))
        else {
            return []
        }
        return targets.map(\.buildSettings)
    }

    private static let actions: Set = [
        "test", "test-without-building", "build", "build-for-testing", "clean", "analyze", "archive",
    ]

    /// `arguments` without xcodebuild's actions, but not a value that reads like one, as in `-scheme test`.
    private static func argumentsWithoutActions(_ arguments: [String]) -> [String] {
        arguments.enumerated().filter { index, argument in
            let isAValue = index > 0 && arguments[index - 1].hasPrefix("-")
            return isAValue || !actions.contains(argument)
        }.map(\.element)
    }

    /// `PLATFORM_NAME`s, and how `os(…)` and `targetEnvironment(…)` read them.
    private static let platforms: [String: (system: String, environment: String?)] = [
        "macosx": ("macOS", nil),
        "iphoneos": ("iOS", nil),
        "iphonesimulator": ("iOS", "simulator"),
        "appletvos": ("tvOS", nil),
        "appletvsimulator": ("tvOS", "simulator"),
        "watchos": ("watchOS", nil),
        "watchsimulator": ("watchOS", "simulator"),
        "xros": ("visionOS", nil),
        "xrsimulator": ("visionOS", "simulator"),
        "driverkit": ("DriverKit", nil),
    ]

    /// The platform all of `targets` build for; nil if they don't agree, or the command gives several destinations,
    /// which can be different platforms, while the settings report only one.
    private static func platform(
        of targets: [Settings],
        in arguments: [String],
        fileManager: FileSystemManager
    ) -> BuildConditions.Platform? {
        let names = Set(targets.compactMap { $0["PLATFORM_NAME"] })
        guard names.count == 1,
              let name = names.first,
              var (system, environment) = platforms[name],
              arguments.filter({ $0 == "-destination" }).count <= 1
        else {
            return nil
        }
        let isCatalyst = targets.contains { $0["IS_MACCATALYST"] == "YES" }
        if isCatalyst {
            (system, environment) = ("iOS", "macCatalyst")
        }
        let architectures = Set(targets.flatMap { ($0["ARCHS"] ?? "").split(separator: " ").map(String.init) })
        guard !architectures.isEmpty else { return nil }

        // A Mac Catalyst build sees the macOS frameworks and the ones for iOS apps on a Mac, and their folders can't
        // say which it may import.
        let modules = isCatalyst ? nil : targets.compactMap { $0["SDKROOT"] }.first.flatMap { sdk in
            BuildConditions.SDKModules(sdk: sdk, fileManager: fileManager)
        }
        return BuildConditions.Platform(
            system: system,
            environment: environment,
            architectures: architectures,
            modules: modules
        )
    }

    private static func customConditions(of target: Settings) -> Set<String> {
        let active = (target["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "").split(whereSeparator: \.isWhitespace)
        let flags = (target["OTHER_SWIFT_FLAGS"] ?? "").split(whereSeparator: \.isWhitespace).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return Set(active.map(String.init)).union(muterCore.customConditions(inSwiftFlags: flags))
    }

    /// Every word in the project's project files, build configuration files and package manifests, and for each that
    /// starts with `D`, the rest of it: in `-DNAME`, the flag's name is glued to its `D`. A word that isn't a condition
    /// costs nothing, as only a name an `#if` asks about is looked up.
    private static func namesInBuildFiles(inProjectAt root: FilePath, fileManager: FileSystemManager) -> Set<String> {
        let buildFiles = (fileManager.subpaths(atPath: root) ?? []).filter { path in
            let name = (path as NSString).lastPathComponent
            return name == "project.pbxproj" || name.hasSuffix(".xcconfig")
                || (name.hasPrefix("Package") && name.hasSuffix(".swift"))
        }
        var names: Set<String> = []
        for path in buildFiles {
            guard let contents = fileManager.contents(atPath: root + "/" + path) else { continue }
            let words = String(decoding: contents, as: UTF8.self).split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            names.formUnion(words.map(String.init))
            names.formUnion(words.filter { $0.hasPrefix("D") }.map { String($0.dropFirst()) })
        }
        return names
    }
}
