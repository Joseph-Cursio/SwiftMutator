import Foundation
import SwiftIfConfig

/// What an xcodebuild test command compiles with, from `xcodebuild -showBuildSettings`, which follows its
/// `-destination`.
enum XcodeBuildConditions {
    /// `-showBuildSettings` reports the targets of an action: for `test`, the test bundles and not the app they test;
    /// with no action, the scheme's own. So it is asked both ways, the second for the configuration the first reports,
    /// which a scheme's test action can set apart from the project's default.
    ///
    /// It reports no target that a scheme's targets only depend on, and no local package's, so a condition no reported
    /// target sets is left undecided if a build file in the project names it. After a build, `afterABuild`, which
    /// target compiled each file is in the lists of files the build left (`filesOfEachTarget`). A Swift package's
    /// scheme has no settings at all, so its conditions come from its manifest (`PackageSchemeBuildConditions`).
    static func conditions(
        inProjectAt root: FilePath,
        testedBy configuration: MuterConfiguration,
        process: ProcessFactory,
        fileManager: FileSystemManager,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        afterABuild: Bool = false
    ) async -> Result<ProjectBuildConditions, BuildConditionsUnavailable> {
        let arguments = configuration.testCommandArguments
        guard var targets = await settings(for: arguments, configuration, process: process) else {
            return .failure(BuildConditionsUnavailable(reason: "xcodebuild reported no build settings"))
        }
        guard let first = targets.first else {
            return await PackageSchemeBuildConditions.conditions(
                inProjectAt: root,
                testedBy: configuration,
                process: process,
                fileManager: fileManager,
                environment: environment
            )
        }
        let withoutActions = argumentsWithoutActions(arguments)
        if withoutActions != arguments {
            let setsConfiguration = arguments.contains("-configuration")
            let testConfiguration = setsConfiguration ? nil : first["CONFIGURATION"]
            targets += await settings(
                for: withoutActions + (testConfiguration.map { ["-configuration", $0] } ?? []),
                configuration,
                process: process
            ) ?? []
        }

        let buildFiles = buildFiles(inProjectAt: root, fileManager: fileManager)
        let namesInBuildFiles = names(in: buildFiles, arguments: arguments, environment: environment)
        // A build file the scan didn't read may set conditions, for a target xcodebuild didn't report, that no file
        // it read names.
        let aBuildFileItDidntReadMaySetSome = mayHaveUnreadBuildFiles(buildFiles, arguments, environment, root: root)
        // A target xcodebuild didn't report, such as the framework the tests test, may build with its own compiler.
        let aTargetMayPickItsCompiler = aBuildFileItDidntReadMaySetSome
            || !namesInBuildFiles.isDisjoint(with: ["TOOLCHAINS", "SWIFT_EXEC"])
        let compiler = aTargetMayPickItsCompiler
            ? nil
            : await compilerVersion(of: targets, in: arguments, process: process)
        let ofFile = afterABuild && !aBuildFileItDidntReadMaySetSome
            ? filesOfEachTarget(of: targets, buildFiles: buildFiles, root: root, fileManager: fileManager)
            : [:]
        return .success(ProjectBuildConditions(
            everyTarget: BuildConditions(
                platform: platform(of: targets, in: arguments, fileManager: fileManager),
                customConditions: targets.map(customConditions(of:)),
                undecidedConditions: namesInBuildFiles,
                compiler: compiler,
                language: languageVersion(
                    of: targets,
                    in: arguments,
                    buildFiles: buildFiles,
                    compiler: compiler,
                    aBuildFileItDidntReadMaySetIt: aBuildFileItDidntReadMaySetSome
                ),
                anyConditionMayBeSetElsewhere: aBuildFileItDidntReadMaySetSome
                    || mayComposeConditions(buildFiles, arguments, environment)
            ),
            customConditionsOfFile: ofFile,
            filesWithAllTheirConditions: Set(ofFile.keys)
        ))
    }

