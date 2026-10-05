@testable import muterCore
import SwiftParser
import XCTest

/// Compiles a rewritten file with the real compiler and runs it. The snapshots record swift-format's
/// rewrite of the generated code, which hides errors, and can't show which mutant it switches on. A
/// `swift test` run names its mutant in a file; any other test command names it in a variable of the
/// mutant's own, and the generated code must switch it on either way.
final class GeneratedEnvironmentCacheTests: MuterTestCase {
    private let xcrun = "/usr/bin/xcrun"
    /// What the compiled program exits with when the generated code's fatal error traps.
    private let trapExitStatus: Int32 = 70
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: xcrun),
            "compiling the generated code needs \(xcrun)"
        )
        directory = try URL(fileURLWithPath: makeTemporaryDirectory())
    }

    func test_theGeneratedCodeSwitchesOnTheMutantItIsTold() throws {
        let (program, identifier) = try compileMutatedCheck()
        let activeMutantFile = directory.appendingPathComponent("active-mutant")
        let file = [activeMutantFileKey: activeMutantFile.path]

        XCTAssertEqual(try run(program).output, "original\n", "no mutant named")
        try write("", to: activeMutantFile)
        XCTAssertEqual(try run(program, adding: file).output, "original\n", "an empty file")
        try write(identifier, to: activeMutantFile)
        XCTAssertEqual(try run(program, adding: file).output, "mutant\n", "the mutant's ID in the file")
        try write(identifier + "\n", to: activeMutantFile)
        XCTAssertEqual(try run(program, adding: file).output, "mutant\n", "the ID and a newline, as `echo` writes")
        try write("Elsewhere_RelationalOperatorReplacement_1_1_0", to: activeMutantFile)
        XCTAssertEqual(try run(program, adding: file).output, "original\n", "another mutant's ID")
        XCTAssertEqual(try run(program, adding: [identifier: "YES"]).output, "mutant\n", "the mutant's own variable")

        // The program stops with a fatal error here, as a test run would. It exits from its trap handler, so
        // macOS keeps no crash report of it.
        let missing = [activeMutantFileKey: directory.appendingPathComponent("missing").path]
        let unreadable = try run(program, adding: missing)
        XCTAssertEqual(unreadable.reason, .exit, "the trap handler must end the program, not the trap")
        XCTAssertEqual(unreadable.status, trapExitStatus, "a file that can't be read must stop the tests")
        XCTAssertEqual(unreadable.output, "", "a file that can't be read must not run the original code")
        XCTAssertTrue(unreadable.errors.contains("could not read the active mutant"), unreadable.errors)
    }

    // MARK: - Helpers

    private struct Run {
        let reason: Foundation.Process.TerminationReason
        let status: Int32
        let output: String
        let errors: String
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Rewrites a file holding one mutant, as `swift test` builds it, and compiles it into a program that
    /// prints which code ran. It's compiled in the strictest mode the generated code must pass: Swift 6, with
    /// only `ProcessInfo` imported from Foundation and members of other imports hidden.
    private func compileMutatedCheck() throws -> (program: URL, identifier: String) {
        let source = SourceCodeInfo(
            path: "/path/to/Check.swift",
            code: Parser.parse(source: """
            import class Foundation.ProcessInfo

            func check(_ value: Int) -> Bool {
                return value > 1
            }

            """)
        )
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)
        XCTAssertEqual(mapping.mutationSchemata.count, 1, "\(mapping.mutationSchemata)")
        let identifier = try XCTUnwrap(mapping.mutationSchemata.first).id

        let mutated = directory.appendingPathComponent("Check.swift")
        let main = directory.appendingPathComponent("main.swift")
        let program = directory.appendingPathComponent("check")
        try write(MuterRewriter(mapping).rewrite(source.code).description, to: mutated)
        // A fatal error traps (SIGTRAP on arm64, SIGILL on x86_64), and macOS keeps a crash report, outside any
        // temporary folder, of every program a trap kills. So this program exits from handlers of its own
        // instead; the generated code's fatal error is untouched.
        try write(
            """
            import Darwin

            signal(SIGTRAP) { _ in _exit(\(trapExitStatus)) }
            signal(SIGILL) { _ in _exit(\(trapExitStatus)) }
            print(check(5) ? "original" : "mutant")

            """,
            to: main
        )

        // The compiler runs with this suite's environment, without the dynamic loader's variables the test
        // runner may set and without the active-mutant file an outer mutation-testing run may name.
        let compiled = try execute(
            URL(fileURLWithPath: xcrun),
            arguments: [
                "swiftc",
                "-swift-version", "6",
                "-enable-upcoming-feature", "MemberImportVisibility",
                "-warnings-as-errors",
                "-o", program.path,
                mutated.path,
                main.path,
            ],
            environment: MuterProcessFactory.environment(inheriting: ProcessInfo.processInfo.environment)
                .filter { !$0.key.hasPrefix("DYLD_") },
            timeLimit: 300
        )
        guard compiled.status == 0 else {
            throw Failure(description: "the generated code didn't compile:\n\(compiled.errors)")
        }
        return (program, identifier)
    }

    /// Runs the compiled program with nothing in its environment but `PATH` and `variables`.
    private func run(_ program: URL, adding variables: [String: String] = [:]) throws -> Run {
        try execute(
            program,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"].merging(variables) { _, added in added },
            timeLimit: 60
        )
    }

    /// Runs a process to its end, or kills it and throws once `timeLimit` seconds pass. Its output goes to
    /// files rather than pipes, so a process that writes a lot never blocks on a full pipe.
    private func execute(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        timeLimit: TimeInterval
    ) throws -> Run {
        let name = UUID().uuidString
        let output = directory.appendingPathComponent("\(name).out")
        let errors = directory.appendingPathComponent("\(name).err")
        try write("", to: output)
        try write("", to: errors)
        let outputHandle = try FileHandle(forWritingTo: output)
        let errorsHandle = try FileHandle(forWritingTo: errors)
        defer {
            try? outputHandle.close()
            try? errorsHandle.close()
        }

        let process = Foundation.Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = errorsHandle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        guard exited.wait(timeout: .now() + timeLimit) == .success else {
            // Foundation.Process starts each process in a group of its own, so this reaches the compiler's
            // own children too. kill(-1) would signal everything.
            if process.processIdentifier > 1 {
                kill(-process.processIdentifier, SIGKILL)
            }
            _ = exited.wait(timeout: .now() + 10)
            let command = ([executable.path] + arguments).joined(separator: " ")
            throw Failure(description: "\(command) was still running after \(timeLimit) seconds, and was killed")
        }

        return Run(
            reason: process.terminationReason,
            status: process.terminationStatus,
            output: try String(contentsOf: output, encoding: .utf8),
            errors: try String(contentsOf: errors, encoding: .utf8)
        )
    }

    private func write(_ text: String, to file: URL) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}
