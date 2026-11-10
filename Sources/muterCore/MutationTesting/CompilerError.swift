import Foundation

/// A compile error parsed out of a compiler or test log: mostly `file:line:column: error: message`.
struct CompilerError: Hashable, Sendable {
    let filePath: String
    let line: Int
    let column: Int
    let message: String

    var fileName: String {
        filePath.lastPathComponent
    }

    var description: String {
        "\(fileName):\(line):\(column): error: \(message)"
    }
}
