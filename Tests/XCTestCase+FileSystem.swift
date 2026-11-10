import Foundation
@testable import muterCore
import XCTest

extension XCTestCase {
    /// A path in the temporary directory that nothing has used, for a folder a test makes in `setUp` and removes in
    /// `tearDown`.
    static func unusedTemporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    }

    /// A new, empty directory, removed when the test finishes. A test that writes files uses one
    /// rather than a folder next to its source: every process running the same compiled tests finds
    /// that folder at the same `#filePath`, so when mutation testing runs the suite in several
    /// processes at once, the copies overwrite and delete each other's files and fail.
    func makeTemporaryDirectory() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        return directory
    }

    /// Starts `arguments[0]` with `arguments`, without closing any descriptor the test has open, in a process group of
    /// its own, as each test process SwiftMutator starts is.
    ///
    /// Not in the test process's group: on CI runners every process is in launchd's session, so a process of that group
    /// that launchd adopted, such as the `sleep` of a killed `sh`, counted as holding the group to its session. When it
    /// exited, the group was left orphaned, and since it held stopped processes, the system sent the whole group
    /// SIGHUP, which ended the test run.
    func spawn(_ arguments: String...) throws -> pid_t {
        var child: pid_t = 0
        let argumentVector = arguments.map { strdup($0) } + [nil]
        defer { argumentVector.forEach { free($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        #if os(macOS)
        var attributes: posix_spawnattr_t?
        #else
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let status = posix_spawn(&child, arguments[0], nil, &attributes, argumentVector, &environment)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EPERM) }
        return child
    }

    /// A new, empty directory that can also be reached through a symbolic link, the way `/private/tmp`
    /// is also `/tmp` on macOS. Both are removed when the test finishes.
    func makeDirectoryWithSymbolicLink() throws -> (directory: String, link: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let directory = "\(root)/directory"
        let link = "\(root)/link"

        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }

        return (directory, link)
    }

    /// The words `/bin/sh` reads in `text`, as it would reading a command whose arguments are `text`. An empty word is
    /// kept: each word printed ends in a NUL.
    func wordsAShellReads(in text: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"printf '%s\0' "# + text]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(lossyUTF8: data)
            .split(separator: "\0", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
    }
}
