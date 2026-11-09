import Foundation
import SwiftIfConfig

/// What a project's build compiles with, for each file where the build system says which targets hold it.
struct ProjectBuildConditions: Equatable, Sendable {
    /// For any file, by every target's conditions: an `#if` is decided only where they all agree.
    let everyTarget: BuildConditions
    /// The custom conditions of the targets that hold a file, by its path relative to the project, for a build system
    /// that says. xcodebuild doesn't: which of its targets compile a file is in the project file, or in the folders
    /// Xcode syncs, and SwiftMutator reads neither.
    var customConditionsOfFile: [FilePath: [Set<String>]] = [:]

    /// What the build compiles the file at `path`, relative to the project, with.
    func conditions(ofFile path: FilePath) -> BuildConditions {
        var conditions = everyTarget
        if let targets = customConditionsOfFile[path], !targets.isEmpty {
            conditions.customConditions = targets
        }
        return conditions
    }
}

/// Why SwiftMutator couldn't tell what a project's build compiles with.
struct BuildConditionsUnavailable: Error, Equatable {
    /// To follow "SwiftMutator couldn't tell which `#if` branches the build compiles: ".
    let reason: String
}

extension BuildConditions.SDKModules {
    /// The modules of the SDK at `sdk`, and the ones only the other SDKs of its Xcode have. Nil if `sdk` lists none,
    /// so that nothing would read as absent because the SDK couldn't be read.
    init?(sdk: FilePath, fileManager: FileSystemManager) {
        let present = Self.modules(ofSDK: sdk, fileManager: fileManager)
        guard !present.isEmpty else { return nil }

        self.present = present
        absent = Self.otherSDKs(than: sdk, fileManager: fileManager)
            .reduce(into: Set<String>()) { $0.formUnion(Self.modules(ofSDK: $1, fileManager: fileManager)) }
            .subtracting(present)
    }

    /// The Apple frameworks a Swift build elsewhere can't import, for a platform with no SDK folders to read. The rest
    /// of what `canImport` asks there is undecided: Foundation and Glibc come with the toolchain or the system.
    static let withoutAnSDK = Self(
        present: [],
        absent: [
            "AppKit", "Cocoa", "Combine", "CoreGraphics", "Darwin", "ObjectiveC", "SwiftUI", "TVUIKit", "UIKit",
            "WatchKit",
        ]
    )

    private static func modules(ofSDK sdk: FilePath, fileManager: FileSystemManager) -> Set<String> {
        var modules: Set<String> = []
        let frameworks = sdk + "/System/Library/Frameworks"
        for entry in (try? fileManager.contentsOfDirectory(atPath: frameworks)) ?? []
        where entry.hasSuffix(".framework") && fileManager.fileExists(atPath: "\(frameworks)/\(entry)/Modules") {
            modules.insert(String(entry.dropLast(".framework".count)))
        }
        for entry in (try? fileManager.contentsOfDirectory(atPath: sdk + "/usr/lib/swift")) ?? []
        where entry.hasSuffix(".swiftmodule") {
            modules.insert(String(entry.dropLast(".swiftmodule".count)))
        }
        return modules
    }

    /// The SDKs in `<Developer>/Platforms/<platform>.platform/Developer/SDKs`, where `sdk` is one, without `sdk`. A
    /// macOS SDK from the Command Line Tools has none beside it.
    private static func otherSDKs(than sdk: FilePath, fileManager: FileSystemManager) -> [FilePath] {
        let platforms = URL(fileURLWithPath: sdk)
            .deletingLastPathComponent() // SDKs
            .deletingLastPathComponent() // Developer
            .deletingLastPathComponent() // <platform>.platform
            .deletingLastPathComponent().path
        guard platforms.hasSuffix("/Platforms") else { return [] }

        return ((try? fileManager.contentsOfDirectory(atPath: platforms)) ?? []).flatMap { platform -> [FilePath] in
            let sdks = "\(platforms)/\(platform)/Developer/SDKs"
            return ((try? fileManager.contentsOfDirectory(atPath: sdks)) ?? [])
                .filter { $0.hasSuffix(".sdk") }
                .map { "\(sdks)/\($0)" }
                .filter { $0 != sdk }
        }
    }
}

/// The compiler's version in what `swift --version` or `swiftc --version` prints, as `compiler(…)` compares it: the
/// `6.2.1` of `Swift version 6.2.1 (swift-6.2.1-RELEASE)` or `Apple Swift version 6.2.1 (swiftlang-…)`. Nil for any
/// other, as a development snapshot's `6.3-dev`, which may not compare as what it says.
func compilerVersion(inVersionOutput output: String) -> VersionTuple? {
    guard let start = output.range(of: "Swift version ")?.upperBound else { return nil }
    let version = output[start...].prefix { !$0.isWhitespace }
    guard version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
    return VersionTuple(parsing: String(version))
}

/// The conditions among compiler flags: `-DNAME`, and `-D NAME` as two flags. A flag that `-Xcc`, `-Xllvm`, `-Xlinker`
/// or `-Xclang-linker` passes on is another tool's, so `-Xcc -DNAME` defines a C macro, not a condition. The frontend
/// takes `-D` as the driver does, so `-Xfrontend -DNAME` is one.
func customConditions(inSwiftFlags flags: [String]) -> Set<String> {
    var conditions: Set<String> = []
    var index = 0
    while index < flags.count {
        let flag = flags[index]
        if passedToAnotherTool.contains(flag) {
            index += 2
            continue
        }
        if flag == "-D" {
            if index + 1 < flags.count {
                conditions.insert(flags[index + 1])
            }
            index += 2
            continue
        }
        if flag.hasPrefix("-D") {
            conditions.insert(String(flag.dropFirst(2)))
        }
        index += 1
    }
    return conditions
}

/// The options that pass the flag after them to a tool other than the Swift compiler.
private let passedToAnotherTool: Set = ["-Xcc", "-Xllvm", "-Xlinker", "-Xclang-linker"]
