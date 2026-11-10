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

        let manifests: [PackageManifest]
        switch await Self.manifests(of: packages, testedBy: configuration, process: process) {
        case let .success(dumped): manifests = dumped
        case let .failure(failure): return .failure(failure)
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

        var gathered = TargetConditions()
        let buildsToolsWithFlags = arguments.contains {
            $0 == "-Xbuild-tools-swiftc" || $0.hasPrefix("-Xbuild-tools-swiftc=")
        }
        for (package, manifest) in zip(packages, manifests) {
            guard gathered.add(package, manifest: manifest, build: build, buildsToolsWithFlags: buildsToolsWithFlags)
            else {
                return .failure(BuildConditionsUnavailable(
                    reason: "`swift package dump-package` gave nothing it could read for \(package.path)"
                ))
            }
        }

        let compiler = xcodeScheme?.picksAnotherCompiler == true
            ? nil
            : await compilerVersion(testedBy: configuration, process: process, environment: environment)
        let commandSetsTheMode = LanguageMode.isSet(inFlags: swiftcFlags(in: arguments))
        let language = commandSetsTheMode ? nil : LanguageMode.languageVersion(of: gathered.modes, compiler: compiler)
        return .success(ProjectBuildConditions(
            everyTarget: BuildConditions(
                platform: platform,
                customConditions: gathered.targets,
                undecidedConditions: gathered.undecided,
                compiler: compiler,
                language: language
            ),
            customConditionsOfFile: gathered.ofFile
        ))
    }

    /// The manifest of each of `packages`, from `swift package dump-package`.
    private static func manifests(
        of packages: [SwiftPackageSources.Package],
        testedBy configuration: MuterConfiguration,
        process: ProcessFactory
    ) async -> Result<[PackageManifest], BuildConditionsUnavailable> {
        var manifests: [PackageManifest] = []
        for package in packages {
            guard let manifest = await manifest(of: package, testedBy: configuration, process: process) else {
                return .failure(BuildConditionsUnavailable(
                    reason: "`swift package dump-package` gave nothing it could read for \(package.path)"
                ))
            }
            manifests.append(manifest)
        }
        return .success(manifests)
    }

    /// Whether a package has a macro or a plugin, whose tools are built, with what they depend on, for the Mac that
    /// builds.
    private static func builtForTheMac(_ manifests: [PackageManifest]) -> Bool {
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

    private static func manifest(
        of package: SwiftPackageSources.Package,
        testedBy configuration: MuterConfiguration,
        process: ProcessFactory
    ) async -> PackageManifest? {
        let options = SwiftPackageSources.forwardedOptions(in: configuration.testCommandArguments)
        guard let dumped = await process().runCommand(
            url: configuration.testCommandExecutable,
            arguments: ["package", "--package-path", package.path] + options + ["dump-package"]
        ), dumped.succeeded else {
            return nil
        }
        return try? JSONDecoder().decode(PackageManifest.self, from: Data(dumped.output.utf8))
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

private extension BuildConditions.Platform {
    /// Whether this is the Mac that builds, as a macOS destination with no architecture names it.
    var isTheMacItself: Bool {
        system == "macOS" && environment == nil && architectures == nil
    }
}
