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

    /// Under `-default-isolation MainActor` the cache's enum is isolated to the main actor, and a mutant in
    /// nonisolated code must still be able to read it.
    func test_theGeneratedCodeBuildsInAModuleIsolatedToTheMainActorByDefault() throws {
        try skipUnlessTheCompilerTakesDefaultIsolation()
        let (program, identifier) = try compileMutatedCheck(
            declaring: "nonisolated func check(_ value: Int) -> Bool",
            arguments: ["-default-isolation", "MainActor"]
        )
        let activeMutantFile = directory.appendingPathComponent("active-mutant")
        try write(identifier, to: activeMutantFile)

        XCTAssertEqual(try run(program).output, "original\n", "no mutant named")
        XCTAssertEqual(
            try run(program, adding: [activeMutantFileKey: activeMutantFile.path]).output,
            "mutant\n",
            "the mutant's ID in the file"
        )
        XCTAssertEqual(try run(program, adding: [identifier: "YES"]).output, "mutant\n", "the mutant's own variable")
    }

    /// Code that other modules may copy, an `@inlinable`, `@_alwaysEmitIntoClient` or `@_transparent` body or a public
    /// function's default argument, can reference only public and `@usableFromInline` declarations, and so can a
    /// mutant in it. Each is in a file of its own, and each file's cache is internal, so this also checks that the
    /// caches of a module's files don't clash.
    func test_theGeneratedCodeBuildsInCodeOtherModulesMayCopy() throws {
        let (program, identifier) = try compileMutatedCheck(
            declaring: "@inlinable public func check(_ value: Int) -> Bool",
            alongside: [
                "Emitted.swift": """
                @_alwaysEmitIntoClient public func emitted(_ value: Int) -> Bool {
                    return value > 1
                }
                """,
                "Transparent.swift": """
                @_transparent public func transparent(_ value: Int) -> Bool {
                    return value > 1
                }
                """,
                "Defaulted.swift": """
                public func defaulted(_ value: Int, _ isLarge: (Int) -> Bool = { $0 > 1 }) -> Bool {
                    return isLarge(value)
                }
                """,
            ]
        )

        XCTAssertEqual(try run(program).output, "original\n", "no mutant named")
        XCTAssertEqual(try run(program, adding: [identifier: "YES"]).output, "mutant\n", "the mutant's own variable")
    }

    /// Inside a multi-line string every line after a line feed, an interpolation's code too, must start with the
    /// indentation of the closing `"""`. A switch in a closure there whose last line ends in a `//` comment or
    /// `#endif` starts each `}` on a line of its own, and that line's indentation must be enough (#90): for a chain
    /// of branches, for a string inside another's interpolation, which needs more, and with each file's line
    /// endings. The program's own mutant isn't the point: `compileMutatedCheck` throws if the generated code doesn't
    /// compile.
    func test_theGeneratedCodeBuildsInAClosureInsideAMultiLineString() throws {
        let summary = """
        func summary(_ items: [Int]) -> String {
            \"""
            Count: \\(items.filter { let limit = 1
                return $0 > limit // the big ones
            }.count)
            Small: \\(items.filter { $0 < 9 // the small ones
            }.count)
            \"""
        }
        """
        _ = try compileMutatedCheck(alongside: [
            "Summary.swift": summary,
            "SummaryCRLF.swift": summary
                .replacingOccurrences(of: "summary", with: "summaryCRLF")
                .replacingOccurrences(of: "\n", with: "\r\n"),
            "SummaryCR.swift": summary
                .replacingOccurrences(of: "summary", with: "summaryCR")
                .replacingOccurrences(of: "\n", with: "\r"),
            // The line after a lone carriage return isn't checked, so the code there can start at column 0.
            "Noted.swift": """
            func noted(_ items: [Int]) -> String {
                \"""
                Noted: \\(items.filter { let limit = 1 /* a note\r*/ return $0 > limit // the big ones
                }.count)
                \"""
            }
            """,
            "Shapes.swift": """
            func shapes(_ items: [Int]) -> String {
                \"""
                Middle: \\(items.filter { $0 > 1 && $0 < 9 // three mutants, so a chain of branches
                }.count)
                Nested: \\(items.map { item in \"""
                        \\(item > 1 ? "big" : "small"): \\(items.filter { $0 > item // in the inner string
                        }.count)
                        \""" // its closing delimiter
                }.joined())
                Debug: \\(items.map { item in let big = item > 1
                    #if DEBUG
                    return big ? "big" : "small"
                    #else
                    return big ? "large" : "little"
                    #endif
                }.joined())
                \"""
            }
            """,
        ])
    }

    /// The compiler takes a `#sourceLocation(file:line:)` that opens a location again, but not a `#sourceLocation()`
    /// that closes one when none is open. Each mutant's branch held a copy of the list, so after the first branch
    /// closed the location, every later branch closed it again and failed to compile. Each function here but the
    /// last closes one: in its own list, after a statement on the same line, in a closure, a `case`, a type, a list
    /// with a switch of its own, a multi-line string, a call the list's first mutant removes, a `case` whose line
    /// ends in a comment, a result builder, and before a block comment that code follows on the next line. The last
    /// opens one and closes it in an `#if` clause of a type's members, which swift-syntax parses as unexpected text.
    func test_theGeneratedCodeBuildsAroundSourceLocationDirectives() throws {
        _ = try compileMutatedCheck(alongside: [
            "Located.swift": """
            #sourceLocation(file: "Located.swift.gyb", line: 1)
            func closed(_ items: [Int]) -> Int {
                let count = items.count > 1 ? 1 : 2
            #sourceLocation()
                return count
            }
            #sourceLocation(file: "Located.swift.gyb", line: 10)
            func closedAfterAStatement(_ items: [Int]) -> Int {
                let count = items.count > 1 ? 1 : 2; #sourceLocation()
                return count
            }
            #sourceLocation(file: "Located.swift.gyb", line: 20)
            func closedInAClosure(_ items: [Int]) -> Int {
                let count = items.count > 1 ? 1 : 2
                let run = { () -> Int in
            #sourceLocation()
                    return count
                }
                return run()
            }
            #sourceLocation(file: "Located.swift.gyb", line: 30)
            func closedInACase(_ items: [Int]) -> Int {
                let count = items.count > 1 ? 1 : 2
                switch count {
                case 1:
            #sourceLocation()
                default:
                    return 0
                }
                return count
            }
            #sourceLocation(file: "Located.swift.gyb", line: 40)
            func closedInAType(_ items: [Int]) -> Int {
                let count = items.count > 1 ? 1 : 2
                struct Box {
                    let value = 1
            #sourceLocation()
                }
                return count + Box().value
            }
            #sourceLocation(file: "Located.swift.gyb", line: 50)
            func closedInASwitchOfItsOwn(_ items: [Int]) -> Int {
                let count = items.count > 1 ? 1 : 2
                if count > 0 {
                    let other = count < 5 ? 3 : 4
            #sourceLocation()
                    return other
                }
                return count
            }
            #sourceLocation(file: "Located.swift.gyb", line: 60)
            func closedInAMultiLineString(_ items: [Int]) -> String {
                \"""
                \\({ () -> Int in let count = items.count > 1 ? 1 : 2; return count
                #sourceLocation()
                }())
                \"""
            }
            #sourceLocation(file: "Located.swift.gyb", line: 70)
            func closedInARemovedCall(_ log: (() -> Void) -> Void, _ note: () -> Void) {
                do {
                    log {
            #sourceLocation()
                    }
                    note()
                }
            }
            #sourceLocation(file: "Located.swift.gyb", line: 80)
            func closedAfterACaseLabelsComment(_ items: [Int]) -> Int {
                let count = items.count > 1 ? 1 : 2
                switch count {
                case 1: // nothing to do
            #sourceLocation()
                default:
                    return 0
                }
                return count
            }
            @resultBuilder enum Joined {
                static func buildBlock(_ parts: String...) -> String { parts.joined() }
                static func buildEither(first part: String) -> String { part }
                static func buildEither(second part: String) -> String { part }
            }
            func joined(@Joined _ make: () -> String) -> String { make() }
            #sourceLocation(file: "Located.swift.gyb", line: 90)
            func closedInABuilder(_ items: [Int]) -> String {
                let count = items.count > 1 ? 1 : 2
                return joined {
                    switch count {
                    case 1:
            #sourceLocation()
                    default:
                        "other"
                    }
                }
            }
            #sourceLocation(file: "Located.swift.gyb", line: 100)
            func closedBeforeABlockComment(_ items: [Int]) -> Int {
                let count = items.count > 1 ? 1 : 2
            #sourceLocation() /* a note that runs
            onto the next line */ let other = count < 3
                return other ? count : 0
            }
            func pairedInATypesIf(_ items: [Int]) -> Int {
                let count = items.count > 1 ? 1 : 2
            #sourceLocation(file: "Located.swift.gyb", line: 110)
                struct Box {
                    #if true
                    let value = 1
            #sourceLocation()
                    #endif
                }
                return count + Box().value
            }
            """,
        ])
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
    /// only `ProcessInfo` imported from Foundation and members of other imports hidden. `signature` declares
    /// the function the mutant is in. `others` are more files of the program, by name, each rewritten from the code
    /// given and holding mutants of its own. `arguments` go to the compiler as well.
    private func compileMutatedCheck(
        declaring signature: String = "func check(_ value: Int) -> Bool",
        alongside others: [String: String] = [:],
        arguments: [String] = []
    ) throws -> (program: URL, identifier: String) {
        let source = SourceCodeInfo(
            path: "/path/to/Check.swift",
            code: Parser.parse(source: """
            import class Foundation.ProcessInfo

            \(signature) {
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
        let otherFiles = try others.sorted { $0.key < $1.key }.map { name, code in
            let other = SourceCodeInfo(
                path: "/path/to/\(name)",
                code: Parser.parse(source: "import class Foundation.ProcessInfo\n\n\(code)\n")
            )
            let otherMapping = try XCTUnwrap(generateSchemataMappings(for: other).first, "\(name) holds no mutant")
            XCTAssertFalse(otherMapping.mutationSchemata.isEmpty, "\(name) holds no mutant")
            let file = directory.appendingPathComponent(name)
            try write(MuterRewriter(otherMapping).rewrite(other.code).description, to: file)
            return file.path
        }
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

        let compiled = try execute(
            URL(fileURLWithPath: xcrun),
            arguments: ["swiftc", "-swift-version", "6"] + arguments + [
                "-enable-upcoming-feature", "MemberImportVisibility",
                "-warnings-as-errors",
                // Every file's errors, not only the first failing file's.
                "-continue-building-after-errors",
                "-o", program.path,
                mutated.path,
                main.path,
            ] + otherFiles,
            environment: compilerEnvironment,
            timeLimit: 300
        )
        guard compiled.status == 0 else {
            throw Failure(description: "the generated code didn't compile:\n\(compiled.errors)")
        }
        return (program, identifier)
    }

    /// Skips a test that compiles with `-default-isolation`, which compilers before Swift 6.2 don't take. Any
    /// other failure is left for the test's own compile to report.
    private func skipUnlessTheCompilerTakesDefaultIsolation() throws {
        let empty = directory.appendingPathComponent("Empty.swift")
        try write("", to: empty)
        let probe = try execute(
            URL(fileURLWithPath: xcrun),
            arguments: ["swiftc", "-typecheck", "-default-isolation", "MainActor", empty.path],
            environment: compilerEnvironment,
            timeLimit: 300
        )
        try XCTSkipIf(
            probe.status != 0 && probe.errors.contains("unknown argument: '-default-isolation'"),
            "compiling with -default-isolation needs Swift 6.2 or later:\n\(probe.errors)"
        )
    }

    /// The compiler runs with this suite's environment, without the dynamic loader's variables the test runner
    /// may set and without the active-mutant file an outer mutation-testing run may name.
    private var compilerEnvironment: [String: String] {
        MuterProcessFactory.environment(inheriting: ProcessInfo.processInfo.environment)
            .filter { !$0.key.hasPrefix("DYLD_") }
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
