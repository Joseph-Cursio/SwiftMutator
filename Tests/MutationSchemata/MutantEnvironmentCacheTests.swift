@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

/// Every mutated block asks "is my mutant active?" each time it runs. Asking with
/// `ProcessInfo.processInfo.environment[id]` rebuilds the whole environment dictionary on every
/// call, about 76 µs, and in hot code that slowed SwiftProjectLint's test run from ~9 s to ~93 s for
/// every mutant. The rewritten file now reads one lazily initialised copy, about 0.16 µs a call.
final class MutantEnvironmentCacheTests: MuterTestCase {
    private let cacheName = MuterRewriter.environmentCacheName(forFileAt: "/path/to/Sample.swift")

    func test_switchesReadTheFileCacheInsteadOfTheLiveEnvironment() throws {
        let rewritten = try rewrite("""
        func check(_ value: Int) -> Bool {
            return value > 1
        }
        """)

        XCTAssertFalse(rewritten.contains("ProcessInfo.processInfo.environment["), rewritten)
        XCTAssertTrue(rewritten.contains("\(cacheName).environment[\""), rewritten)
    }

    func test_theCacheIsDeclaredOnceAtTheEndOfAMutatedFile() throws {
        let rewritten = try rewrite("""
        func first(_ value: Int) -> Bool {
            return value > 1
        }

        func second(_ value: Int) -> Bool {
            return value < 9
        }
        """)

        let declarations = rewritten.components(separatedBy: "enum \(cacheName) {").count - 1
        XCTAssertEqual(declarations, 1, rewritten)
        let lastLine = rewritten.split(separator: "\n").last.map(String.init)
        XCTAssertEqual(lastLine?.trimmingCharacters(in: .whitespaces), "}")
        XCTAssertFalse(Parser.parse(source: rewritten).hasError, rewritten)
    }

    func test_aFileWithoutMutantsIsLeftUnchanged() throws {
        let text = "func constant() -> Int { 4 }\n"
        XCTAssertEqual(try rewrite(text), text)
    }

    // SwiftPM keys its cache of compiled package manifests on the whole environment, so a `swift test`
    // run can't name its mutant in a variable of the mutant's own without recompiling every manifest.
    // It names a file instead, holding the mutant's ID, and the cache adds that ID as if it were set.
    // Only the first line counts, so a file written by hand with `echo` works too.
    func test_theCacheAddsTheMutantNamedInTheActiveMutantFile() throws {
        let rewritten = try rewrite("""
        func check(_ value: Int) -> Bool {
            return value > 1
        }
        """)

        XCTAssertTrue(rewritten.contains(#"environment["SWIFTMUTATOR_ACTIVE_MUTANT_FILE"]"#), rewritten)
        XCTAssertTrue(rewritten.contains("String(contentsOfFile: path, encoding: .utf8)"), rewritten)
        XCTAssertTrue(rewritten.contains("contents.prefix { !$0.isNewline }"), rewritten)
        XCTAssertTrue(rewritten.contains(#"environment[identifier] = "YES""#), rewritten)
    }

    // A file the tests can't read would otherwise switch no mutant on, and every mutant would survive.
    func test_anUnreadableActiveMutantFileStopsTheTestsRatherThanSwitchingNothingOn() throws {
        let rewritten = try rewrite("""
        func check(_ value: Int) -> Bool {
            return value > 1
        }
        """)

        XCTAssertTrue(
            rewritten.contains(#"fatalError("SwiftMutator could not read the active mutant from \(path)")"#),
            rewritten
        )
    }

    // Only how the cache is filled changes: every switch still asks it for its own mutant's ID.
    func test_switchConditionsAreUnchanged() throws {
        let rewritten = try rewrite("""
        func check(_ value: Int) -> Bool {
            return value > 1
        }
        """)

        XCTAssertTrue(
            rewritten.contains(#"\#(cacheName).environment["Sample_RelationalOperatorReplacement_"#),
            rewritten
        )
        XCTAssertTrue(rewritten.contains(#"] != nil"#), rewritten)
    }

    // An `@inlinable`, `@_alwaysEmitIntoClient` or `@_transparent` body, or a public function's default argument,
    // can reference only public and `@usableFromInline` declarations, and a mutant in one reads the cache.
    func test_theCacheCanBeReadFromInlinableCode() throws {
        let rewritten = try rewrite("""
        @inlinable
        public func check(_ value: Int) -> Bool {
            return value > 1
        }
        """)

        XCTAssertTrue(rewritten.contains("@usableFromInline internal enum \(cacheName) {"), rewritten)
        XCTAssertTrue(
            rewritten.contains("@usableFromInline nonisolated static let environment: [String: String]"),
            rewritten
        )
        XCTAssertFalse(rewritten.contains("fileprivate"), rewritten)
    }

    // The cache is internal, so no two files of a module may name it alike, and the compiler doesn't build a module
    // with two files of the same name. The name is the same in every process and wherever the project is.
    func test_theCacheIsNamedAfterItsFilesName() {
        let name = MuterRewriter.environmentCacheName(forFileAt:)

        XCTAssertEqual(name("/path/to/Sample.swift"), "__SwiftMutator_c6ec652bc78cf45e")
        XCTAssertEqual(name("/elsewhere/Sample.swift"), name("/path/to/Sample.swift"))
        XCTAssertNotEqual(name("/path/to/Other.swift"), name("/path/to/Sample.swift"))
        XCTAssertNotEqual(name("/path/to/sample.swift"), name("/path/to/Sample.swift"))
        XCTAssertFalse(Parser.parse(source: "enum \(name("/path/to/Main+Tests.swift")) {}").hasError)
    }

    private func rewrite(_ text: String) throws -> String {
        let source = SourceCodeInfo(path: "/path/to/Sample.swift", code: Parser.parse(source: text))
        let mapping = generateSchemataMappings(for: source).first ?? SchemataMutationMapping(filePath: source.path)
        return MuterRewriter(mapping).rewrite(source.code).description
    }
}
