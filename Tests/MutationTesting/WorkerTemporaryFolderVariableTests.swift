import Foundation
@testable import muterCore
import XCTest

#if os(macOS)
/// What a test bundle sees, as a program compiled with the real compiler. Not `getconf`: macOS ignores the variable for
/// its own programs, so `/bin/sh` and `swift` keep the `TMPDIR` they are given.
final class WorkerTemporaryFolderVariableTests: GeneratedCodeTestCase {
    // Foundation's temporary directory comes from `confstr`, and doesn't follow TMPDIR. The variable that moves it is
    // undocumented: if this fails, workers' tests that use Foundation's temporary directory share it again, so the
    // README's "Tests that share state across workers" no longer holds.
    func test_theVariableMovesFoundationsTemporaryDirectory() throws {
        let source = directory.appendingPathComponent("main.swift")
        let program = directory.appendingPathComponent("program")
        try write(
            """
            import Foundation
            print(NSTemporaryDirectory())
            print(FileManager.default.temporaryDirectory.path)
            """,
            to: source
        )
        let compiled = try execute(
            URL(fileURLWithPath: xcrun),
            arguments: ["swiftc", source.path, "-o", program.path],
            environment: compilerEnvironment,
            timeLimit: 120
        )
        XCTAssertEqual(compiled.status, 0, compiled.errors)
        let folder = WorkerTemporaryFolder(
            forWorkerIn: URL(fileURLWithPath: "/runs/variable-check"),
            under: FileManager.default.temporaryDirectory
        )

        let moved = try run(program, adding: folder.environment)

        // Compared from the folder's name: `run` gives the program nothing else, and this process's own may be moved.
        let lines = moved.output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, moved.output)
        for line in lines {
            XCTAssertTrue(line.hasSuffix("/" + folder.name) || line.hasSuffix("/" + folder.name + "/"), line)
        }
    }
}
#endif
