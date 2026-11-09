import Foundation
import SwiftIfConfig

/// What a `swift test` command compiles with: the host's platform, unless it cross-compiles, and for each target,
/// `DEBUG` in a debug build, `SWIFT_PACKAGE`, the `.define`s and `-D` flags in its package's manifest, and any
/// `-Xswiftc -D` in the command's arguments, and the language mode of all of them, if they share one. The manifest
/// comes from `swift package dump-package`, and which files each target compiles from `swift package describe`.
enum SwiftPackageBuildConditions {
    /// How xcodebuild builds a package's scheme, where `configuration`'s `swift test` stands for its configuration: for
    /// the destination's platform, with Xcode's own `Xcode` condition besides SwiftPM's, and with the compiler of the
    /// `swift` given, unless the xcodebuild command picks another.
    struct XcodeScheme {
        let platform: BuildConditions.Platform?
        let picksAnotherCompiler: Bool
    }

    static func conditions(
        inProjectAt root: FilePath,
        testedBy configuration: MuterConfiguration,
        process: ProcessFactory,
        fileManager: FileSystemManager,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        xcodeScheme: XcodeScheme? = nil
    ) async -> Result<ProjectBuildConditions, BuildConditionsUnavailable> {
        let packages: [SwiftPackageSources.Package]
        switch await SwiftPackageSources.packages(inProjectAt: root, testedBy: configuration, process: process) {
        case let .success(described): packages = described
        case let .failure(failure): return .failure(BuildConditionsUnavailable(reason: failure.reason))
        }

        var manifests: [Manifest] = []
        for package in packages {
            guard let manifest = await manifest(of: package, testedBy: configuration, process: process) else {
                return .failure(BuildConditionsUnavailable(
                    reason: "`swift package dump-package` gave nothing it could read for \(package.path)"
                ))
            }
            manifests.append(manifest)
        }

        let arguments = configuration.testCommandArguments
        let platform = if let xcodeScheme {
            // Xcode builds a macro, a plugin's tools and what they depend on for the Mac it runs on, whatever the
            // destination. SwiftMutator doesn't tell which files those are.
            builtForTheMac(manifests) && !(xcodeScheme.platform?.isTheMacItself ?? true) ? nil : xcodeScheme.platform
        } else {
            await platform(testedWith: arguments, process: process, fileManager: fileManager)
        }
        let build = Build(
            configuration: buildConfiguration(in: arguments),
            platform: platform?.system.lowercased(),
            flags: customConditions(inSwiftFlags: swiftcFlags(in: arguments)).union(xcodeScheme == nil ? [] : ["Xcode"])
        )

        var targets: [Set<String>] = []
        var ofFile: [FilePath: [Set<String>]] = [:]
        var undecided: Set<String> = []
        var modes: [LanguageMode?] = []
        let buildsToolsWithFlags = arguments.contains {
            $0 == "-Xbuild-tools-swiftc" || $0.hasPrefix("-Xbuild-tools-swiftc=")
        }
        for (package, manifest) in zip(packages, manifests) {
            let unreadable = BuildConditionsUnavailable(
                reason: "`swift package dump-package` gave nothing it could read for \(package.path)"
            )
            undecided.formUnion((manifest.traits ?? []).map(\.name))
            // SwiftPM builds a plugin in its tools version's mode, with `-Xbuild-tools-swiftc`'s flags.
            func languageMode(of target: Manifest.Target) -> LanguageMode? {
                guard target.type == "plugin" else {
                    return build.languageMode(of: target.settings ?? [], default: manifest.defaultLanguageMode)
                }
                return buildsToolsWithFlags ? nil : manifest.toolsVersionsLanguageMode
            }
            // A test target's or a plugin's are no target's here, but `--files-to-mutate` can name their files.
            for other in manifest.targets where !package.targets.contains(where: { $0.name == other.name }) {
                let conditions = build.conditions(of: other.settings ?? [])
                undecided.formUnion(conditions.set.subtracting(build.conditions(of: []).set))
                undecided.formUnion(conditions.undecided)
                modes.append(languageMode(of: other))
            }
            for target in package.targets {
                // Taking a target with no settings to read for one with none would decide its conditions wrongly.
                guard let declared = manifest.targets.first(where: { $0.name == target.name }) else {
                    return .failure(unreadable)
                }
                let conditions = build.conditions(of: declared.settings ?? [])
                targets.append(conditions.set)
                undecided.formUnion(conditions.undecided)
                modes.append(languageMode(of: declared))
                for file in target.files {
                    ofFile[file, default: []].append(conditions.set)
                }
            }
        }

        let compiler = xcodeScheme?.picksAnotherCompiler == true
            ? nil
            : await compilerVersion(testedBy: configuration, process: process, environment: environment)
        let commandSetsTheMode = LanguageMode.isSet(inFlags: swiftcFlags(in: arguments))
        return .success(ProjectBuildConditions(
            everyTarget: BuildConditions(
                platform: platform,
                customConditions: targets,
                undecidedConditions: undecided,
                compiler: compiler,
                language: commandSetsTheMode ? nil : LanguageMode.languageVersion(of: modes, compiler: compiler)
            ),
            customConditionsOfFile: ofFile
        ))
    }

