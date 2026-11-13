#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Fingerprints of files' contents.
enum FileDigest {
    /// How much of a file is hashed at a time, so a large executable is never all in memory.
    private static let chunkSize = 1 << 20

    /// The hex SHA-256 of a file's bytes, or nil if it can't be read.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    /// The hex SHA-256 of `data`.
    static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

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

        /// What makes `swift` and `xcodebuild` say their version.
        static let versionArguments = ["swift": ["--version"], "xcodebuild": ["-version"]]

        /// Whether `testCommand` is asked its version, which then identifies the toolchain. Any other test command is
        /// identified by its SHA-256.
        static func isAskedItsVersion(_ testCommand: String) -> Bool {
            versionArguments[testCommand.lastPathComponent] != nil
        }
    }

    let swiftMutator: Build
    let toolchain: Toolchain
    let processIdentifier: Int32
    let host: String
    /// SwiftMutator's command-line arguments, after the executable.
    let arguments: [String]

    /// The environment variables that choose the toolchain or the SDK a test command uses.
    static let environmentKeys = ["SDKROOT", "DEVELOPER_DIR", "TOOLCHAINS"]
}
