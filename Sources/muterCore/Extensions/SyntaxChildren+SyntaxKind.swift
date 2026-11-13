import SwiftSyntax

extension SyntaxChildren {
    var asArray: [Element] {
        Array(self)
    }

    func containsSyntaxKind(_ syntax: (some SyntaxProtocol).Type) -> Bool {
        asArray.containsSyntaxKind(syntax)
    }
}

extension [Syntax] {
    func containsSyntaxKind<A: SyntaxProtocol>(_: A.Type) -> Bool {
        contains { $0.is(A.self) }
    }
}

extension SyntaxProtocol {
    var allChildren: SyntaxChildren {
        children(viewMode: .all)
    }
}
