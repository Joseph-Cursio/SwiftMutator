@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

/// A getter or function returning `some …` that is not a result builder compiles its switch as an
/// `if` expression, so every branch must have one type. A switch nested in a builder closure inside
/// it changes the default branch's type (`_ConditionalContent<…>`) and the build of every mutant
/// fails ("failed to produce diagnostic for expression"). Those nested mutants are dropped; the
/// outer ones, and every mutant in a builder or a concretely typed body, are kept.
final class OpaqueBodyNestedSchemataTests: MuterTestCase {

    func test_dropsMutantsNestedInsideAnOpaqueNonBuilderGetter() {
        let lines = keptMutantLines(in: """
        struct Row: View {
            var isExpanded: Bool
            private var toggle: some View {
                Button {
                    print("tap")
                } label: {
                    Image(systemName: isExpanded ? "up" : "down")
                }
                .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            }
        }
        """)

        XCTAssertEqual(lines, [9], "the label's nested mutant (line 7) is dropped, the outer one kept")
    }

    func test_keepsNestedMutantsInABody() {
        let lines = keptMutantLines(in: """
        struct Row: View {
            var isExpanded: Bool
            var body: some View {
                Button {
                    print("tap")
                } label: {
                    Image(systemName: isExpanded ? "up" : "down")
                }
                .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            }
        }
        """)

        XCTAssertEqual(lines, [7, 9])
    }

    func test_keepsNestedMutantsInAnExplicitBuilder() {
        let lines = keptMutantLines(in: """
        struct Row: View {
            var isExpanded: Bool
            @ViewBuilder private var toggle: some View {
                Button {
                    print("tap")
                } label: {
                    Image(systemName: isExpanded ? "up" : "down")
                }
                .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            }
        }
        """)

        XCTAssertEqual(lines, [7, 9])
    }

    func test_keepsNestedMutantsWhenTheReturnTypeIsConcrete() {
        let lines = keptMutantLines(in: """
        func check(_ values: [Int], _ limit: Int) -> Bool {
            let small = values.filter { value in value < limit }
            return small.count > 1
        }
        """)

        XCTAssertEqual(lines, [2, 3])
    }

    /// The lines of the mutants left after discovery's per-file pruning.
    private func keptMutantLines(in text: String) -> [Int] {
        let source = SourceCodeInfo(path: "/path/to/Row.swift", code: Parser.parse(source: text))
        let mappings = generateSchemataMappings(for: source)
        mappings.forEach { $0.dropNestedSchemataInOpaqueBodies(of: source.code) }

        return Set(mappings.flatMap(\.mutationSchemata).map(\.position.line)).sorted()
    }
}
