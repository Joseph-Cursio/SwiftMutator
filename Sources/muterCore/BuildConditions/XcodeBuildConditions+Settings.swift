import Foundation
import SwiftIfConfig

extension XcodeBuildConditions {
    typealias Settings = [String: String]

    /// The toolchain Xcode builds with unless a project, the command or `TOOLCHAINS` picks another.
    static let defaultToolchain = "com.apple.dt.toolchain.XcodeDefault"

    /// The version of the compiler all of `targets` build with: what their `TOOLCHAIN_DIR`'s `swiftc` says it is. Nil
    /// if they don't agree, or one sets `SWIFT_EXEC` or a toolchain other than Xcode's own, or the command picks one
    /// with `-toolchain`, which `TOOLCHAIN_DIR` may not follow. The caller doesn't ask when a build file or the command
    /// names either setting, as it may be an unreported target's, or when a build file it didn't read may set one.
    static func compilerVersion(
        of targets: [Settings],
        in arguments: [String],
        process: ProcessFactory
    ) async -> VersionTuple? {
        let toolchains = Set(targets.map { $0["TOOLCHAIN_DIR"] ?? "" })
        let buildWithXcodesCompiler = targets.allSatisfy {
            ($0["SWIFT_EXEC"] ?? "").isEmpty && $0["TOOLCHAINS"] == defaultToolchain
        }
        guard toolchains.count == 1,
              let toolchain = toolchains.first,
              !toolchain.isEmpty,
              buildWithXcodesCompiler,
              !arguments.contains("-toolchain"),
              let version = await process().runCommand(url: toolchain + "/usr/bin/swiftc", arguments: ["--version"]),
              version.succeeded
        else {
            return nil
        }
        return muterCore.compilerVersion(inVersionOutput: version.output)
    }

    struct Target: Decodable {
        let buildSettings: Settings
    }

    /// The settings of each target `-showBuildSettings` reports, none for a package's scheme; nil if it failed.
    static func settings(
        for arguments: [String],
        _ configuration: MuterConfiguration,
        process: ProcessFactory
    ) async -> [Settings]? {
        guard let result = await process().runCommand(
            url: configuration.testCommandExecutable,
            arguments: arguments + ["-showBuildSettings", "-json"]
        ), result.succeeded,
            let targets = try? JSONDecoder().decode([Target].self, from: Data(result.output.utf8))
        else {
            return nil
        }
        return targets.map(\.buildSettings)
    }

    /// `arguments` without xcodebuild's actions, but not a value that reads like one, as in `-scheme test`. Only an
    /// option that takes a value has one, so the `test` after an option that stands alone, as `-quiet` or
    /// `-skipMacroValidation`, is still an action.
    static func argumentsWithoutActions(_ arguments: [String]) -> [String] {
        XcodebuildArguments(arguments).leavingOut { $0.kind == .action }
    }

    /// `PLATFORM_NAME`s, and how `os(…)` and `targetEnvironment(…)` read them.
    static let platforms: [String: (system: String, environment: String?)] = [
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
    static func platform(
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

    static func customConditions(of target: Settings) -> Set<String> {
        let active = (target["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "").split(whereSeparator: \.isWhitespace)
        let flags = (target["OTHER_SWIFT_FLAGS"] ?? "").split(whereSeparator: \.isWhitespace).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return Set(active.map(String.init)).union(muterCore.customConditions(inSwiftFlags: flags))
    }

    /// The language version of every target the build may compile: that of the one mode the reported targets'
    /// `SWIFT_VERSION` and every `SWIFT_VERSION` a build file sets all give, as a target xcodebuild didn't report may
    /// have its own. Nil if they don't all give one, and the same; if a flag sets the mode, which SwiftMutator doesn't
    /// follow; if a build configuration file it didn't read may set one, as `-xcconfig`'s or `XCODE_XCCONFIG_FILE`'s;
    /// or if the project has a package, whose targets' modes the manifest sets.
    static func languageVersion(
        of targets: [Settings],
        buildFiles: [BuildFile],
        compiler: VersionTuple?,
        aBuildFileItDidntReadMaySetIt: Bool
    ) -> VersionTuple? {
        guard !aBuildFileItDidntReadMaySetIt else { return nil }
        let flags = targets.flatMap {
            ($0["OTHER_SWIFT_FLAGS"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        }
        let aFlagSetsTheMode = LanguageMode.isSet(inFlags: flags) || buildFiles.contains {
            $0.text.contains("-swift-version") || $0.text.contains("-language-mode")
        }
        guard !aFlagSetsTheMode, !buildFiles.contains(where: \.isPackageManifest) else { return nil }
        let modes = targets.map { $0["SWIFT_VERSION"].flatMap(LanguageMode.init) }
            + buildFiles.flatMap { swiftVersions(in: $0.text) }
        return LanguageMode.languageVersion(of: modes, compiler: compiler)
    }

    /// The mode of each `SWIFT_VERSION = …` in a project file or build configuration file: nil for a value that isn't
    /// one, such as `$(inherited)`, and for a mention it can't read as a setting, which may still be one. A setting
    /// for some configurations or SDKs counts too, as `SWIFT_VERSION[config=Debug][sdk=*] = 5`, and as a project file
    /// writes it, `"SWIFT_VERSION[sdk=iphoneos*]" = 5.0;`.
    static func swiftVersions(in text: String) -> [LanguageMode?] {
        let isPartOfAName: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        var modes: [LanguageMode?] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(line)
            while let found = rest.range(of: "SWIFT_VERSION") {
                let before = rest[..<found.lowerBound].last
                var after = rest[found.upperBound...]
                rest = after
                // Not part of another name, as EFFECTIVE_SWIFT_VERSION or SWIFT_VERSION_X.
                guard !(before.map(isPartOfAName) ?? false), !(after.first.map(isPartOfAName) ?? false) else {
                    continue
                }
                while after.first == "[", let close = after.firstIndex(of: "]") {
                    after = after[after.index(after: close)...]
                }
                if after.first == "\"" {
                    after = after.dropFirst()
                }
                after = after.drop { $0 == " " || $0 == "\t" }
                guard after.first == "=" else {
                    modes.append(nil)
                    continue
                }
                let written = after.dropFirst().prefix { $0 != ";" }.components(separatedBy: "//")[0]
                modes.append(LanguageMode(written.trimmingCharacters(in: .whitespaces)))
            }
        }
        return modes
    }
}
