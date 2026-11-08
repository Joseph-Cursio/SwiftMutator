import Foundation

/// The files discovery never mutates, by their paths in the project: the defaults, and the configuration's `exclude`.
enum SourceFileExcludes {
    /// What no entry can keep, with the project's own manifests (`isAlwaysExcluded`). Package manifests, versioned
    /// (`Package@swift-6.0.swift`) or not, are never mutated: every `swift test` run in a worker folder has one
    /// environment, so SwiftPM reuses the baseline's cached manifest and a mutant in one would never switch on. Build
    /// folders and SwiftMutator's own aren't the project's code.
    static let alwaysExcluded: [FilePath] = [
        "/.swiftpm/",
        "/.build/",
        "/muter_tmp/",
    ]

    /// Left out unless an entry that starts with `!` keeps them: a local package's manifest, which is most likely
    /// what a deeper file of that name is, build products, dependencies, tests and the code that serves them, as test
    /// doubles and helpers do, and SwiftPM's snippets.
    static let excludedByDefault: [FilePath] = [
        "/Package.swift",
        "/Package@swift-",
        "/Build/",
        "/DerivedData/",
        "/Carthage/",
        "/Pods/",
        "/fastlane/",
        "/Spec/",
        "/Tests/",
        "Tests.swift",
        "Spec.swift",
        "/Mocks/",
        "/Stubs/",
        "/Fakes/",
        "/TestHelpers/",
        "/TestSupport/",
        "Mock.swift",
        "/Snippets/",
    ]

    /// Whether no entry can keep a path in the project: one `alwaysExcluded` matches, or the project's own manifest.
    static func isAlwaysExcluded(_ pathInProject: FilePath) -> Bool {
        let isRootManifest = pathInProject == "Package.swift"
            || !pathInProject.contains("/") && pathInProject.hasPrefix("Package@swift-")
        let path = "./" + pathInProject
        return isRootManifest || alwaysExcluded.contains { path.contains($0) }
    }

    /// Whether a path in the project is left out by `provided` or the defaults. An entry matches a path if it has no
    /// `*` and `./` and the path contains it, such as `/Generated/`, or if it has one and matches the path, such as
    /// `Sources/**/Generated/*.swift`. An entry that starts with `!`, such as `!/Stubs/`, keeps what the rest of it
    /// matches, whatever else matches it, but for `alwaysExcluded`.
    static func matcher(_ provided: [FilePath]) -> (FilePath) -> Bool {
        let kept = provided.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
        let excluded = matcher(of: provided.filter { !$0.hasPrefix("!") } + excludedByDefault)
        let isKept = matcher(of: kept)

        return { pathInProject in
            isAlwaysExcluded(pathInProject) || excluded(pathInProject) && !isKept(pathInProject)
        }
    }

    /// Whether any of `entries` matches a path in the project.
    private static func matcher(of entries: [FilePath]) -> (FilePath) -> Bool {
        let fragments = entries.filter { !$0.contains("*") && !$0.isEmpty }
        let globs = entries.filter { $0.contains("*") }.map(ExcludeGlob.init)

        return { pathInProject in
            let path = "./" + pathInProject
            return fragments.contains { path.contains($0) } || globs.contains { $0.matches(pathInProject) }
        }
    }
}
