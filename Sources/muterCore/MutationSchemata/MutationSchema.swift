import Foundation
import SwiftParser
import SwiftSyntax

struct MutationSchema {
    /// What switches the mutant on (`MutationSwitch`): `<file name>_<path hash>_<operator>_<line>_<column>_<offset>`,
    /// the offset counting the header and import SwiftMutator inserts. The hash is of the file's path in the mutated
    /// project, so that same-named files, such as two executable targets' `main.swift`, don't share an ID: a test run
    /// switched a mutant on in each, and its verdict covered both. Being relative, it is the same wherever the
    /// project is. A test plan records the ID, since its code holds it.
    let id: String
    let filePath: String
    let mutationOperatorId: MutationOperator.Id
    let syntaxMutation: CodeBlockItemListSyntax
    let position: MutationPosition
    let snapshot: MutationOperator.Snapshot

    var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }

    /// `projectRoot` is the mutated project's folder, which the ID's path is relative to. Without it the path is the
    /// file's name, as in a test of one file.
    init(
        filePath: String,
        mutationOperatorId: MutationOperator.Id,
        syntaxMutation: CodeBlockItemListSyntax,
        position: MutationPosition,
        snapshot: MutationOperator.Snapshot,
        under projectRoot: URL? = nil
    ) {
        let path = projectRoot.map { RepoRelativePath.of(filePath, under: $0) }
            ?? URL(fileURLWithPath: filePath).lastPathComponent
        id = Self.id(of: filePath, pathHash: path.stableHash, mutationOperatorId, position)
        self.filePath = filePath
        self.mutationOperatorId = mutationOperatorId
        self.syntaxMutation = syntaxMutation
        self.position = position
        self.snapshot = snapshot
    }

    /// Without `pathHash`, the ID a SwiftMutator from before the hash gave the mutant: a test plan made by one records
    /// no ID, and its code switches on this.
    static func id(
        of filePath: String,
        pathHash: String?,
        _ mutationOperatorId: MutationOperator.Id,
        _ position: MutationPosition
    ) -> String {
        let fileName = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        return ([fileName] + [pathHash].compactMap { $0 } + [
            mutationOperatorId.rawValue,
            "\(position.line)",
            "\(position.column)",
            "\(position.utf8Offset)",
        ]).joined(separator: "_")
    }
}

extension MutationSchema: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try container.decode(String.self, forKey: .filePath)
        mutationOperatorId = try container.decode(MutationOperator.Id.self, forKey: .mutationOperatorId)
        syntaxMutation = CodeBlockItemListSyntax([])
        position = try container.decode(MutationPosition.self, forKey: .position)
        snapshot = try container.decode(MutationOperator.Snapshot.self, forKey: .snapshot)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? Self.id(of: filePath, pathHash: nil, mutationOperatorId, position)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(filePath, forKey: .filePath)
        try container.encode(mutationOperatorId, forKey: .mutationOperatorId)
        try container.encode(position, forKey: .position)
        try container.encode(snapshot, forKey: .snapshot)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case filePath
        case mutationOperatorId
        case position
        case snapshot
    }
}

extension MutationSchema: Nullable {
    static var null: MutationSchema {
        MutationSchema(
            filePath: "",
            mutationOperatorId: .ror,
            syntaxMutation: CodeBlockItemListSyntax([]),
            position: .null,
            snapshot: .null
        )
    }
}

extension MutationSchema: Equatable {
    static func == (lhs: MutationSchema, rhs: MutationSchema) -> Bool {
        lhs.id == rhs.id &&
            lhs.filePath == rhs.filePath &&
            lhs.mutationOperatorId == rhs.mutationOperatorId &&
            lhs.syntaxMutation.description == rhs.syntaxMutation.description &&
            lhs.position == rhs.position &&
            lhs.snapshot == rhs.snapshot
    }
}

extension MutationSchema: CustomStringConvertible, CustomDebugStringConvertible {
    var debugDescription: String { description }

    var description: String {
        """
        Schemata(
            id: "\(id)",
            filePath: "\(filePath)",
            mutationOperatorId: .\(mutationOperatorId),
            syntaxMutation: "\(syntaxMutation.escapedDescription)",
            position: \(position.debugDescription),
            snapshot: \(snapshot.debugDescription)
        )
        """
    }
}

extension MutationSchema {
    /// Where the mutant comes among its file's in mutation testing's jobs.
    var orderInFile: JobOrder.InFile {
        JobOrder.InFile(line: position.line, column: position.column, mutationOperatorId: mutationOperatorId)
    }
}

struct MutationPoint: Equatable, Codable {
    let mutationOperatorId: MutationOperator.Id
    let filePath: String
    let position: MutationPosition

    var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

extension MutationPoint: Nullable {
    static var null: MutationPoint {
        MutationPoint(
            mutationOperatorId: .removeSideEffects,
            filePath: "",
            position: .null
        )
    }
}
