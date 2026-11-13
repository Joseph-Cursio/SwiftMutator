import XCTest

extension GeneratedEnvironmentCacheTests {
    /// Under `-default-isolation MainActor`, mutants in code with an isolation of its own must still read the cache:
    /// an actor's method, a `@Sendable` closure, a function of another global actor, and a detached task's closure.
    /// `compileMutatedCheck` throws if the generated code doesn't compile.
    func test_theGeneratedCodeBuildsInEachIsolationOfAModuleIsolatedToTheMainActorByDefault() throws {
        try skipUnlessTheCompilerTakesDefaultIsolation()
        let (program, identifier) = try compileMutatedCheck(
            declaring: "nonisolated func check(_ value: Int) -> Bool",
            alongside: [
                "Counter.swift": """
                actor Counter {
                    func isLarge(_ value: Int) -> Bool {
                        return value > 1
                    }
                }
                """,
                "Largeness.swift": """
                nonisolated func largeness() -> @Sendable (Int) -> Bool {
                    return { value in value > 1 }
                }
                """,
                "Background.swift": """
                @globalActor actor Background {
                    static let shared = Background()
                }

                @Background func isLargeInTheBackground(_ value: Int) -> Bool {
                    return value > 1
                }
                """,
                "Detached.swift": """
                nonisolated func isLargeWhenDetached(_ value: Int) async -> Bool {
                    return await Task.detached { value > 1 }.value
                }
                """,
            ],
            arguments: ["-default-isolation", "MainActor"]
        )

        XCTAssertEqual(try run(program).output, "original\n", "no mutant named")
        XCTAssertEqual(try run(program, adding: [identifier: "YES"]).output, "mutant\n", "the mutant's own variable")
    }

    /// Under library evolution, the initial value of a `@frozen` type's stored property is copied into the modules
    /// that use it, so a mutant in it can reference only public and `@usableFromInline` declarations, as one in an
    /// `@inlinable` body can (#137).
    func test_theGeneratedCodeBuildsInAFrozenTypesStoredPropertyUnderLibraryEvolution() throws {
        let (program, identifier) = try compileMutatedCheck(
            alongside: [
                "Limits.swift": """
                @frozen public struct Limits {
                    public var isLarge: (Int) -> Bool = { $0 > 1 }

                    public init() {}
                }
                """,
            ],
            arguments: ["-enable-library-evolution"]
        )

        XCTAssertEqual(try run(program).output, "original\n", "no mutant named")
        XCTAssertEqual(try run(program, adding: [identifier: "YES"]).output, "mutant\n", "the mutant's own variable")
    }
}
