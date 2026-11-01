import Foundation

/// The files discovery never mutates, by their paths in the project: the defaults, and the configuration's `exclude`.
enum SourceFileExcludes {
    /// Package manifests, versioned (`Package@swift-6.0.swift`) or not, are never mutated: every `swift test`
    /// run in a worker folder has one environment, so SwiftPM reuses the baseline's cached manifest and a
    /// mutant in one would never switch on.
    static let defaults: [FilePath] = [
        "/.swiftpm/",
        "/.build/",
        "/Build/",
        "/Carthage/",
        "/muter_tmp/",
        "/Pods/",
        "/Spec/",
        "/Tests/",
        "Tests.swift",
        "/fastlane/",
        "/Package.swift",
        "/Package@swift-",
    ]

    /// Whether a path in the project is left out by `provided` or the defaults: `./` and the path contains an entry
    /// with no `*`, such as `/Generated/`, or an entry with one, such as `Sources/**/Generated/*.swift`, matches the
    /// path.
    static func matcher(_ provided: [FilePath]) -> (FilePath) -> Bool {
        let excludeList = provided + defaults
        let fragments = excludeList.filter { !$0.contains("*") }
        let globs = excludeList.filter { $0.contains("*") }.map(ExcludeGlob.init)

        return { pathInProject in
            let path = "./" + pathInProject
            return fragments.contains { path.contains($0) } || globs.contains { $0.matches(pathInProject) }
        }
    }
}
