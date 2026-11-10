@testable import muterCore
import SwiftParser
import XCTest

extension CompileRecoveryTests {
    var builderError: String { "closure containing control flow statement cannot be used with result builder 'Sum'" }

    struct File {
        let mapping: SchemataMutationMapping
        let prepared: String
        let rewritten: String
        let path: String
        var ids: [String] { mapping.mutationSchemata.map(\.id) }
    }

    func file(_ code: String, at filePath: String? = nil) throws -> File {
        let mutatedFile = filePath ?? path
        let source = SourceCodeInfo(path: mutatedFile, code: Parser.parse(source: code))
        let mapping = try XCTUnwrap(generateSchemataMappings(for: source).first)
        XCTAssertGreaterThan(mapping.mutationSchemata.count, 1)
        return File(
            mapping: mapping,
            prepared: code,
            rewritten: MuterRewriter(mapping).visit(source.code).description,
            path: mutatedFile
        )
    }

    func assertBranch(
        of id: String,
        at place: (line: Int, column: Int),
        in file: File,
        fileName: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .branch(found, chain) = locator(file).place(line: place.line, column: place.column) else {
            XCTFail(file.rewritten, file: fileName, line: line)
            return
        }
        XCTAssertEqual(found, id, file: fileName, line: line)
        XCTAssertEqual(Set(chain), Set(file.ids), file: fileName, line: line)
    }

    func locator(_ file: File) -> MutantLocator {
        MutantLocator(rewritten: file.rewritten, filePath: file.path)
    }

    func recovery(of file: File) throws -> CompileRecovery {
        state.mutationMapping = [file.mapping]
        state.preparedSources = [file.path: file.prepared]
        return try XCTUnwrap(CompileRecovery(of: state))
    }

    /// The range of the first token of `id`'s branch.
    func branchBody(of id: String, in code: String) throws -> Range<String.Index> {
        let idRange = try XCTUnwrap(code.range(of: "\"\(id)\"] != nil"), code)
        let brace = try XCTUnwrap(code[idRange.upperBound...].firstIndex(of: "{"), code)
        let condition = brace ..< code.index(after: brace)
        let start = try XCTUnwrap(code[condition.upperBound...].firstIndex { !$0.isWhitespace && !$0.isNewline }, code)
        return start ..< code.index(after: start)
    }

    /// The line and column of `range`'s start, as the compiler prints them: columns in UTF-8 bytes.
    func place(of range: Range<String.Index>, in code: String) -> (line: Int, column: Int) {
        let before = code[..<range.lowerBound].utf8
        let lastLineBreak = before.lastIndex(of: UInt8(ascii: "\n"))
        let lineStart = lastLineBreak.map { before.index(after: $0) } ?? before.startIndex
        return (
            before.count { $0 == UInt8(ascii: "\n") } + 1,
            before.distance(from: lineStart, to: before.endIndex) + 1
        )
    }

    func error(atBranchOf id: String, in file: File, saying message: String) throws -> String {
        let place = place(of: try branchBody(of: id, in: file.rewritten), in: file.rewritten)
        return "\(file.path):\(place.line):\(place.column): error: \(message)"
    }
}
