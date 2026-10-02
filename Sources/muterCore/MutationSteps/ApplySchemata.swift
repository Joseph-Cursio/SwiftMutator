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
            // Prefer the tree the mappings were discovered in: they are keyed by
            // node identity, so a re-parsed tree would match none of them and the
            // file would be written back without any mutation switches.
            let sourceCode: SourceFileSyntax
            if let cached = state.sourceCodeByFilePath[mutationMap.filePath] {
                sourceCode = cached
            } else if let discovered = mutationMap.sourceFile {
                sourceCode = discovered
            } else if let parsed = loadSourceCode(from: mutationMap.filePath) {
                sourceCode = parsed
            } else {
                continue
            }

            let rewriter = MuterRewriter(mutationMap)

            let newFile = rewriter.visit(sourceCode)

            do {
                try writeFile(
                    newFile.description,
                    mutationMap.filePath
                )
            } catch {
                throw MuterError.literal(reason: error.localizedDescription)
            }
        }

        return []
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
