import SwiftSyntax

public extension SourceFileSyntax {
    /// A source file with nothing in it.
    static func makeBlankSourceFile() -> Self {
        SourceFileSyntax(
            statements: CodeBlockItemListSyntax([]),
            endOfFileToken: .endOfFileToken()
        )
    }
}
