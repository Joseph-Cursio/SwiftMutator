import SwiftSyntax

public extension SourceFileSyntax {
    /// Makes a source file with no statements.
    static func makeBlankSourceFile() -> Self {
        SourceFileSyntax(
            statements: CodeBlockItemListSyntax([]),
            endOfFileToken: .endOfFileToken()
        )
    }
}
