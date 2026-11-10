@testable import muterCore
import XCTest

private struct GitTimedOut: Error {
    let arguments: [String]
}

extension ProjectTreeTests {
    var projectURL: URL { URL(fileURLWithPath: project) }

    func fingerprint(
        hashingIn hashingRoot: String? = nil,
        excluding excluded: [String] = [],
        pruning prunedFolders: Set<String> = [],
        list: ProjectFileListing = { await GitFileListing.list(in: $0) }
    ) async -> ProjectTree {
        await ProjectTree.fingerprint(
            listingIn: projectURL,
            hashingIn: URL(fileURLWithPath: hashingRoot ?? project),
            excluding: excluded,
            pruning: prunedFolders,
            list: list
        )
    }

    func tree(_ files: [String: String], excluding excluded: [String]) -> ProjectTree {
        ProjectTree(listedBy: .git, files: files, excluded: excluded, treeSHA256: ProjectTree.treeHash(of: files))
    }

    /// Writes each file, relative to `folder`, the project unless given, making its folders.
    func write(_ files: [String: String], in folder: String? = nil) throws {
        for (path, contents) in files {
            let file = URL(fileURLWithPath: "\(folder ?? project)/\(path)")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
    }

    func digest(of path: String) -> String? {
        FileDigest.sha256(of: URL(fileURLWithPath: "\(project)/\(path)"))
    }

    func sha256(_ text: String) -> String {
        FileDigest.sha256(of: Data(text.utf8))
    }

    /// Sets the environment variable `name` to `value` until the test ends.
    func setEnvironment(_ name: String, to value: String) {
        let earlier = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        addTeardownBlock {
            if let earlier {
                setenv(name, earlier, 1)
            } else {
                unsetenv(name)
            }
        }
    }

    /// Runs git in `directory`, as SwiftMutator does: never in a repository the environment names, as a hook's does.
    func git(_ arguments: String..., in directory: String) throws {
        let git = Foundation.Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", directory] + arguments
        git.environment = GitFileListing.environment(ProcessInfo.processInfo.environment)
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        git.terminationHandler = { _ in exited.signal() }
        try git.run()
        guard exited.wait(timeout: .now() + 60) == .success else {
            git.terminate()
            _ = exited.wait(timeout: .now() + 5)
            throw GitTimedOut(arguments: arguments)
        }
        XCTAssertEqual(git.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}
