import Foundation

/// Works out how a mutant's tests would run directly, on macOS: the helper, the build's products and the bundles.
private struct DirectTestRunProber {
    typealias Unavailable = DirectTestRun.Unavailable

    @Dependency(\.process)
    var process: ProcessFactory
    @Dependency(\.fileManager)
    var fileManager: FileSystemManager

    func probe(_ configuration: MuterConfiguration, in project: URL) async -> Result<DirectTestRun, Unavailable> {
        let executable = configuration.testCommandExecutable
        guard URL(fileURLWithPath: executable).lastPathComponent == "swift",
              configuration.testCommandArguments.first == "test"
        else {
            return .failure(Unavailable(reason: nil))
        }
        guard let helper = await helper(of: executable) else {
            return .failure(Unavailable(reason: "\(executable)'s toolchain has no swiftpm-testing-helper"))
        }
        guard let platform = await output(of: "/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"])
        else {
            return .failure(Unavailable(reason: "`xcrun` didn't say where the macOS platform is"))
        }
        let coverage = SwiftCoverage(platform: .darwin)
        guard let products = await coverage.buildDirectory(configuration)?.canonicalPath else {
            return .failure(Unavailable(reason: "`swift test --show-codecov-path` didn't say where the build is"))
        }
        let projectPath = project.path.canonicalPath
        guard products.hasPrefix(projectPath + "/") else {
            return .failure(Unavailable(reason: "the build, in \(products), is outside the project"))
        }
        let testTargets = await coverage.testTargetSources(configuration)
        let bundles = coverage.testBundleFiles(in: products, testTargets: testTargets.map { Set($0.keys) })
        guard !bundles.isEmpty else {
            return .failure(Unavailable(reason: "there is no test bundle in \(products)"))
        }
        return .success(DirectTestRun(
            helper: helper,
            productsFolder: String(products.dropFirst(projectPath.count + 1)),
            bundles: bundles.map(\.name),
            // Swift Build names each bundle after its test target.
            testFiles: (testTargets ?? [:]).mapValues { sources in
                sources.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            },
            platformDeveloperFolder: platform + "/Developer",
            arguments: Array(configuration.testWithoutBuildArguments(with: "").dropFirst())
        ))
    }

    /// The `swiftpm-testing-helper` beside the `swift` that `executable` runs: in `<toolchain>/usr/libexec`, where
    /// its resource folder is `<toolchain>/usr/lib/swift`. Asked of `swift` itself, so `xcrun`'s and swiftly's
    /// proxies, and `TOOLCHAINS`, choose the toolchain as they do for `swift test`.
    private func helper(of executable: String) async -> String? {
        guard let info = await output(of: executable, ["-print-target-info"]),
              let target = try? JSONDecoder().decode(TargetInfo.self, from: Data(info.utf8))
        else {
            return nil
        }
        let helper = URL(fileURLWithPath: target.paths.runtimeResourcePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("libexec/swift/pm/swiftpm-testing-helper")
            .path
        return fileManager.fileExists(atPath: helper) ? helper : nil
    }

    private struct TargetInfo: Decodable {
        let paths: TargetPaths
    }

    private struct TargetPaths: Decodable {
        let runtimeResourcePath: String
    }

    /// What `executable` printed, trimmed, if it succeeded and printed anything.
    private func output(of executable: String, _ arguments: [String]) async -> String? {
        guard let result = await process().runCommand(url: executable, arguments: arguments), result.succeeded
        else {
            return nil
        }
        return result.output.trimmed.nilIfEmpty
    }
}

extension DirectTestRun {
    /// How `configuration`'s test command would run the bundles of `project`, the mutated project, once its baseline
    /// has built them.
    static func probe(
        _ configuration: MuterConfiguration,
        in project: URL
    ) async -> Result<DirectTestRun, Unavailable> {
        #if os(macOS)
        await DirectTestRunProber().probe(configuration, in: project)
        #else
        .failure(Unavailable(reason: nil))
        #endif
    }
}
