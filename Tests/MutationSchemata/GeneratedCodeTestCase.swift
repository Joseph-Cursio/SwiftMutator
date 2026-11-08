@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

/// The base of the tests that rewrite files as a mutation-testing run does, compile them with the real compiler and
/// run the program. The snapshots record swift-format's rewrite of the generated code, which hides errors, and can't
/// show which mutant it switches on.
class GeneratedCodeTestCase: MuterTestCase {
    let xcrun = "/usr/bin/xcrun"
    /// What the compiled program exits with when the generated code's fatal error traps.
    let trapExitStatus: Int32 = 70
    private(set) var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: xcrun),
            "compiling the generated code needs \(xcrun)"
        )
        directory = try URL(fileURLWithPath: makeTemporaryDirectory())
    }

    struct Run {
        let reason: Foundation.Process.TerminationReason
        let status: Int32
        let output: String
        let errors: String
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// A program compiled from rewritten files, and what the rewrite found in them.
    struct Compiled {
        let program: URL
        /// Each rewritten file's mutants, by the file's name.
        let mappings: [String: SchemataMutationMapping]
        /// Each rewritten file's code as given, by the file's name.
        let sources: [String: String]
        /// Each rewritten file's generated code, by the file's name.
        let rewritten: [String: String]

        /// The mutants of the file named `name`, in the order mutation testing runs them.
        func mutants(in name: String) -> MutationSchemata {
            mappings[name]?.mutationSchemata ?? []
        }

        /// The mutants of the file named `name` on the line of its code, as given, that holds `text`. It fails unless
        /// exactly one line does.
        func mutants(
            in name: String,
            onTheLineHolding text: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) -> MutationSchemata {
            let lines = (sources[name] ?? "").components(separatedBy: "\n").enumerated()
                .filter { $0.element.contains(text) }
            XCTAssertEqual(lines.count, 1, "lines of \(name) holding \(text)", file: file, line: line)
            guard let number = lines.first.map({ $0.offset + 1 }) else { return [] }
            return mutants(in: name).filter { $0.position.line == number }
        }

        /// The operators of the mutants of the file named `name` on the line of its code that holds `text`.
        func operators(
            in name: String,
            onTheLineHolding text: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) -> Set<MutationOperator.Id> {
            Set(mutants(in: name, onTheLineHolding: text, file: file, line: line).map(\.mutationOperatorId))
        }

        /// The ID of the one mutant of the file named `name` that `isWanted` picks. It fails unless exactly one does,
        /// so a test can't switch on a mutant other than the one it means.
        func identifier(
            in name: String,
            file: StaticString = #filePath,
            line: UInt = #line,
            where isWanted: (MutationSchema) -> Bool
        ) throws -> String {
            let wanted = mutants(in: name).filter(isWanted)
            XCTAssertEqual(wanted.count, 1, "\(mutants(in: name))", file: file, line: line)
            return try XCTUnwrap(wanted.first, file: file, line: line).id
        }
    }

    /// Prepares and rewrites each file of `mutated`, by name, as a mutation-testing run does: the `ProcessInfo` import
    /// and the comments that turn linters off are added in front, the file is parsed again, every operator's mutants
    /// are found, the mutants nested in an opaque body that isn't a result builder are dropped, and the switches are
    /// written in. Each file must hold a mutant. The files of `plain` are compiled as given, and when neither names a
    /// `main.swift`, an empty one is added.
    ///
    /// The program is compiled in the strictest mode the generated code must pass: Swift 6, with only `ProcessInfo`
    /// imported from Foundation and members of other imports hidden, and every warning an error. It's a full build,
    /// not a type check, which misses errors found later, such as a `guard` body that falls through. `arguments` go to
    /// the compiler as well. It throws if the program doesn't compile. With `recovering`, a failed build is tried once
    /// more, as `CompileRecovery` does, with each switch the compiler says a result builder can't take in a closure
    /// called on the spot.
    func compileMutated(
        _ mutated: [String: String],
        plain: [String: String] = [:],
        arguments: [String] = [],
        recovering: Bool = false
    ) throws -> Compiled {
        var mappings: [String: SchemataMutationMapping] = [:]
        var rewritten: [String: String] = [:]
        var trees: [String: SourceFileSyntax] = [:]
        for (name, code) in mutated {
            let path = "/path/to/\(name)"
            let addImport = AddImportRewriter()
            let disableLinters = DisableLintersRewriter()
            let prepared = disableLinters.visit(addImport.visit(Parser.parse(source: code))).description
            let source = SourceCodeInfo(path: path, code: Parser.parse(source: prepared))
            let changes = MutationSourceCodePreparationChange(
                newLines: addImport.newLinesAddedToFile + disableLinters.newLinesAddedToFile
            )
            var mapping = try XCTUnwrap(
                generateSchemataMappings(for: source, changes: changes).first,
                "\(name) holds no mutant"
            )
            mapping.dropNestedSchemataInOpaqueBodies(of: source.code)
            XCTAssertFalse(mapping.mutationSchemata.isEmpty, "\(name) holds no mutant")
            mappings[name] = mapping
            trees[name] = source.code
            rewritten[name] = MuterRewriter(mapping).visit(source.code).description
        }

        var compiled = try compile(rewritten, plain: plain, arguments: arguments)
        if compiled.run.status != 0, recovering {
            for (name, code) in rewritten {
                let locator = MutantLocator(rewritten: code, filePath: "/path/to/\(name)")
                let errors = CompilerError.all(in: compiled.run.errors)
                    .filter { URL(fileURLWithPath: $0.filePath).lastPathComponent == name }
                for id in Set(errors.compactMap(locator.switchABuilderCantTake)) {
                    _ = mappings[name]?.switchInAClosureCalledOnTheSpot(theListOf: id)
                }
                if let mapping = mappings[name], let tree = trees[name] {
                    rewritten[name] = MuterRewriter(mapping).visit(tree).description
                }
            }
            compiled = try compile(rewritten, plain: plain, arguments: arguments)
        }
        guard compiled.run.status == 0 else {
            throw Failure(description: "the generated code didn't compile:\n\(compiled.run.errors)")
        }
        return Compiled(program: compiled.program, mappings: mappings, sources: mutated, rewritten: rewritten)
    }

    /// Compiles `rewritten` and `plain`, by file name, as `compileMutated` describes.
    private func compile(
        _ rewritten: [String: String],
        plain: [String: String],
        arguments: [String]
    ) throws -> (program: URL, run: Run) {
        var files = rewritten.merging(plain) { _, _ in
            XCTFail("a file is both mutated and plain")
            return ""
        }
        if files["main.swift"] == nil {
            files["main.swift"] = ""
        }
        let paths = try files.sorted { $0.key < $1.key }.map { name, code in
            let file = directory.appendingPathComponent(name)
            try write(code, to: file)
            return file.path
        }

        let program = directory.appendingPathComponent("program")
        let compiled = try execute(
            URL(fileURLWithPath: xcrun),
            arguments: ["swiftc", "-swift-version", "6"] + arguments + [
                "-enable-upcoming-feature", "MemberImportVisibility",
                "-warnings-as-errors",
                // Every file's errors, not only the first failing file's.
                "-continue-building-after-errors",
                "-o", program.path,
            ] + paths,
            environment: compilerEnvironment,
            timeLimit: 300
        )
        return (program, compiled)
    }

    /// A `main.swift` that runs `statements` after setting up its trap handlers. A fatal error traps (SIGTRAP on
    /// arm64, SIGILL on x86_64), and macOS keeps a crash report, outside any temporary folder, of every program a
    /// trap kills. So the program exits from handlers of its own instead; the generated code's fatal error is
    /// untouched.
    func driver(_ statements: String) -> String {
        """
        import Darwin

        signal(SIGTRAP) { _ in _exit(\(trapExitStatus)) }
        signal(SIGILL) { _ in _exit(\(trapExitStatus)) }
        \(statements)

        """
    }

    /// The compiler runs with this suite's environment, without the dynamic loader's variables the test runner
    /// may set and without the active-mutant file an outer mutation-testing run may name.
    var compilerEnvironment: [String: String] {
        MuterProcessFactory.environment(inheriting: ProcessInfo.processInfo.environment)
            .filter { !$0.key.hasPrefix("DYLD_") }
    }

    /// Runs the compiled program with nothing in its environment but `PATH` and `variables`.
    func run(_ program: URL, adding variables: [String: String] = [:]) throws -> Run {
        try execute(
            program,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"].merging(variables) { _, added in added },
            timeLimit: 60
        )
    }

    /// Runs the compiled program with the mutant `identifier` switched on by its own variable.
    func run(_ program: URL, switchingOn identifier: String) throws -> Run {
        try run(program, adding: [identifier: "YES"])
    }

    /// Runs a process to its end, or kills it and throws once `timeLimit` seconds pass. Its output goes to
    /// files rather than pipes, so a process that writes a lot never blocks on a full pipe.
    func execute(
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

    func write(_ text: String, to file: URL) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}