    /// Whether a package has a macro or a plugin, whose tools are built, with what they depend on, for the Mac that
    /// builds.
    private static func builtForTheMac(_ manifests: [Manifest]) -> Bool {
        manifests.contains { $0.targets.contains { $0.type == "macro" || $0.type == "plugin" } }
    }

    /// The options that build with a compiler other than the one `swift --version` names: another toolchain, a
    /// toolset's compiler, or a Swift SDK's.
    private static let compilerPickingOptions = crossCompilingOptions + ["--toolchain", "--toolset"]

    /// The version of the compiler `swift test` builds with: what the same `swift` says it is, run where the tests are,
    /// so that a toolchain picked by a `.swift-version` file there is the one asked. Nil if the command, or
    /// `SWIFT_EXEC`, picks another compiler.
    private static func compilerVersion(
        testedBy configuration: MuterConfiguration,
        process: ProcessFactory,
        environment: [String: String]
    ) async -> VersionTuple? {
        let picksAnotherCompiler = environment["SWIFT_EXEC"] != nil
            || configuration.testCommandArguments.contains { argument in
                compilerPickingOptions.contains { argument == $0 || argument.hasPrefix($0 + "=") }
            }
        let swift = configuration.testCommandExecutable
        guard !picksAnotherCompiler,
              let version = await process().runCommand(url: swift, arguments: ["--version"]),
              version.succeeded
        else {
            return nil
        }
        return muterCore.compilerVersion(inVersionOutput: version.output)
    }

    /// What decides a package's conditions in this build. `platform` is as a manifest's conditions name it; nil if
    /// SwiftMutator can't tell.
    private struct Build {
        let configuration: String
        let platform: String?
        let flags: Set<String>

        /// The conditions a target with `settings` sets, and those that depend on what can't be told here.
        func conditions(of settings: [Manifest.Setting]) -> (set: Set<String>, undecided: Set<String>) {
            var set = flags.union(["SWIFT_PACKAGE"])
            if configuration == "debug" {
                set.insert("DEBUG")
            }
            var undecided: Set<String> = []
            for setting in settings where setting.tool == "swift" {
                let names = setting.kind.define.map { [$0._0] } ?? []
                let flags = customConditions(inSwiftFlags: setting.kind.unsafeFlags?._0 ?? [])
                let declared = Set(names).union(flags)
                switch applies(setting.condition) {
                case true?: set.formUnion(declared)
                case false?: break
                case nil: undecided.formUnion(declared)
                }
            }
            return (set, undecided)
        }

        /// The language mode a target with `settings` builds in, in a package whose own is `packageMode`: the one its
        /// `swiftLanguageMode` sets, if it does. Nil if it can't be told: a setting that may or may not apply, one
        /// SwiftMutator can't read, two that differ, or flags that set it.
        func languageMode(of settings: [Manifest.Setting], default packageMode: LanguageMode?) -> LanguageMode? {
            var targetsOwn: LanguageMode?
            for setting in settings where setting.tool == "swift" {
                let setsIt = setting.kind.setsLanguageMode
                    || LanguageMode.isSet(inFlags: setting.kind.unsafeFlags?._0 ?? [])
                guard setsIt else { continue }
                switch applies(setting.condition) {
                case false?:
                    continue
                case true?:
                    guard let mode = setting.kind.languageMode, targetsOwn == nil || targetsOwn == mode else {
                        return nil
                    }
                    targetsOwn = mode
                case nil:
                    return nil
                }
            }
            return targetsOwn ?? packageMode
        }

        /// Whether a setting with `condition` applies; nil if it can't be told, as for one that a trait enables.
        private func applies(_ condition: Manifest.Condition?) -> Bool? {
            guard let condition else { return true }
            if let config = condition.config, config != configuration {
                return false
            }
            guard (condition.traits ?? []).isEmpty else { return nil }
            let platforms = condition.platformNames ?? []
            guard !platforms.isEmpty else { return true }
            return platform.map(platforms.contains)
        }
    }

    /// The fields of `swift package dump-package` that say what a target compiles with.
    private struct Manifest: Decodable {
        let targets: [Target]
        let traits: [Trait]?
        let toolsVersion: ToolsVersion?
        let swiftLanguageVersions: [String]?

        struct ToolsVersion: Decodable {
            // swiftlint:disable:next identifier_name
            let _version: String
        }

        /// The language mode of a target that sets none: the latest of `swiftLanguageModes`, as a compiler that has
        /// them all builds in, or else the one its tools version sets. Nil for a mode SwiftMutator doesn't know, which
        /// may be the latest, or a tools version before 5.
        var defaultLanguageMode: LanguageMode? {
            if let written = swiftLanguageVersions, !written.isEmpty {
                let modes = written.compactMap(LanguageMode.init)
                return modes.count == written.count ? modes.max() : nil
            }
            return toolsVersionsLanguageMode
        }

        /// The language mode the tools version sets, which a plugin is built in whatever `swiftLanguageModes` says.
        var toolsVersionsLanguageMode: LanguageMode? {
            switch toolsVersion?._version.split(separator: ".").first {
            case "5": return .swift5
            case "6": return .swift6
            default: return nil
            }
        }

