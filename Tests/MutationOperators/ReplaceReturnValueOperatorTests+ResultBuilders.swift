import XCTest

extension ReplaceReturnValueOperatorTests {
    // A builder would take the empty value as a component, which it may not build. The tree can't tell which
    // attribute is a builder, so any but those known not to be one leaves out a body's one expression; a `return`
    // turns a builder off, so its value is kept.
    func test_theOneExpressionOfABodyAResultBuilderMayBuild_isLeftAlone() throws {
        for code in [
            "@Lines func f() -> [String] { load() }",
            "struct S { @Lines var x: [String] { load() } }",
            "struct S { var x: [String] { @Lines get { load() } } }",
            "struct S { @Lines subscript(i: Int) -> [String] { load() } }",
            "@Lines @inlinable func f() -> String { load() }",
            "#if DEBUG\n@inlinable\n#endif\nfunc f() -> String { load() }",
            // A dynamic replacement takes the builder of what it replaces.
            "extension S { @_dynamicReplacement(for: header) var newHeader: [String] { load() } }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
        XCTAssertEqual(try values(in: "@Lines func f() -> [String] { return load() }"), ["load()"])
        XCTAssertEqual(try values(in: "struct S { @Lines var x: [String] { return load() } }"), ["load()"])
    }

    func test_anAttributeKnownNotToBeABuilder_keepsTheValue() throws {
        for attribute in [
            "@inlinable", "@inline(__always)", "@discardableResult", "@available(macOS 14, *)", "@objc",
            "@nonobjc", "@usableFromInline", "@MainActor", "@preconcurrency", "@_spi(Testing)",
            "@backDeployed(before: macOS 15)", "@warn_unqualified_access", "@_disfavoredOverload", "@_transparent",
            "@_alwaysEmitIntoClient",
        ] {
            XCTAssertEqual(try values(in: "\(attribute) func f() -> Int { load() }"), ["load()"], attribute)
        }
        XCTAssertEqual(try values(in: "struct S { @MainActor var x: Int { load() } }"), ["load()"])
    }

    // A closure passed to a call may be built by a builder its parameter is declared with, which may be in another
    // file. One stored, or called on the spot, isn't.
    func test_theOneExpressionOfAClosurePassedToACall_isLeftAlone() throws {
        for code in [
            "func f() { lines { () -> [String] in load() } }",
            "func f() { lines(make: { () -> [String] in load() }) }",
            "func f() { lines { () -> [String] in load() } footer: { () -> [String] in load() } }",
            "func f() { x[{ () -> Int in load() }] }",
            "func f() { #lines({ () -> [String] in load() }) }",
            "let f = { @Lines () -> [String] in load() }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
        XCTAssertEqual(try values(in: "func f() { lines { () -> [String] in return load() } }"), ["load()"])
        XCTAssertEqual(try values(in: "let f = { @MainActor () -> [String] in load() }"), ["load()"])
    }

    // Swift gives a protocol's requirement's builder to the member that meets it, which carries no attribute of its
    // own. A protocol declared in another file isn't seen.
    func test_aMemberNamedAsARequirementWithABuilder_isLeftAlone() throws {
        XCTAssertEqual(
            try values(in: """
            protocol Report {
                @Lines var lines: [String] { get }
                @Lines func footer() -> [String]
                @MainActor var title: String { get }
            }
            struct Daily: Report {
                var lines: [String] { load() }
                func footer() -> [String] { load() }
                var title: String { name }
                var other: [String] { rows }
            }
            """),
            ["name", "rows"]
        )
    }

    // A requirement in a `#if` clause, at any depth, gives its builder all the same.
    func test_aMemberNamedAsARequirementWithABuilderInACompilerDirective_isLeftAlone() throws {
        XCTAssertEqual(
            try values(in: """
            protocol Report {
            #if !os(Linux)
                @Lines var lines: [String] { get }
            #elseif DEBUG
                #if canImport(UIKit)
                @Lines func footer() -> [String]
                #endif
            #endif
            }
            struct Daily: Report {
                var lines: [String] { load() }
                func footer() -> [String] { load() }
                var other: [String] { rows }
            }
            """),
            ["rows"]
        )
    }

    // Without its `try` or `await`, a closure may no longer throw or wait, and a call it is passed to that rethrows
    // leaves its own `try` over nothing that throws, which warns.
    func test_aClosuresValueWithATryOrAwait_isLeftAlone() throws {
        for code in [
            "let f = { (x: Int) -> [Int] in return try load(x) }",
            "let f = { (x: Int) async -> Int in return await load(x) }",
            "let f = { (x: Int) -> [Int] in return [try load(x)] }",
            "let f = { (x: Int) -> [Int] in return (x > 1 ? try load(x) : []) }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
        // A nested closure's are its own, and a function's are fine.
        XCTAssertEqual(
            try values(in: "let f = { (x: Int) -> Int in return run { try load(x) } }"),
            ["run { try load(x) }"]
        )
        XCTAssertEqual(try values(in: "func f() async throws -> [Int] { try await load() }"), ["try await load()"])
    }
}