    /// The custom conditions of every target that compiled each file in the build just run, by the file's path in the
    /// project, for each file that only reported targets compiled. Empty if SwiftMutator can't tell.
    ///
    /// Every target that compiles Swift leaves a list of the files it compiled, at `SWIFT_RESPONSE_FILE_PATH_…` in
    /// its settings, under `OBJROOT` in derived data: those of the targets `-showBuildSettings` doesn't report too, as
    /// a framework the app only depends on and a local package's. A file in any list but a reported target's may build
    /// with conditions SwiftMutator can't see, and is left to `everyTarget`. A list from an earlier build, of a target
    /// since removed or of another configuration, holds what it held: it can only leave more files to `everyTarget`.
    /// A reported target's own, if this build didn't compile it, only adds a target to its files, which decides less.
    ///
    /// It goes by the lists only where they are all that can compile a file: all reported targets share an `OBJROOT`
    /// in derived data, no build file moves a target's intermediate files elsewhere, references another project,
    /// which may be outside the project, has a target an external tool builds, runs the compiler itself, or a script
    /// SwiftMutator can't read, or sets anything for an architecture or build variant, which `-showBuildSettings`
    /// doesn't resolve as the build does, and the caller has found no build configuration file it didn't read, which
    /// may do any of that.
    private static func filesOfEachTarget(
        of targets: [Settings],
        buildFiles: [BuildFile],
        root: FilePath,
        fileManager: FileSystemManager
    ) -> [FilePath: [Set<String>]] {
        let objectRoots = Set(targets.map { $0["OBJROOT"] ?? "" })
        guard objectRoots.count == 1,
              let objectRoot = objectRoots.first,
              objectRoot.hasSuffix("/Build/Intermediates.noindex"),
              !buildFiles.contains(where: { mayCompileOutOfSight($0) }),
              !buildFiles.contains(where: { runsAScriptThatMayCompile($0, fileManager: fileManager) })
        else {
            return [:]
        }

        // The conditions of a reported target, by each of its lists, unless its flags may hide some.
        var targetsOfList: [FilePath: [Set<String>]] = [:]
        for target in targets where readableConditions(of: target) {
            for (setting, list) in target where setting.hasPrefix("SWIFT_RESPONSE_FILE_PATH_") {
                targetsOfList[list.canonicalPath, default: []].append(customConditions(of: target))
            }
        }

        var unreported: Set<FilePath> = []
        var reported: [FilePath: (spellings: Set<FilePath>, targets: [Set<String>])] = [:]
        var aReportedListIsAllThere = false
        for list in fileLists(under: objectRoot, fileManager: fileManager) {
            guard let contents = fileManager.contents(atPath: list),
                  let files = filePaths(inFileList: String(decoding: contents, as: UTF8.self))
            else {
                return [:]
            }
            guard let listTargets = targetsOfList[list.canonicalPath] else {
                unreported.formUnion(files.map(\.canonicalPath))
                continue
            }
            aReportedListIsAllThere = aReportedListIsAllThere || files.allSatisfy(fileManager.fileExists)
            for file in files {
                reported[file.canonicalPath, default: ([], [])].spellings.insert(file)
                reported[file.canonicalPath, default: ([], [])].targets += listTargets
            }
        }
        // Lists that each name a file that's there, as a check that they read as Xcode writes them.
        guard aReportedListIsAllThere else { return [:] }

        let roots = Set([root, root.canonicalPath]).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var ofFile: [FilePath: [Set<String>]] = [:]
        for (file, found) in reported where !unreported.contains(file) {
            for spelling in found.spellings.union([file]) {
                if let matchedRoot = roots.first(where: spelling.hasPrefix) {
                    ofFile[String(spelling.dropFirst(matchedRoot.count))] = found.targets
                }
            }
        }
        return ofFile
    }

