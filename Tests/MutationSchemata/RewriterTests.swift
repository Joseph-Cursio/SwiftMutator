@testable import muterCore
import SnapshotTesting
import SwiftParser
import SwiftSyntax
import TestingExtensions
import XCTest

private struct OperatorIdAndPositionAssert: Equatable, CustomStringConvertible {
    let id: MutationOperator.Id
    let position: MutationPosition

    var description: String {
        """
        OperatorIdAndPositionAssert(
            id: .\(id),
            position: MutationPosition(
                utf8Offset: \(position.utf8Offset),
                line: \(position.line),
                column: \(position.column)
            )
        )
        """
    }
}

final class RewriterTests: MuterTestCase {
    private let sampleFolder = XCTestCase.unusedTemporaryPath()
    private var samplePath: String { sampleFolder + "/sampleWithAllOperators.swift" }

    override func setUpWithError() throws {
        try super.setUpWithError()

        try FileManager.default.createDirectory(atPath: sampleFolder, withIntermediateDirectories: true)
        addTeardownBlock { [sampleFolder] in try? FileManager.default.removeItem(atPath: sampleFolder) }
        FileManager.default.createFile(
            atPath: samplePath,
            contents: allOperatorsSourceCode.data(using: .utf8)
        )
    }

    override func setUp() {
        super.setUp()

        current.writeFile = { try $0.write(toFile: $1, atomically: true, encoding: .utf8) }
    }

    func test_allOperatorsWithImplicitReturn() throws {
        let sourceCode = try XCTUnwrap(PrepareSourceCode().prepareSourceCode(samplePath))

        let all = generateSchemataMappings(
            for: sourceCode.source,
            changes: sourceCode.changes
        )

        XCTAssertEqual(all.count, 1)

        let mapping = try XCTUnwrap(all.first)

        let positions = mapping.mutationSchemata
            .map { ($0.mutationOperatorId, $0.position) }
            .map(OperatorIdAndPositionAssert.init)

        AssertSnapshot(positions.description)
    }

    func test_allOperatorsWithImplicitReturnSourceCode() throws {
        let sourceCode = try XCTUnwrap(PrepareSourceCode().prepareSourceCode(samplePath))

        let all = generateSchemataMappings(
            for: sourceCode.source,
            changes: sourceCode.changes
        )

        XCTAssertEqual(all.count, 1)

        let mapping = try XCTUnwrap(all.first)

        let sut = MuterRewriter(mapping)

        let mutatedSourceCode = sut.rewrite(sourceCode.source.code).description

        AssertSnapshot(formatCode(mutatedSourceCode.description))
    }

    // A stored-property initializer has no statement list of its own, so its mutations were
    // keyed to the nearest one walking up: the file's top level, or a top-level `#if`. Wrapping
    // that list in the mutation switch puts imports and type declarations inside an `if`, which
    // does not compile, and the shared baseline build of every mutant fails with it. Its switch goes
    // around the value alone.
    func test_doesNotWrapFileScopeStatementsInAMutationSwitch() throws {
        let source = SourceCodeInfo(
            path: "/path/to/probe.swift",
            code: Parser.parse(source: """
            import Foundation

            struct Config {
                static let isLarge = Int.max > 1
                func check(_ value: Int) -> Bool {
                    return value > 1
                }
            }

            #if DEBUG
            enum Probe {
                static let temp = CommandLine.arguments.count > 1 ? "a" : "b"
            }
            #endif
            """)
        )
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)

        let lines = mapping.mutationSchemata.map(\.position.line)
        XCTAssertEqual(Set(lines), [4, 6, 12], "the values' comparisons are kept, and check(_:)'s")

        let rewritten = MuterRewriter(mapping).rewrite(source.code).description
        XCTAssertEqual(fileScopeSwitches(in: rewritten), [], rewritten)
        XCTAssertEqual(
            rewritten.components(separatedBy: ".environment[").count - 1,
            mapping.mutationSchemata.count,
            "a branch for each mutant"
        )
        XCTAssertTrue(rewritten.contains("static let isLarge = if __SwiftMutator_"), rewritten)

