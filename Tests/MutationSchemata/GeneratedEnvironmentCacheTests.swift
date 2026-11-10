@testable import muterCore
import XCTest

/// Compiles a rewritten file with the real compiler and runs it, to check which mutant the generated code switches
/// on. A `swift test` run names its mutant in a file; any other test command names it in a variable of the mutant's
/// own, and the generated code must switch it on either way.
final class GeneratedEnvironmentCacheTests: GeneratedCodeTestCase {
    /// Without ReplaceBooleanValue: its `let big = true` makes the compiler warn that a branch of the `?:` that reads
    /// `big` will never be executed, and these files compile with warnings as errors. Nor ReplaceReturnValue: its
    /// `return 0` in place of `return count` leaves the local `count` never used, which warns too. Their own shapes
    /// compile in GeneratedCodeShapesTests. RelationalOperatorReplacement's constants would make the compiler warn so
    /// of a `let` that is only a comparison, or a ternary of literals on one, so the files' are more than that.
    override var operatorsToDiscoverWith: MutationOperatorList {
        super.operatorsToDiscoverWith.filter { ![.replaceBooleanValue, .replaceReturnValue].contains($0) }
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

    // The marker says the mutant's block ran, and the file beside it that the run read the mutants' switches. Neither
    // may change what the code does.
    func test_theGeneratedCodeShowsWhetherTheMutantsBlockRan() throws {
        let (program, identifier) = try compileMutatedCheck()
        let activeMutantFile = directory.appendingPathComponent("active-mutant")
        let marker = directory.appendingPathComponent("marker")
        let reached = URL(fileURLWithPath: marker.path + ActivationMarker.reachedSuffix)
        let file = [activeMutantFileKey: activeMutantFile.path]

        try write(identifier + "\n" + marker.path, to: activeMutantFile)
        XCTAssertEqual(try run(program, adding: file).output, "mutant\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the mutant's block ran")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reached.path), "the run read its switches")

        try FileManager.default.removeItem(at: marker)
        try FileManager.default.removeItem(at: reached)
        try write("Elsewhere_RelationalOperatorReplacement_1_1_0\n" + marker.path, to: activeMutantFile)
        XCTAssertEqual(try run(program, adding: file).output, "original\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "another mutant's block didn't run")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reached.path), "the run read its switches")

        // As xcodebuild's and other test commands' runs are told.
        try FileManager.default.removeItem(at: reached)
        let environment = [identifier: "YES", activationMarkerKey: marker.path]
        XCTAssertEqual(try run(program, adding: environment).output, "mutant\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the mutant's block ran")

        // A line break in the marker's path, as a project's folder may hold, stays in it.
        let awkward = directory.appendingPathComponent("two\nlines")
        try FileManager.default.createDirectory(at: awkward, withIntermediateDirectories: true)
        let inIt = awkward.appendingPathComponent("marker")
        try write(identifier + "\n" + inIt.path, to: activeMutantFile)
        XCTAssertEqual(try run(program, adding: file).output, "mutant\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inIt.path), "the whole path, line break and all")

        // A place it can't write, as a sandboxed test host has, changes nothing.
        let nowhere = directory.appendingPathComponent("no/such/folder/marker").path
        try write(identifier + "\n" + nowhere, to: activeMutantFile)
        XCTAssertEqual(try run(program, adding: file).output, "mutant\n", "a marker that can't be written")
        // Nor does no marker at all, as the command `--mutant` prints gives none.
        try write(identifier, to: activeMutantFile)
        XCTAssertEqual(try run(program, adding: file).output, "mutant\n", "no marker named")
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
                Debug: \\(items.map { item in let big = item > 1 || item < -1
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

    // MARK: - Helpers

    /// Rewrites a file holding one mutant, as `swift test` builds it, and compiles it into a program that prints
    /// which code ran. `signature` declares the function the mutant is in. `others` are more files of the program, by
    /// name, each rewritten from the code given and holding mutants of its own. `arguments` go to the compiler as well.
    func compileMutatedCheck(
        declaring signature: String = "func check(_ value: Int) -> Bool",
        alongside others: [String: String] = [:],
        arguments: [String] = []
    ) throws -> (program: URL, identifier: String) {
        let check = """
        \(signature) {
            return value > 1
        }
        """
        let compiled = try compileMutated(
            others.merging(["Check.swift": check]) { _, _ in
                XCTFail("Check.swift is the file of the mutant switched on")
                return check
            },
            plain: ["main.swift": driver(#"print(check(5) ? "original" : "mutant")"#)],
            arguments: arguments
        )
        // Its RelationalOperatorReplacement mutant `false`, as `value >= 1` and `value != 1` give what `value > 1`
        // does for 5: `identifier` fails unless exactly one is picked.
        return try (compiled.program, compiled.identifier(in: "Check.swift") {
            $0.mutationOperatorId == .ror && $0.snapshot.after == "false"
        })
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
}