    /// Whether a target's conditions are all in its `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and `OTHER_SWIFT_FLAGS` as
    /// `customConditions(of:)` reads them: neither quotes, escapes nor refers to anything, and no flag is a response
    /// file, which can hold more.
    private static func readableConditions(of target: Settings) -> Bool {
        let written = (target["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "") + " " + (target["OTHER_SWIFT_FLAGS"] ?? "")
        return !written.contains { "\"'\\$@`".contains($0) }
    }

    /// The settings that put a target's intermediate files, its file list among them, somewhere.
    private static let buildFolderSettings: Set = [
        "OBJROOT", "SYMROOT", "BUILD_DIR", "BUILD_ROOT", "PROJECT_TEMP_DIR", "PROJECT_TEMP_ROOT",
        "CONFIGURATION_TEMP_DIR", "TARGET_TEMP_DIR", "TEMP_DIR", "TEMP_ROOT", "TEMP_FILES_DIR", "OBJECT_FILE_DIR",
        "SWIFT_RESPONSE_FILE_PATH", "SHARED_PRECOMPS_DIR", "DERIVED_DATA_DIR",
    ]

    /// What in a build file may compile a file SwiftMutator doesn't find in a list in `OBJROOT`, or with conditions
    /// `-showBuildSettings` doesn't report: in workspace settings, a build location of their own; and in a project file
    /// or build configuration file, a setting for an architecture or variant, another project, a target an external
    /// tool builds, a script that runs the compiler or another build, or a setting that moves intermediate files.
    private static func mayCompileOutOfSight(_ file: BuildFile) -> Bool {
        // A workspace's projects are the caller's: it goes by the lists only where it read all their build files,
        // which this then looks at in turn.
        if file.name.hasSuffix(".xcsettings") {
            return file.text.contains("BuildLocation")
        }
        return tellTales.contains { file.text.contains($0) } || names(in: [file]).contains { name in
            buildFolderSettings.contains { name == $0 || name.hasPrefix($0 + "_") }
                || perCompileSettings.contains(name)
        }
    }

    /// Text in a build file or script that may compile Swift out of the lists' sight, or set something for one
    /// architecture or variant: by a condition on a setting, or by a reference to one, as `$(FLAGS_$(arch))`, which
    /// `-showBuildSettings` resolves with none.
    private static let tellTales = [
        "[arch=", "[variant=", "(arch)", "{arch}", "(variant)", "{variant}", "PBXLegacyTarget", "wrapper.pb-project",
        "swiftc", "swift-frontend", "swift build", "xcodebuild",
    ]

    /// The settings the build sets for each compile, for an architecture or variant, that `-showBuildSettings` reports
    /// with none.
    private static let perCompileSettings: Set = ["CURRENT_ARCH", "CURRENT_VARIANT", "NATIVE_ARCH", "ACTION"]

    /// How a Run Script phase names the folder of its project.
    private static let projectFolderReferences = [
        "${SRCROOT}", "$SRCROOT", "$(SRCROOT)", "${PROJECT_DIR}", "$PROJECT_DIR", "$(PROJECT_DIR)",
    ]

    /// The kinds of file a Run Script phase may run.
    private static let scriptExtensions = [".sh", ".bash", ".zsh", ".py", ".rb", ".pl", ".command", ".swift"]

    /// Whether a project file has a Run Script phase that runs a script SwiftMutator can't read, or that holds a tell
    /// tale: one outside the project, by a path that leaves it, starts from a variable it doesn't follow, or names no
    /// file. A script runs in the folder of the project, which `SRCROOT` and `PROJECT_DIR` name.
    private static func runsAScriptThatMayCompile(_ file: BuildFile, fileManager: FileSystemManager) -> Bool {
        guard file.name == "project.pbxproj" else { return false }
        let projectFolder = file.path.deletingLastPathComponent.deletingLastPathComponent
        let scripts = file.text.split(whereSeparator: \.isNewline).filter { $0.contains("shellScript = ") }
        for script in scripts {
            if script.contains("../") || script.contains("~/") || script.contains("$HOME") {
                return true
            }
            let words = script.replacingOccurrences(of: "\\n", with: " ")
                .split { $0.isWhitespace || "\"';|&<>`".contains($0) || $0 == "\\" }
            for word in words where scriptExtensions.contains(where: word.hasSuffix) {
                var path = String(word)
                for folder in projectFolderReferences {
                    path = path.replacingOccurrences(of: folder, with: projectFolder)
                }
                if !path.hasPrefix("/") {
                    path = projectFolder + "/" + path
                }
                guard !path.contains("$"), path.hasPrefix(projectFolder + "/"),
                      let contents = fileManager.contents(atPath: path)
                else {
                    return true
                }
                let text = String(decoding: contents, as: UTF8.self)
                if tellTales.contains(where: text.contains) {
                    return true
                }
            }
        }
        return false
    }

    /// The paths of the file lists under `objectRoot`, at `<project or package>.build/<configuration>/<target>.build/
    /// Objects-<variant>/<architecture>/<product>.SwiftFileList`.
    private static func fileLists(under objectRoot: FilePath, fileManager: FileSystemManager) -> [FilePath] {
        func entries(of folder: FilePath, endingIn suffix: String = "") -> [FilePath] {
            ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasSuffix(suffix) }
                .map { folder + "/" + $0 }
        }
        return entries(of: objectRoot, endingIn: ".build")
            .flatMap { entries(of: $0) }
            .flatMap { entries(of: $0, endingIn: ".build") }
            .flatMap { target in
                entries(of: target).filter { ($0).lastPathComponent.hasPrefix("Objects-") }
            }
            .flatMap { entries(of: $0) }
            .flatMap { entries(of: $0, endingIn: ".SwiftFileList") }
    }

    /// The paths in a file list: one a line, with a backslash before a space, a quote or a backslash in one. Nil if a
    /// line isn't an absolute path.
    static func filePaths(inFileList text: String) -> [FilePath]? {
        var paths: [FilePath] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var path = ""
            var escaped = false
            for character in line {
                if escaped || character != "\\" {
                    path.append(character)
                    escaped = false
                } else {
                    escaped = true
                }
            }
            guard path.hasPrefix("/"), !escaped else { return nil }
            paths.append(path)
        }
        return paths
    }

