import Foundation

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
    static let withoutAnSDK = Self( // swiftlint:disable:this unused_declaration - used under #if os(Linux) only
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
