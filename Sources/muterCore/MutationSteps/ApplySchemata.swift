import Foundation
import SwiftParser
import SwiftSyntax

struct ApplySchemata: MutationStep {
    @Dependency(\.writeFile)
    private var writeFile: WriteFile

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        for mutationMap in state.mutationMapping {
            // Mappings are keyed by code-block position and text (`CodeBlockKey`), so a
            // fresh parse of the file matches them as well as the discovery tree would.
            let sourceCode: SourceFileSyntax
            if let cached = state.sourceCodeByFilePath[mutationMap.filePath] {
                sourceCode = cached
            } else if let parsed = loadSourceCode(from: mutationMap.filePath) {
                sourceCode = parsed
            } else if mutationMap.isEmpty {
                continue
            } else {
                // Its mutants would still be tested, with no switch in the code: every one would survive.
                throw MuterError.literal(reason: Self.couldNotRead(mutationMap))
            }

            let newFile = await Self.onAStackOfItsOwn {
                MuterRewriter(mutationMap).visit(sourceCode).description
            }

            do {
                try writeFile(
                    newFile,
                    mutationMap.filePath
                )
            } catch {
                throw MuterError.literal(reason: error.localizedDescription)
            }
        }

        return []
    }

    /// Why a file with mutants that can't be read, or isn't UTF-8, stops the run.
    static func couldNotRead(_ mapping: SchemataMutationMapping) -> String {
        let count = mapping.mutationSchemata.count
        return """
        SwiftMutator could not read \(mapping.filePath), or it isn't UTF-8, so it could not insert the \
        \(count == 1 ? "switch of the mutant" : "switches of the \(count) mutants") it found there. Their tests would run without them, and every \
        one would survive.
        """
    }

    /// The bytes of stack a file's rewrite gets: room for tens of thousands of mutants in one list, where swiftc
    /// itself stops somewhere between 4,000 and 8,000.
    private static let rewriteStackSize = 64 << 20

    /// Runs `work` on a thread of its own, with a stack of `rewriteStackSize` bytes. Each mutant of a list is an
    /// `else if` inside the one before, and walking the rewritten file, as writing it out does, recurses once per
    /// level. The threads Swift concurrency runs this step on have stacks of about 512 KiB, which ran out at about
    /// 520 mutants in one list in a debug build, or about 4,500 in a release one: the run died with a bus error
    /// after discovery. `work` and what it returns cross to that thread and back, so they are Sendable.
    private static func onAStackOfItsOwn<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: work())
            }
            thread.stackSize = rewriteStackSize
            thread.start()
        }
    }

    private func loadSourceCode(from path: String) -> SourceFileSyntax? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let source = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return Parser.parse(source: source)
    }
}
