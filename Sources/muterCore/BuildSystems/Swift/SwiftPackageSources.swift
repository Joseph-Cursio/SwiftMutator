import Foundation

/// The Swift files a SwiftPM package's targets compile, from `swift package describe`. Discovery mutates only these: a
/// file that no target builds, such as an example app's, gets mutants no test can kill, which count as survivors.
enum SwiftPackageSources {
    /// Why the files couldn't be listed.
    enum Failure: Error, Equatable {
        /// The test command, this executable, isn't `swift`, so it can't be asked to describe the package.
        case notSwift(String)
        /// The package the test command's `--package-path` names, as given, isn't in the project.
        case packageOutsideProject(String)
        /// The command, the test command's executable, couldn't be started.
        case couldNotRun(String)
        /// `swift package describe` of the package at this path failed, with the first line of its errors that says
        /// `error:`, or else its first.
        case describeFailed(packagePath: String, error: String)
        /// What `swift package describe` printed for the package at this path couldn't be read.
        case unreadableDescription(packagePath: String)
        /// There's no package at this path: SwiftPM looked in the folders above it and described another.
        case noPackage(packagePath: String)

        /// Why the files couldn't be listed, to follow "SwiftMutator couldn't tell which files the package's targets
        /// compile: ".
        var reason: String {
            switch self {
            case let .notSwift(command):
                return "the test command, \(command), isn't swift"
            case let .packageOutsideProject(path):
                return "the package the test command names, \(path), isn't in the project"
            case let .couldNotRun(command):
                return "\(command) couldn't be started"
            case let .describeFailed(path, error):
                let failed = "`swift package describe` failed for \(path)"
                return error.isEmpty ? failed : "\(failed): \(error)"
            case let .unreadableDescription(path):
                return "what `swift package describe` printed for \(path) couldn't be read"
            case let .noPackage(path):
                return "there's no Package.swift in \(path)"
            }
        }
    }

    /// The types of target that hold no code under test: a test target, which holds the tests, a plugin, which runs in
    /// the build, and a snippet.
    static let typesNotUnderTest: Set = ["test", "plugin", "snippet"]

    /// The options of the test command that `swift package describe` needs too: without `--disable-sandbox`, it can't
    /// compile the manifest where the tests can't use the sandbox either.
    private static let forwardedFlags: Set = ["--disable-sandbox"]
    /// The options with a value that `swift package describe` needs too: the flags the manifest is compiled with,
    /// which can add or take out targets in `#if` blocks.
    private static let forwardedOptionsWithValues = ["-Xmanifest", "-Xbuild-tools-swiftc"]

    /// The Swift files, relative to the project at `root`, that the tested package compiles, and those of the local
    /// packages in the project that it depends on, at any depth: every target's but those of `typesNotUnderTest`. The
    /// tested package is the one that the test command in `configuration` names with `--package-path`, relative to
    /// `root`, where the command runs, or else the one at `root`. A local package outside the project isn't copied with
    /// it, so its files aren't listed. Nor are the files that a link to a folder leads to outside the project: mutating
    /// them would change the files there. A file that links to folders give two paths is listed once, by its path
    /// without them. A link to a file is listed by its own path, as the mutated file replaces the link in the copy.
    static func files(
        inProjectAt root: FilePath,
        testedBy configuration: MuterConfiguration,
        process: ProcessFactory
    ) async -> Result<[FilePath], Failure> {
        let swift = configuration.testCommandExecutable
        guard (swift as NSString).lastPathComponent == "swift" else {
            return .failure(.notSwift(swift))
        }
        // describe resolves the links in a package's own path, but not those in its local dependencies' paths, so
        // every path is compared with its links resolved.
        let canonicalRoot = root.canonicalPath
        // Relative to `root`, which is "".
        var testedPackage: FilePath = ""
        if let tested = packagePath(in: configuration.testCommandArguments) {
            guard let inProject = projectPath(of: tested, in: root, canonicalRoot: canonicalRoot) else {
                return .failure(.packageOutsideProject(tested))
            }
            testedPackage = inProject
        }
        let options = forwardedOptions(in: configuration.testCommandArguments)

        var files: Set<FilePath> = []
        var described: Set<FilePath> = []
        var toDescribe: [FilePath] = [testedPackage]
        while let package = toDescribe.popLast() {
            guard described.insert(package).inserted else {
                continue
            }
            let description: Description
            let path = package.isEmpty ? root : root + "/" + package
            switch await describe(path, with: swift, options: options, process: process) {
            case let .success(packageDescription):
                description = packageDescription
            case let .failure(failure):
                return .failure(failure)
            }

            for target in description.targets where !typesNotUnderTest.contains(target.type) {
                for source in target.sources ?? [] where source.hasSuffix(".swift") {
                    let sourcePath = joined(package, target.path ?? "", source)
                    if let inProject = projectPath(ofSource: sourcePath, in: root, canonicalRoot: canonicalRoot) {
                        files.insert(inProject)
                    }
                }
            }
            // The package at `root`, too, when the tested one is in a folder of the project and depends on it.
            toDescribe += description.dependencies
                .compactMap(\.path)
                .compactMap { projectPath(of: $0, in: root, canonicalRoot: canonicalRoot) }
        }

        return .success(files.sorted())
    }

