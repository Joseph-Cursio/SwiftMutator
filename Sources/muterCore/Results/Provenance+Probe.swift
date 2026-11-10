import Foundation

extension Provenance {
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
        output: (String, [String]) async -> String? = { await current.process().runProcess(url: $0, arguments: $1) },
        sha256: (URL) -> String? = FileDigest.sha256(of:),
        arguments: [String] = current.commandLineArguments
    ) async -> Provenance {
        await Provenance(
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
    static func hostName() -> String {
        let capacity = 256
        // One more than gethostname may fill, so a name it cuts short still ends in a NUL.
        var buffer = [CChar](repeating: 0, count: capacity + 1)
        guard gethostname(&buffer, capacity) == 0 else { return "" }
        return String(lossyUTF8: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
    }
}

private extension Provenance.Toolchain {
    init(
        testCommand: String,
        environment: [String: String],
        output: (String, [String]) async -> String?,
        sha256: (URL) -> String?
    ) async {
        let name = testCommand.lastPathComponent
        if let arguments = Self.versionArguments[name] {
            await self.init(
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
