import Foundation

/// What a `swift test` command compiles with: the host's platform, unless it cross-compiles, and for each target,
/// `DEBUG` in a debug build, `SWIFT_PACKAGE`, the `.define`s and `-D` flags in its package's manifest, and any
/// `-Xswiftc -D` in the command's arguments. The manifest comes from `swift package dump-package`, and which files each
/// target compiles from `swift package describe`.
enum SwiftPackageBuildConditions {
    static func conditions(
        inProjectAt root: FilePath,
        testedBy configuration: MuterConfiguration,
        process: ProcessFactory,
        fileManager: FileSystemManager
    ) async -> Result<ProjectBuildConditions, BuildConditionsUnavailable> {
        let packages: [SwiftPackageSources.Package]
        switch await SwiftPackageSources.packages(inProjectAt: root, testedBy: configuration, process: process) {
        case let .success(described): packages = described
        case let .failure(failure): return .failure(BuildConditionsUnavailable(reason: failure.reason))
        }

        let arguments = configuration.testCommandArguments
        let platform = await platform(testedWith: arguments, process: process, fileManager: fileManager)
        let build = Build(
            configuration: buildConfiguration(in: arguments),
            platform: platform?.system.lowercased(),
            flags: customConditions(inSwiftFlags: swiftcFlags(in: arguments))
        )

        var targets: [Set<String>] = []
        var ofFile: [FilePath: [Set<String>]] = [:]
        var undecided: Set<String> = []
        for package in packages {
            let unreadable = BuildConditionsUnavailable(
                reason: "`swift package dump-package` gave nothing it could read for \(package.path)"
            )
            guard let manifest = await manifest(of: package, testedBy: configuration, process: process) else {
                return .failure(unreadable)
            }
            undecided.formUnion((manifest.traits ?? []).map(\.name))
            // A test target's or a plugin's are no target's here, but `--files-to-mutate` can name their files.
            for other in manifest.targets where !package.targets.contains(where: { $0.name == other.name }) {
                let conditions = build.conditions(of: other.settings ?? [])
                undecided.formUnion(conditions.set.subtracting(build.conditions(of: []).set))
                undecided.formUnion(conditions.undecided)
            }
            for target in package.targets {
                // Taking a target with no settings to read for one with none would decide its conditions wrongly.
                guard let declared = manifest.targets.first(where: { $0.name == target.name }) else {
                    return .failure(unreadable)
                }
                let conditions = build.conditions(of: declared.settings ?? [])
                targets.append(conditions.set)
                undecided.formUnion(conditions.undecided)
                for file in target.files {
                    ofFile[file, default: []].append(conditions.set)
                }
            }
        }

        return .success(ProjectBuildConditions(
            everyTarget: BuildConditions(platform: platform, customConditions: targets, undecidedConditions: undecided),
            customConditionsOfFile: ofFile
        ))
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

        struct Trait: Decodable {
            let name: String
        }

        struct Target: Decodable {
            let name: String
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

    /// The flags `-Xswiftc` passes to the compiler, in their order.
    private static func swiftcFlags(in arguments: [String]) -> [String] {
        arguments.indices.dropLast().filter { arguments[$0] == "-Xswiftc" }.map { arguments[$0 + 1] }
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
