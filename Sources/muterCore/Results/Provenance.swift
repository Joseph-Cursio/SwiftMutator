import Foundation

/// Where a session's results came from: this SwiftMutator build, and the toolchain its test command used. A results
/// file's header records it, so results are only ever reused by the build and toolchain that produced them.
struct Provenance: Codable, Equatable {
    struct Build: Codable, Equatable {
        let version: String
        let executablePath: String?
        /// SHA-256 of the executable, which stands in for the commit it was built from: that isn't built in.
        let executableSHA256: String?
    }

    struct Toolchain: Codable, Equatable {
        /// What the test command says its version is: `swift --version` or `xcodebuild -version`.
        let testCommandVersion: String?
        /// SHA-256 of a test command that wraps `swift` or `xcodebuild`, whose contents are configuration.
        let testExecutableSHA256: String?
        /// SDKROOT, DEVELOPER_DIR and TOOLCHAINS as set; one that's unset is absent, so unset differs from empty.
        let environment: [String: String]
    }

    let swiftMutator: Build
    let toolchain: Toolchain
    let processIdentifier: Int32
    let host: String
    /// SwiftMutator's command-line arguments, after the executable.
    let arguments: [String]
}
