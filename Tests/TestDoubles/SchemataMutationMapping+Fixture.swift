import Foundation
@testable import muterCore

typealias SchemataMutationMappings = (source: String, schemata: MutationSchemata)

extension SchemataMutationMapping {
    static func make(
        _ mappings: SchemataMutationMappings...,
        filePath: String = ""
    ) throws -> SchemataMutationMapping {
        var schemataMutationMapping = SchemataMutationMapping(filePath: filePath)

        for (source, schemata) in mappings {
            let codeBlockSyntax = try sourceCode(source).statements

            for schema in schemata {
                schemataMutationMapping.add(codeBlockSyntax, schema)
            }
        }

        return schemataMutationMapping
    }
}

extension MutationSchema {
    static func make(
        filePath: String = "",
        mutationOperatorId: MutationOperator.Id = .ror,
        syntaxMutation: String = "",
        position: MutationPosition = .null,
        snapshot: MutationOperator.Snapshot = .null,
        under projectRoot: URL? = nil
    ) throws -> MutationSchema {
        try MutationSchema(
            filePath: filePath,
            mutationOperatorId: mutationOperatorId,
            syntaxMutation: sourceCode(syntaxMutation).statements,
            position: position,
            snapshot: snapshot,
            under: projectRoot
        )
    }
}
