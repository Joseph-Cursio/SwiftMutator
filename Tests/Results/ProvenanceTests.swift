#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import muterCore
import XCTest

final class ProvenanceTests: XCTestCase {
    private let swiftMutator = URL(fileURLWithPath: "/usr/local/Cellar/swift-mutator/0.1.0/bin/swift-mutator")
    private let swiftVersion = """
    Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
    Target: arm64-apple-macosx27.0.0
    """
    private let xcodebuildVersion = """
    Xcode 27.0
    Build version 27A266a
    """

    func test_asksSwiftAndXcodebuildForTheirVersion() {
        var asked: [[String]] = []
        var hashed: [URL] = []
        let output: (String, [String]) -> String? = { executable, arguments in
            asked.append([executable] + arguments)
            // As each prints it, with its trailing line break.
            return (executable.hasSuffix("/xcodebuild") ? self.xcodebuildVersion : self.swiftVersion) + "\n"
        }
        let sha256: (URL) -> String? = { url in
            hashed.append(url)
            return "9f2c"
        }

        let swift = Provenance.probe(
            MuterConfiguration(executable: "/Users/me/.swiftly/bin/swift", arguments: ["test"]),
            executable: swiftMutator,
            environment: [:],
            output: output,
            sha256: sha256
        )
        let xcodebuild = Provenance.probe(
            MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test", "-scheme", "Sum"]),
            executable: swiftMutator,
            environment: [:],
            output: output,
            sha256: sha256
        )

        XCTAssertEqual(asked, [
            ["/Users/me/.swiftly/bin/swift", "--version"],
            ["/usr/bin/xcodebuild", "-version"],
        ])
        XCTAssertEqual(swift.toolchain.testCommandVersion, swiftVersion)
        XCTAssertEqual(xcodebuild.toolchain.testCommandVersion, xcodebuildVersion)
        XCTAssertNil(swift.toolchain.testExecutableSHA256)
        XCTAssertNil(xcodebuild.toolchain.testExecutableSHA256)
        XCTAssertEqual(hashed, [swiftMutator, swiftMutator], "only SwiftMutator's own executable is hashed")
    }

    func test_aVersionCommandThatSaysNothing_recordsNoVersion() {
        for said in [nil, "", " \n"] {
            let provenance = Provenance.probe(
                MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"]),
                executable: nil,
                environment: [:],
                output: { _, _ in said }
            )

            XCTAssertNil(provenance.toolchain.testCommandVersion, "\(String(describing: said))")
        }
    }

    func test_aWrapperExecutableIsHashed_notRun() throws {
        let directory = try makeTemporaryDirectory()
        let wrapper = "\(directory)/test-with-sdk.sh"
        try Data("abc".utf8).write(to: URL(fileURLWithPath: wrapper))
        var ran: [String] = []

        // Even when `buildSystem` says it runs `swift test`: a wrapper could do anything when run.
        let provenance = Provenance.probe(
            MuterConfiguration(executable: wrapper, arguments: ["test"], buildSystem: .swift),
            executable: nil,
            environment: [:],
            output: { executable, _ in
                ran.append(executable)
                return self.swiftVersion
            }
        )

        XCTAssertEqual(ran, [])
        XCTAssertNil(provenance.toolchain.testCommandVersion)
        XCTAssertEqual(
            provenance.toolchain.testExecutableSHA256,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func test_keepsOnlySDKROOTDeveloperDirAndToolchains_andLeavesOutUnsetOnes() throws {
        let provenance = Provenance.probe(
            MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"]),
            executable: nil,
            environment: [
                "SDKROOT": "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk",
                "TOOLCHAINS": "",
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/me",
                "SDKROOT_BACKUP": "/elsewhere",
            ],
            output: { _, _ in "Apple Swift version 6.4" }
        )

        XCTAssertEqual(provenance.toolchain.environment, [
            "SDKROOT": "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk",
            "TOOLCHAINS": "",
        ])
        // Unset differs from empty: DEVELOPER_DIR is absent, while TOOLCHAINS is there and empty.
        XCTAssertEqual(
            String(decoding: try ResultsCoding.encoder.encode(provenance.toolchain), as: UTF8.self),
            #"{"environment":{"SDKROOT":"/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk","TOOLCHAINS":""},"#
                + #""testCommandVersion":"Apple Swift version 6.4"}"#
        )
    }

    func test_recordsTheExecutablesHash() throws {
        let directory = try makeTemporaryDirectory()
        let executable = URL(fileURLWithPath: "\(directory)/swift-mutator")
        try Data("abc".utf8).write(to: executable)

        let provenance = Provenance.probe(
            MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"]),
            executable: executable,
            environment: [:],
            output: { _, _ in nil }
        )

        XCTAssertEqual(provenance.swiftMutator, Provenance.Build(
            version: muterCore.version,
            executablePath: executable.path,
            executableSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        ))
    }

    func test_aMissingExecutable_hasNoHash() throws {
        let directory = try makeTemporaryDirectory()
        let missing = URL(fileURLWithPath: "\(directory)/swift-mutator")
        let wrapper = MuterConfiguration(executable: "\(directory)/test-with-sdk.sh", arguments: ["test"])

        let deleted = Provenance.probe(wrapper, executable: missing, environment: [:], output: { _, _ in nil })
        let unknown = Provenance.probe(wrapper, executable: nil, environment: [:], output: { _, _ in nil })

        XCTAssertEqual(
            deleted.swiftMutator,
            Provenance.Build(version: muterCore.version, executablePath: missing.path, executableSHA256: nil)
        )
        XCTAssertEqual(
            unknown.swiftMutator,
            Provenance.Build(version: muterCore.version, executablePath: nil, executableSHA256: nil)
        )
        XCTAssertNil(deleted.toolchain.testExecutableSHA256)
        XCTAssertNil(FileDigest.sha256(of: URL(fileURLWithPath: directory)), "a folder has no hash")
    }

    func test_withoutATestCommand_asksNothing_andHashesNothing() {
        var asked: [String] = []

        let provenance = Provenance.probe(
            MuterConfiguration(),
            executable: nil,
            environment: [:],
            output: { executable, _ in
                asked.append(executable)
                return nil
            },
            sha256: { url in
                asked.append(url.path)
                return nil
            }
        )

        XCTAssertEqual(asked, [])
        XCTAssertNil(provenance.toolchain.testCommandVersion)
        XCTAssertNil(provenance.toolchain.testExecutableSHA256)
    }

    // The arguments are the ones the command that continues a stopped run repeats: by default, this process's.
    func test_recordsThisProcess_itsHost_andItsArguments() {
        let provenance = Provenance.probe(
            MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"]),
            executable: nil,
            environment: [:],
            output: { _, _ in nil },
            arguments: ["run", "--skip-coverage"]
        )

        XCTAssertEqual(provenance.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(provenance.arguments, ["run", "--skip-coverage"])
        XCTAssertEqual(World().commandLineArguments, Array(CommandLine.arguments.dropFirst()))
        XCTAssertFalse(provenance.host.isEmpty)
        XCTAssertFalse(provenance.host.contains("\0"), provenance.host)
    }

    #if canImport(CryptoKit)
    func test_sha256_ofAFileLargerThanOneRead_isTheWholeFilesHash() throws {
        let directory = try makeTemporaryDirectory()
        let file = URL(fileURLWithPath: "\(directory)/large")
        let contents = Data((0 ..< 2_621_447).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try contents.write(to: file)

        XCTAssertEqual(
            FileDigest.sha256(of: file),
            SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        )
    }
    #endif
}