    private typealias Settings = [String: String]

    /// The toolchain Xcode builds with unless a project, the command or `TOOLCHAINS` picks another.
    private static let defaultToolchain = "com.apple.dt.toolchain.XcodeDefault"

    /// The version of the compiler all of `targets` build with: what their `TOOLCHAIN_DIR`'s `swiftc` says it is. Nil
    /// if they don't agree, or one sets `SWIFT_EXEC` or a toolchain other than Xcode's own, or the command picks one
    /// with `-toolchain`, which `TOOLCHAIN_DIR` may not follow. The caller doesn't ask when a build file or the command
    /// names either setting, as it may be an unreported target's, or when a build file it didn't read may set one.
    private static func compilerVersion(
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

    private struct Target: Decodable {
        let buildSettings: Settings
    }

    /// The settings of each target `-showBuildSettings` reports, none for a package's scheme; nil if it failed.
    private static func settings(
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
    private static func argumentsWithoutActions(_ arguments: [String]) -> [String] {
        XcodebuildArguments(arguments).leavingOut { $0.kind == .action }
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

    /// The language version of every target the build may compile: that of the one mode the reported targets'
    /// `SWIFT_VERSION` and every `SWIFT_VERSION` a build file sets all give, as a target xcodebuild didn't report may
    /// have its own. Nil if they don't all give one, and the same; if a flag sets the mode, which SwiftMutator doesn't
    /// follow; if a build configuration file it didn't read may set one, as `-xcconfig`'s or `XCODE_XCCONFIG_FILE`'s;
    /// or if the project has a package, whose targets' modes the manifest sets.
    private static func languageVersion(
        of targets: [Settings],
        in _: [String],
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

    /// Whether a build file SwiftMutator didn't read may set what a target builds with: a build configuration file
    /// that `-xcconfig` or `XCODE_XCCONFIG_FILE` names, or a project file or build configuration file bases settings
    /// on (`namesAnUnreadConfigurationFile`), outside the project or where SwiftMutator can't tell, or the project
    /// file or manifest of a project or package a workspace or another project references, likewise, with build
    /// files of its own. `root` is the folder the test command runs in, which a relative path is from.
    static func mayHaveUnreadBuildFiles(
        _ buildFiles: [BuildFile],
        _ arguments: [String],
        _ environment: [String: String],
        root: FilePath
    ) -> Bool {
        let readProjects = Set(buildFiles.filter { $0.name == "project.pbxproj" }.map(\.path.canonicalPath))
        let readManifests = Set(buildFiles.filter { $0.name == "Package.swift" }.map(\.path.canonicalPath))
        let readConfigurationFiles = Set(
            buildFiles.filter { $0.name.hasSuffix(".xcconfig") }.map(\.path.canonicalPath)
        )
        let referencesAnotherProject = buildFiles.contains { file in
            if file.name == "contents.xcworkspacedata" {
                return referencesAnUnreadProject(file, readProjects: readProjects, readManifests: readManifests)
            }
            guard file.name == "project.pbxproj" else { return false }
            return referencedProjects(ofProject: file).map { projects in
                !projects.allSatisfy { readProjects.contains(($0 + "/project.pbxproj").canonicalPath) }
            } ?? true
        }
        // A `PROJECT_DIR=…` argument moves the folder a project file's paths are resolved from.
        let movesTheProjectFolder = arguments.contains { argument in
            argument.firstIndex(of: "=").map { projectFolderSettings.contains(String(argument[..<$0])) } ?? false
        }
        let commandsFilesAreRead = configurationFiles(ofCommand: arguments, environment, root: root).map { files in
            files.allSatisfy { file in
                [file, lexicallyNormalized(file)].allSatisfy { readConfigurationFiles.contains($0.canonicalPath) }
            }
        } ?? false
        return !commandsFilesAreRead
            || movesTheProjectFolder
            || namesAnUnreadConfigurationFile(buildFiles)
            || referencesAnotherProject
    }

    /// A project file, build configuration file or package manifest in the project, as `buildFiles` reads it.
    struct BuildFile {
        let name: String
        let text: String
        /// Where it is; empty if that doesn't matter.
        var path: FilePath = ""

        var isPackageManifest: Bool {
            name.hasPrefix("Package") && name.hasSuffix(".swift")
        }
    }

    /// The project's project files, build configuration files, package manifests, and workspaces' contents and
    /// settings.
    private static func buildFiles(inProjectAt root: FilePath, fileManager: FileSystemManager) -> [BuildFile] {
        (fileManager.subpaths(atPath: root) ?? []).compactMap { path in
            let name = path.lastPathComponent
            let isABuildFile = name == "project.pbxproj" || name.hasSuffix(".xcconfig")
                || (name.hasPrefix("Package") && name.hasSuffix(".swift"))
                || name == "contents.xcworkspacedata" || name.hasSuffix(".xcsettings")
            guard isABuildFile, let contents = fileManager.contents(atPath: root + "/" + path) else { return nil }
            return BuildFile(name: name, text: String(decoding: contents, as: UTF8.self), path: root + "/" + path)
        }
    }

    /// Every word in the build files, and for each that starts with `D`, the rest of it: in `-DNAME`, the flag's name
    /// is glued to its `D`. A word that isn't a condition costs nothing, as only a name an `#if` asks about is looked
    /// up.
    private static func names(in buildFiles: [BuildFile]) -> Set<String> {
        names(inText: buildFiles.map(\.text))
    }

    /// The names in the build files, and in the build settings the test command sets: its `NAME=value` arguments, and
    /// the environment variables xcodebuild may read as settings, those a build file or another such value names and
    /// those that set conditions. A target xcodebuild didn't report may use one that no reported target does, as
    /// `$(CORE_FLAGS)` for `CORE_FLAGS=-DCORE_ONLY`.
    private static func names(
        in buildFiles: [BuildFile],
        arguments: [String],
        environment: [String: String]
    ) -> Set<String> {
        var names = names(in: buildFiles)
            .union(names(inText: arguments.filter { $0.contains("=") }))
            .union(["OTHER_SWIFT_FLAGS", "SWIFT_ACTIVE_COMPILATION_CONDITIONS"])
        var read: Set<String> = []
        var unread = environment.filter { names.contains($0.key) }
        while !unread.isEmpty {
            read.formUnion(unread.keys)
            names.formUnion(self.names(inText: Array(unread.values)))
            unread = environment.filter { names.contains($0.key) && !read.contains($0.key) }
        }
        return names
    }

    private static func names(inText texts: [String]) -> Set<String> {
        var names: Set<String> = []
        for text in texts {
            let words = text.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            names.formUnion(words.map(String.init))
            names.formUnion(words.filter { $0.hasPrefix("D") }.map { String($0.dropFirst()) })
        }
        return names
    }
}