        // The shape the bug made: the file's statements, and a top-level `#if` clause's, each wrapped in a switch.
        // The check finds both, so its finding none above means none was added.
        let wrappedFileScope = """
        if __SwiftMutator_0123.environment["probe_0123_RelationalOperatorReplacement_4_29_70"] != nil {
            import Foundation
        } else {
            import Foundation
        }
        #if DEBUG
        if __SwiftMutator_0123.environment["probe_0123_RelationalOperatorReplacement_12_55_250"] != nil {
            enum Probe {}
        } else {
            enum Probe {}
        }
        #endif
        """
        XCTAssertEqual(fileScopeSwitches(in: wrappedFileScope).count, 2)
    }

    /// The mutation switches among the file's own statements, and those of its top-level `#if` clauses, each by its
    /// first line. A switch is an `if` that reads a mutant from `__SwiftMutator_<hash>.environment`.
    private func fileScopeSwitches(in code: String) -> [String] {
        func switches(in statements: CodeBlockItemListSyntax) -> [String] {
            statements.flatMap { statement -> [String] in
                if let ifConfig = statement.item.as(IfConfigDeclSyntax.self) {
                    return ifConfig.clauses.flatMap { clause -> [String] in
                        guard case let .statements(clauseStatements)? = clause.elements else { return [] }
                        return switches(in: clauseStatements)
                    }
                }
                let text = statement.item.trimmedDescription
                guard text.hasPrefix("if "), text.contains("__SwiftMutator_"), text.contains(".environment[") else {
                    return []
                }
                return [String(text.prefix { !$0.isNewline })]
            }
        }
        return switches(in: Parser.parse(source: code).statements)
    }

    // A mutant is located in its block by position. Searching the block's text found the first copy of
    // a repeated expression, so the second ternary's mutant changed the first one instead.
    func test_mutatesTheRightCopyOfARepeatedExpression() throws {
        let source = SourceCodeInfo(path: "/path/to/twice.swift", code: Parser.parse(source: """
        func twice(_ flag: Bool) -> Int {
            let first = flag ? 1 : 2
            let second = flag ? 1 : 2
            return first + second
        }
        """))
        let visitor = SwapTernaryOperator.Visitor(sourceCodeInfo: source)
        visitor.walk(source.code)
        let mutations = visitor.schemataMappings.mutationSchemata.map(\.syntaxMutation.description)

        XCTAssertEqual(mutations.count, 2)
        XCTAssertEqual(Set(mutations).count, 2, "both mutants changed the same ternary: \(mutations)")
    }
}

private let allOperatorsSourceCode =
    """
    #if os(iOS) || os(tvOS)
        print("please ignore me")
    #endif

    struct ConditionalOperators {
        func something(_ a: Int) -> String {
            let b = a == 5
            let e = a != 1
            let c = a >= 4
            let d = a <= 10
            let f = a < 5
            let g = a > 5

            if a == 10 {
                return "hello"
            }

            return a == 9 ? "goodbye" : "what"
        }

        func < (_: String, _: String) -> Bool {
            return false
        }

        func baz() {
            _ = foo(bar: { $0 == char })
        }
    }

    struct LogicalConnectors {
        func someCode() -> Bool {
            return false && false
        }

        func someOtherCode() -> Bool {
            return true || true
        }
    }

    struct SideEffects {
        func containsSideEffect() -> Int {
            _ = causesSideEffect()
            return 1
        }

        func containsSideEffect() -> Int {
            print("something")

            _ = causesSideEffect()
        }

        @discardableResult
        func causesSideEffect() -> Int {
            return 0
        }

        func causesAnotherSideEffect() {
            let key = "some key"
            let value = aFunctionThatReturnsAValue()
            someFunctionThatWritesToADatabase(key: key, value: value)
        }

        func containsSpecialCases() {
            fatalError("this should never be deleted!")
            exit(1)
            abort()
        }

        func containsADeepMethodCall() {
            let containsIgnoredResult = statement.description.contains("_ = ")
            var anotherIgnoredResult = statement.description.contains("_ = ")
        }

        func containsAVoidFunctionCallThatSpansManyLine() {
            functionCall(
                "some argument",
                anArgumentLabel: "some argument that's different",
                anotherArgumentLabel: 5
            )
        }
    }

    struct Concurrency {
        private let semaphore = DispatchSemaphore(value: 1)
        private let conditionLock = NSConditionLock(condition: 0)
        private let lock = NSRecursiveLock()
        private let condition = NSCondition()

        private func semaphoreLock(block: () -> Void) {
            defer { semaphore.signal() }
            semaphore.wait()
            block()
        }

        private func recursiveLock(block: () -> Void) {
            defer { lock.unlock() }
            lock.lock()
            block()
        }

        private func nsCondition(block: () -> Void) {
            defer { condition.signal() }
            condition.wait()
            block()
        }

        private func nsConditionLock(block: () -> Void) {
            defer { conditionLock.unlock(withCondition: 1) }
            conditionLock.lock(whenCondition: 1)
            block()
        }

        private func sync(block: () -> Int) -> Int {
            let semaphore = DispatchSemaphore(value: 2)
            semaphore.wait()
            let value = block()
            semaphore.signal()

            return value
        }
    }

    struct TernayOperators {
        func someCode(_ a: Bool) -> Bool {
            return a ? true : false
        }

        func someAnotherCode(_ a: Bool) -> String {
            return a ? "true" : "false"
        }

        func someCode(_ a: Bool, _ b: Bool) -> Bool {
            return a ? b ? true : false : false
        }
    }

    public enum Enum {
        case a(CGFloat)
        case b(CGFloat)

        public func kerning(for something: String?) -> CGFloat {
            switch self {
            case let .a(value):
                return value
            case let .b(value):
                if something == nil {
                    return 0
                }
                return 10
            }
        }
    }

    extension String {
        private func bar() -> (String, String) {
            return Something { value in
                var remainder = value
                for char in self {
                    guard let (_, newRemainder) = doSomething(condition: { $0 == char }) else {
                        return nil
                    }

                    remainder = newRemainder
                }
                return (self, remainder)
            }
        }
    }

    """