    /// The fields of `swift package describe --type json` that say which files a package compiles.
    private struct Description: Decodable {
        /// The package's absolute path, with its links resolved.
        let path: String
        let dependencies: [Dependency]
        let targets: [Target]

        struct Dependency: Decodable {
            /// A local package's absolute path; nil for a package from a repository or a registry.
            let path: String?
        }

        struct Target: Decodable {
            let type: String
            /// Relative to the package. A binary target has no sources.
            let path: String?
            /// Relative to `path`.
            let sources: [String]?
        }
    }

    private static func describe(
        _ packagePath: FilePath,
        with swift: String,
        options: [String],
        process: ProcessFactory
    ) async -> Result<Description, Failure> {
        // `--package-path` is an option of `swift package`, not of `describe`.
        guard let described = await process().runCommand(
            url: swift,
            arguments: ["package", "--package-path", packagePath] + options + ["describe", "--type", "json"]
        ) else {
            return .failure(.couldNotRun(swift))
        }
        guard described.succeeded else {
            let error = SwiftCoverage.firstError(in: described.errors) ?? SwiftCoverage.firstLine(of: described.errors)
            return .failure(.describeFailed(packagePath: packagePath, error: error))
        }
        guard let description = try? JSONDecoder().decode(Description.self, from: Data(described.output.utf8)) else {
            return .failure(.unreadableDescription(packagePath: packagePath))
        }
        // Without a manifest there, SwiftPM describes the first package in the folders above.
        guard description.path.canonicalPath == packagePath.canonicalPath else {
            return .failure(.noPackage(packagePath: packagePath))
        }

        return .success(description)
    }

    /// The value of the last `--package-path` among `arguments`, given as `--package-path <path>` or
    /// `--package-path=<path>`.
    private static func packagePath(in arguments: [String]) -> String? {
        var path: String?
        for (index, argument) in arguments.enumerated() {
            if argument == "--package-path", index + 1 < arguments.count {
                path = arguments[index + 1]
            } else if argument.hasPrefix("--package-path=") {
                path = String(argument.dropFirst("--package-path=".count))
            }
        }
        return path
    }

    /// The options among `arguments` that describe is given too, in their order, each option with a value as given:
    /// `-Xmanifest <flag>` or `-Xmanifest=<flag>`.
    private static func forwardedOptions(in arguments: [String]) -> [String] {
        var options: [String] = []
        for (index, argument) in arguments.enumerated() {
            let isOptionWithItsValue = forwardedOptionsWithValues.contains { argument.hasPrefix($0 + "=") }
            if forwardedFlags.contains(argument) || isOptionWithItsValue {
                options.append(argument)
            } else if forwardedOptionsWithValues.contains(argument), index + 1 < arguments.count {
                options += [argument, arguments[index + 1]]
            }
        }
        return options
    }

    /// `path`, absolute or relative to `root`, relative to the project at `root`: "" for `root` itself, nil outside it.
    /// A path that isn't there has its `..` folders taken out by name, as its links can't be resolved.
    private static func projectPath(of path: String, in root: FilePath, canonicalRoot: FilePath) -> FilePath? {
        let absolute = path.hasPrefix("/") ? path : root + "/" + path
        let resolved = absolute.canonicalPath
        let canonical = resolved == absolute ? URL(fileURLWithPath: absolute).standardized.path : resolved
        return canonical == canonicalRoot ? "" : relativePath(canonical, to: canonicalRoot)
    }

    /// `source`, relative to the project at `root`, with the links in its folders resolved, or nil if they lead
    /// outside the project. A link to the file itself is kept: the mutated file replaces it in the project's copy.
    private static func projectPath(
        ofSource source: FilePath,
        in root: FilePath,
        canonicalRoot: FilePath
    ) -> FilePath? {
        let absolute = (root + "/" + source) as NSString
        return relativePath(
            absolute.deletingLastPathComponent.canonicalPath + "/" + absolute.lastPathComponent,
            to: canonicalRoot
        )
    }

    /// `parts` joined by `/`, without the empty parts and `.` folders that a target at its package's root has.
    private static func joined(_ parts: String...) -> FilePath {
        parts
            .flatMap { $0.split(separator: "/") }
            .filter { $0 != "." }
            .joined(separator: "/")
    }

    /// `path` relative to `root`, if it lies inside it. Both are spelled alike: neither has its links resolved here.
    private static func relativePath(_ path: FilePath, to root: FilePath) -> FilePath? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
}
