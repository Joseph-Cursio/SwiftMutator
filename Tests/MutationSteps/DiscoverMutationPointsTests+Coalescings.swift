@testable import muterCore
import XCTest

extension DiscoverMutationPointsTests {
    /// Values whose `??` fallback already is what ReplaceReturnValue or ReplaceBooleanValue puts in their place, so
    /// that ReplaceNilCoalescing's mutant is the same code, with where that mutant goes.
    private var coalescedValues: [(code: String, mutant: String)] {
        [
            ("func f(n: () -> Int?) -> Int { return n() ?? 0 }\n", "return 0"),
            ("func f(b: () -> Bool?) -> Bool { return b() ?? false }\n", "return false"),
            ("func f(s: String?) -> String { s ?? \"\" }\n", "\"\""),
        ]
    }

    // ReplaceNilCoalescing's fallback stands for ReplaceReturnValue's empty value and ReplaceBooleanValue's literal
    // when they are the fallback, so each such value gets that mutant once; `b() ?? false` keeps its `true`, and
    // FlipBooleanLiteral's `b() ?? true`.
    func test_aCoalescingWhoseFallbackIsTheValuesReplacement_getsOneMutantOfIt() async throws {
        let expected: [[MutationOperator.Id]] = [
            [.replaceNilCoalescing],
            [.replaceNilCoalescing, .replaceBooleanValue, .flipBooleanLiteral],
            [.replaceNilCoalescing],
        ]
        for ((code, mutant), operators) in zip(coalescedValues, expected) {
            let schemata = try await schemata(discoveredIn: code, by: .allOperators)
            XCTAssertEqual(
                schemata.map(\.mutationOperatorId).sorted { $0.rawValue < $1.rawValue },
                operators.sorted { $0.rawValue < $1.rawValue },
                code
            )
            XCTAssertEqual(schemata.filter { $0.syntaxMutation.trimmedDescription == mutant }.count, 1, code)
        }
    }

    // Without ReplaceNilCoalescing, as under `skipOperators`, the others keep their mutants.
    func test_aCoalescingWhoseFallbackIsTheValuesReplacement_keepsTheOthersMutantsWithoutReplaceNilCoalescing()
        async throws {
        let others = MutationOperatorList.allOperators.filter { $0 != .replaceNilCoalescing }
        let expected: [[MutationOperator.Id]] = [
            [.replaceReturnValue],
            [.replaceBooleanValue, .flipBooleanLiteral, .replaceBooleanValue],
            [.replaceReturnValue],
        ]
        for ((code, _), operators) in zip(coalescedValues, expected) {
            let schemata = try await schemata(discoveredIn: code, by: others)
            XCTAssertEqual(schemata.map(\.mutationOperatorId), operators, code)
        }
    }

    // A fallback other than the value's replacement is a mutant of its own.
    func test_aCoalescingWithAnotherFallback_keepsBothMutants() async throws {
        let code = "func f(n: () -> Int?) -> Int { return n() ?? 1 }\n"
        let schemata = try await schemata(discoveredIn: code, by: .allOperators)
        XCTAssertEqual(
            Set(schemata.map(\.mutationOperatorId)),
            [.replaceNilCoalescing, .replaceReturnValue],
            code
        )
    }

    // `--mutant` discovers every operator, and must still find the mutant a run without ReplaceNilCoalescing reported.
    func test_aMutantNamed_findsTheReplacedValueOfACoalescing() async throws {
        let returned = try await mutants(named: "1:39 ReplaceReturnValue", in: coalescedValues[0].code)
        XCTAssertEqual(returned.map(\.mutationOperatorId), [.replaceReturnValue])
        XCTAssertEqual(returned.map(\.snapshot.after), ["0"])

        let replaced = try await mutants(named: "1:53 ReplaceBooleanValue", in: coalescedValues[1].code)
        XCTAssertEqual(replaced.map(\.mutationOperatorId), [.replaceBooleanValue])
        XCTAssertEqual(replaced.map(\.snapshot.after), ["false"])
    }

    /// The mutants discovery finds in `code` with `list`, in the order of the file.
    private func schemata(discoveredIn code: String, by list: MutationOperatorList) async throws -> [MutationSchema] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).swift")
        try code.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        state.sourceFileCandidates = [file.path]
        state.mutationOperatorList = list
        state.apply(try await sut.run(with: state))
        return state.mutationMapping.flatMap(\.mutationSchemata)
    }
}