        struct Trait: Decodable {
            let name: String
        }

        struct Target: Decodable {
            let name: String
            let type: String?
            let settings: [Setting]?
        }

        struct Setting: Decodable {
            let tool: String
            let kind: Kind
            let condition: Condition?
        }

        struct Kind: Decodable {
            let define: Payload<String>?
            let unsafeFlags: Payload<[String]>?
            /// Whether the setting sets the language mode: `swiftLanguageMode`, `swiftLanguageVersion` as tools
            /// versions before 6 write it, or another spelling of either.
            let setsLanguageMode: Bool
            /// The mode it sets; nil if it sets none, or one SwiftMutator can't read.
            let languageMode: LanguageMode?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: ManifestKey.self)
                define = try container.decodeIfPresent(Payload<String>.self, forKey: ManifestKey("define"))
                unsafeFlags = try container.decodeIfPresent(Payload<[String]>.self, forKey: ManifestKey("unsafeFlags"))
                let modeKeys = container.allKeys.filter { key in
                    let name = key.stringValue.lowercased()
                    return name.contains("languagemode") || name.contains("languageversion")
                }
                setsLanguageMode = !modeKeys.isEmpty
                let known = modeKeys.count == 1 && ["swiftLanguageMode", "swiftLanguageVersion"]
                    .contains(modeKeys[0].stringValue)
                languageMode = known
                    ? (try? container.decode(Payload<String>.self, forKey: modeKeys[0])).flatMap { LanguageMode($0._0) }
                    : nil
            }
        }

        // swiftlint:disable:next identifier_name
        struct Payload<Value: Decodable>: Decodable { let _0: Value }

        struct Condition: Decodable {
            let config: String?
            let platformNames: [String]?
            let traits: [String]?
        }
    }

    private static func manifest(
        of package: SwiftPackageSources.Package,
        testedBy configuration: MuterConfiguration,
        process: ProcessFactory
    ) async -> Manifest? {
        let options = SwiftPackageSources.forwardedOptions(in: configuration.testCommandArguments)
        guard let dumped = await process().runCommand(
            url: configuration.testCommandExecutable,
            arguments: ["package", "--package-path", package.path] + options + ["dump-package"]
        ), dumped.succeeded else {
            return nil
        }
        return try? JSONDecoder().decode(Manifest.self, from: Data(dumped.output.utf8))
    }

    /// `-c`'s or `--configuration`'s value, or `debug`, `swift test`'s default.
    private static func buildConfiguration(in arguments: [String]) -> String {
        var configuration = "debug"
        for (index, argument) in arguments.enumerated() {
            if ["-c", "--configuration"].contains(argument), index + 1 < arguments.count {
                configuration = arguments[index + 1]
            } else if argument.hasPrefix("--configuration=") {
                configuration = String(argument.dropFirst("--configuration=".count))
            }
        }
        return configuration
    }

    /// The flags `-Xswiftc` passes to the compiler, in their order, as `-Xswiftc -DNAME` or `-Xswiftc=-DNAME`.
    private static func swiftcFlags(in arguments: [String]) -> [String] {
        var flags: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-Xswiftc", index + 1 < arguments.count {
                flags.append(arguments[index + 1])
                index += 1
            } else if argument.hasPrefix("-Xswiftc=") {
                flags.append(String(argument.dropFirst("-Xswiftc=".count)))
            }
            index += 1
        }
        return flags
    }

    /// The options that build for another platform than the host.
    private static let crossCompilingOptions = [
        "--triple", "--arch", "--swift-sdk", "--experimental-swift-sdk", "--destination", "--sdk",
    ]

    /// The host's platform; nil if `arguments` build for another, or SwiftMutator doesn't know its own.
    private static func platform(
        testedWith arguments: [String],
        process: ProcessFactory,
        fileManager: FileSystemManager
    ) async -> BuildConditions.Platform? {
        let crossCompiles = arguments.contains { argument in
            crossCompilingOptions.contains { argument == $0 || argument.hasPrefix($0 + "=") }
        }
        guard !crossCompiles else { return nil }

        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        return nil
        #endif

        #if os(macOS)
        let sdk: String? = await process().runProcess(
            url: "/usr/bin/xcrun",
            arguments: ["--sdk", "macosx", "--show-sdk-path"]
        )
        return BuildConditions.Platform(
            system: "macOS",
            architectures: [architecture],
            modules: sdk.flatMap { BuildConditions.SDKModules(sdk: $0.trimmed, fileManager: fileManager) }
        )
        #elseif os(Linux)
        return BuildConditions.Platform(system: "Linux", architectures: [architecture], modules: .withoutAnSDK)
        #else
        return nil
        #endif
    }
}

/// Any key of a manifest's JSON, for a setting whose keys aren't all known.
private struct ManifestKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) {
        stringValue = name
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

private extension BuildConditions.Platform {
    /// Whether this is the Mac that builds, as a macOS destination with no architecture names it.
    var isTheMacItself: Bool {
        system == "macOS" && environment == nil && architectures == nil
    }
}
