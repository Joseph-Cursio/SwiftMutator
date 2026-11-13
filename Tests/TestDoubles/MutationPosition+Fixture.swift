@testable import muterCore
import SwiftSyntax

extension MutationPosition: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init(
            sourceLocation: .init(integerLiteral: value)
        )
    }
}

extension SwiftSyntax.SourceLocation: @retroactive ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init(line: value, column: value, offset: value, file: "")
    }
}

extension MutationPosition {
    static var firstPosition: MutationPosition {
        MutationPosition(utf8Offset: 0, line: 0, column: 0)
    }
}
