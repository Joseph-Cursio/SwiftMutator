import Foundation

/// A check xcodebuild makes before it runs a package's plugin or macro: until someone trusts each one in Xcode, a build
/// that runs it fails, and a run with no one at the Mac, as on CI, has no one to trust it. Each has a flag that skips
/// it, which `init` writes into an xcodebuild configuration when the project uses what the check is for. `swift test`
/// makes neither check, so a SwiftPM configuration never needs them.
enum XcodebuildTrustCheck: CaseIterable, Equatable {
    case packagePlugins
    case macros

    /// The xcodebuild argument that skips the check.
    var skippingArgument: String {
        switch self {
        case .packagePlugins: "-skipPackagePluginValidation"
        case .macros: "-skipMacroValidation"
        }
    }

    /// What the check is for, as a sentence names it.
    var subject: String {
        switch self {
        case .packagePlugins: "package plugins"
        case .macros: "macros"
        }
    }

    /// The checks whose skipping argument is among `arguments`, in the order of `allCases`.
    static func skipped(by arguments: [String]) -> [XcodebuildTrustCheck] {
        allCases.filter { arguments.contains($0.skippingArgument) }
    }

    /// The checks a build of the project in `directoryContents` would make, judged from the files `init` lists.
    ///
    /// Plugins: a `project.pbxproj` names a plugin a target uses as a package product called `plugin:<name>`, and a
    /// `Package.swift` declares or uses one with `.plugin(`. Macros: a macro package depends on swift-syntax, or on a
    /// prebuilt copy whose name starts the same, so a `Package.resolved` that names it means a macro is likely, and a
    /// `Package.swift` declares one with `.macro(`. Either guess can be wrong both ways. A wrong yes only adds an
    /// argument that skips a check nothing needed, and a wrong no leaves the configuration as `init` used to write it,
    /// which a build at the Mac still runs once its plugins and macros are trusted.
    ///
    /// Files in `.build` or `SourcePackages` are left out: they are the dependencies' own checkouts, whose manifests
    /// and resolved files describe the dependencies' builds, not this project's. A dependency's macro still shows, in
    /// the project's own `Package.resolved`, once its packages are resolved. Only a URL's relative path is looked at,
    /// so a project that is itself in such a folder, as a CI runner's may be, still has its own files read.
    static func needed(by directoryContents: [URL]) -> [XcodebuildTrustCheck] {
        let projectFiles = directoryContents.exclude(isInADependencyCheckout)
        let projects = contents(of: projectFiles) { $0 == "project.pbxproj" }
        let manifests = contents(of: projectFiles) { $0 == "Package.swift" || $0.matches("Package@*.swift") }
        let resolvedPackages = contents(of: projectFiles) { $0 == "Package.resolved" }

        return allCases.filter { check in
            switch check {
            case .packagePlugins:
                projects.contains { $0.contains(#"productName = "plugin:"#) }
                    || manifests.contains { $0.contains(".plugin(") }
            case .macros:
                resolvedPackages.contains { $0.contains("swift-syntax") }
                    || manifests.contains { $0.contains(".macro(") }
            }
        }
    }

    private static func isInADependencyCheckout(_ url: URL) -> Bool {
        url.relativePath.split(separator: "/").contains { $0 == ".build" || $0 == "SourcePackages" }
    }

    /// The text of each file in `urls` whose name `isWanted` takes, leaving out those that can't be read.
    private static func contents(of urls: [URL], named isWanted: (String) -> Bool) -> [String] {
        urls
            .include { isWanted($0.lastPathComponent) }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
