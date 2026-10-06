#if canImport(CryptoKit)
import CryptoKit
#endif
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

extension Provenance {
    /// The environment variables that choose the toolchain or the SDK a test command uses.
    static let environmentKeys = ["SDKROOT", "DEVELOPER_DIR", "TOOLCHAINS"]

    /// This SwiftMutator process, and the toolchain `configuration`'s test command uses.
    ///
    /// The test command is run only to ask its version, and only if it is `swift` or `xcodebuild` itself, whatever
    /// `buildSystem` says: a wrapper script could do anything when run, so its contents, which are configuration,
    /// are hashed instead. It runs in the current folder, as the test command does: during mutation testing that is
    /// the mutated project, where swiftly reads the copied `.swift-version`.
    static func probe(
        _ configuration: MuterConfiguration,
        executable: URL? = Bundle.main.executableURL?.resolvingSymlinksInPath(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        output: (String, [String]) -> String? = { current.process().runProcess(url: $0, arguments: $1) },
        sha256: (URL) -> String? = FileDigest.sha256(of:),
        arguments: [String] = current.commandLineArguments
    ) -> Provenance {
        Provenance(
            swiftMutator: Build(
                version: version,
                executablePath: executable?.path,
                executableSHA256: executable.flatMap(sha256)
            ),
            toolchain: Toolchain(
                testCommand: configuration.testCommandExecutable,
                environment: environment.filter { environmentKeys.contains($0.key) },
                output: output,
                sha256: sha256
            ),
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            host: hostName(),
            arguments: arguments
        )
    }

    /// gethostname(3), never `ProcessInfo.hostName`, which can wait on DNS.
    private static func hostName() -> String {
        let capacity = 256
        // One more than gethostname may fill, so a name it cuts short still ends in a NUL.
        var buffer = [CChar](repeating: 0, count: capacity + 1)
        guard gethostname(&buffer, capacity) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension Provenance.Toolchain {
    /// What makes `swift` and `xcodebuild` say their version.
    static let versionArguments = ["swift": ["--version"], "xcodebuild": ["-version"]]

    /// Whether `testCommand` is asked its version, which then identifies the toolchain. Any other test command is
    /// identified by its SHA-256.
    static func isAskedItsVersion(_ testCommand: String) -> Bool {
        versionArguments[(testCommand as NSString).lastPathComponent] != nil
    }
}

private extension Provenance.Toolchain {
    init(
        testCommand: String,
        environment: [String: String],
        output: (String, [String]) -> String?,
        sha256: (URL) -> String?
    ) {
        let name = (testCommand as NSString).lastPathComponent
        if let arguments = Self.versionArguments[name] {
            self.init(
                testCommandVersion: output(testCommand, arguments)?.trimmed.nilIfEmpty,
                testExecutableSHA256: nil,
                environment: environment
            )
        } else {
            self.init(
                testCommandVersion: nil,
                testExecutableSHA256: testCommand.isEmpty ? nil : sha256(URL(fileURLWithPath: testCommand)),
                environment: environment
            )
        }
    }
}

/// Fingerprints of files' contents.
enum FileDigest {
    /// How much of a file is hashed at a time, so a large executable is never all in memory.
    private static let chunkSize = 1 << 20

    /// The hex SHA-256 of a file's bytes, or nil if it can't be read, or there is no CryptoKit.
    static func sha256(of url: URL) -> String? {
        #if canImport(CryptoKit)
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
        #else
        return nil
        #endif
    }

    /// The hex SHA-256 of `data`, or nil if there is no CryptoKit.
    static func sha256(of data: Data) -> String? {
        #if canImport(CryptoKit)
        return hex(SHA256.hash(data: data))
        #else
        return nil
        #endif
    }

    #if canImport(CryptoKit)
    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
    #endif
}
