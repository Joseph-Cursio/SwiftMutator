import Foundation
@testable import muterCore

/// A run for the reports other tools read, Stryker's and SARIF: a project whose path has a space, a file with
/// characters UTF-8 and UTF-16 count apart and code its operators place where it ends, one that can't be read, one
/// outside the project, and one no test ran.
enum ToolReportFixture {
    static let project = URL(fileURLWithPath: "/work/My Foo")
    static let copy = URL(fileURLWithPath: "/work/My Foo_mutated")

    /// Sources/Rules.swift. On line 2, `==` is at byte 25 and unit 24, and `true` at byte 39 and unit 38. The ternary
    /// on lines 6 to 8, the `&&` that starts line 12 and the statement on line 15 are where their operators place them
    /// (`ternaryEnd`, `andPlace`, `statementEnd`): where the ternary and the statement end, and `&&` at the end of the
    /// line above.
    static let rules = """
    func allows(_ a: Int, _ b: Int) -> Bool {
        let café = 1; if a == b { return true }
        return a < b
    }
    func pick(_ flag: Bool) -> Int {
        flag
            ? 1
            : 2
    }
    func both(_ a: Bool, _ b: Bool) -> Bool {
        a
            && b
    }
    func store(_ items: inout [Int]) {
        items.append(1)
    }

    """

    /// The ternary as its operator gives it, on one line.
    static let ternary = "flag ? 1 : 2"
    static let ternaryEnd = (line: 8, column: 12)
    static let andPlace = (line: 11, column: 6)
    static let statementEnd = (line: 15, column: 20)

    /// Reads Rules.swift, Unrun.swift and the file outside the project; never Other.swift.
    static let read: ReadFile = { path in
        switch path {
        case Self.project.path + "/Sources/Rules.swift": Data(Self.rules.utf8)
        case Self.project.path + "/Sources/Unrun.swift": Data("func unrun() {}\n".utf8)
        case "/elsewhere/Shared.swift": Data("let same = a == b\n".utf8)
        default: nil
        }
    }

    /// A mutant of `operatorId` at `line` and `column`, the UTF-8 one, of `path` in the project, or of an absolute
    /// `path` outside it, which has no key.
    static func mutant(
        _ outcome: TestSuiteOutcome,
        line: Int,
        column: Int,
        operatorId: MutationOperator.Id = .ror,
        path: String = "Sources/Rules.swift",
        before: String = "==",
        after: String = "!=",
        description: String = "changed == to !=",
        killingTests: MutationTestOutcome.KillingTests? = nil,
        durationSeconds: Double? = nil
    ) -> MutationTestOutcome.Mutation {
        let isOutside = path.hasPrefix("/")
        return .make(
            testSuiteOutcome: outcome,
            point: .make(
                mutationOperatorId: operatorId,
                filePath: isOutside ? path : copy.path + "/" + path,
                position: MutationPosition(utf8Offset: 0, line: line, column: column)
            ),
            snapshot: .make(before: before, after: after, description: description),
            originalProjectDirectoryUrl: project,
            mutatedProjectDirectoryURL: copy,
            killingTests: killingTests,
            key: isOutside ? nil : MutantKey(
                path: path, mutationOperatorId: operatorId, line: line, column: column, occurrence: 0
            ),
            durationSeconds: durationSeconds
        )
    }

    /// One mutant of each outcome, and every kind of file.
    static var everyOutcome: MutationTestOutcome {
        var leftOut = mutant(
            .buildError,
            line: 3,
            column: 14,
            operatorId: .relationalBoundary,
            before: "<",
            after: "<=",
            description: "changed < to <="
        )
        leftOut.leftOutWithOthers = true
        let tests = MutationTestOutcome.KillingTests(
            tests: [
                .init(name: "RulesTests.test_allows()", location: "RulesTests.swift:4"),
                .init(name: "RulesTests.test_equal()", location: nil),
            ],
            count: 2,
            isComplete: true
        )
        let crash = mutant(
            .runtimeError,
            line: 2,
            column: 39,
            operatorId: .flipBooleanLiteral,
            before: "true",
            after: "false",
            description: "changed true to false",
            killingTests: .init(tests: [tests.tests[0]], count: 1, isComplete: true),
            durationSeconds: 0.75
        )
        let timeout = mutant(
            .timeout,
            line: ternaryEnd.line,
            column: ternaryEnd.column,
            operatorId: .swapTernary,
            before: ternary,
            after: "flag ? 2 : 1",
            description: "swapped ternary"
        )
        let buildError = mutant(
            .buildError,
            line: 4,
            column: 9,
            operatorId: .logicalOperator,
            path: "Sources/Other.swift",
            before: "&&",
            after: "||",
            description: "changed && to ||"
        )
        let notCovered = mutant(
            .noCoverage,
            line: statementEnd.line,
            column: statementEnd.column,
            operatorId: .removeSideEffects,
            before: "items.append(1)",
            after: "removed line",
            description: "removed line"
        )
        return outcome([
            mutant(.failed, line: 2, column: 25, killingTests: tests, durationSeconds: 1.25),
            crash,
            mutant(.passed, line: 3, column: 14, before: "<", after: ">", description: "changed < to >"),
            leftOut,
            timeout,
            buildError,
            notCovered,
            mutant(.passed, line: 1, column: 14, operatorId: .ror, path: "/elsewhere/Shared.swift"),
        ])
    }

    static func outcome(_ mutations: [MutationTestOutcome.Mutation]) -> MutationTestOutcome {
        MutationTestOutcome(
            mutations: mutations,
            coverage: .make(percent: 70, filesWithoutCoverage: [copy.path + "/Sources/Unrun.swift"]),
            projectPath: project.path,
            mutatedProjectPath: copy.path
        )
    }
}
