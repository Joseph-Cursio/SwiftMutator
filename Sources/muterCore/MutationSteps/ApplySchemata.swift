import Foundation
import SwiftParser
import SwiftSyntax

struct ApplySchemata: MutationStep {
    @Dependency(\.writeFile)
    private var writeFile: WriteFile
    @Dependency(\.notificationCenter)
    private var notificationCenter: NotificationCenter

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
            } else {
                continue
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

    /// The bytes of stack a file's rewrite gets: room for tens of thousands of mutants in one list, where swiftc
    /// itself stops somewhere between 4,000 and 8,000.
    private static let rewriteStackSize = 64 << 20

    /// Runs `work` on a thread of its own, with a stack of `rewriteStackSize` bytes. Each mutant of a list is an
    /// `else if` inside the one before, and walking the rewritten file, as writing it out does, recurses once per
    /// level. The threads Swift concurrency runs this step on have stacks of about 512 KiB, which ran out at about
    /// 520 mutants in one list in a debug build, or about 4,500 in a release one: the run died with a bus error
    /// after discovery.
    private static func onAStackOfItsOwn<Value>(_ work: @escaping () -> Value) async -> Value {
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
