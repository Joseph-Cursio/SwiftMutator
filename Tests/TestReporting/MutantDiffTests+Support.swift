@testable import muterCore
import SwiftParser

extension MutantDiffTests {
    func schemata(_ visitor: VisitorInitializer, in source: String) -> [MutationSchema] {
        let code = Parser.parse(source: source)
        let walker = visitor(nil, SourceCodeInfo(path: "/project/Sources/File.swift", code: code), .empty)
        walker.walk(code)
        return walker.schemataMappings.mutationSchemata
    }

    func diff(of schema: MutationSchema, in source: String) -> [String]? {
        MutantDiff.lines(
            original: source,
            snapshot: schema.snapshot,
            mutationOperatorId: schema.mutationOperatorId,
            line: schema.position.line,
            column: schema.position.column
        )
    }
}
