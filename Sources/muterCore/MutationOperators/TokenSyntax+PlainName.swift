import SwiftSyntax

extension TokenSyntax {
    /// The name this token gives, without the backticks around one written as `` `Type` ``.
    var plainName: String {
        text.filter { $0 != "`" }
    }
}
