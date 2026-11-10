import Foundation

/// Where a mutant comes in a session's jobs. Discovery sorts files by path (`mergeByFilePath`) and each file's mutants
/// by `InFile` (`SchemataMutationMapping.mutationSchemata`); a key's repeats come in the order they were found, which
/// their occurrences number. A results file holds mutants in the order they finished; this gives back the order the
/// run tested and reported them in.
struct JobOrder: Comparable {
    /// The absolute path, as discovery sorted it: a file outside the mutated project, whose path the results file
    /// keeps as it is, then keeps its place among the others.
    let filePath: String
    let inFile: InFile
    let occurrence: Int

    /// Where a mutant comes among its file's: by line and column, as numbers, then by operator. Not by switch ID,
    /// which holds them as text, so line 10 came before line 9, and whose format may change. Nor by offset, which
    /// counts the header and import SwiftMutator inserts: a result a resumed session kept holds the offset of the
    /// session that tested it, and the line and column, which don't move, fix the offset within a session anyway.
    struct InFile: Comparable {
        let line: Int
        let column: Int
        let mutationOperatorId: MutationOperator.Id

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.line, lhs.column, lhs.mutationOperatorId.rawValue)
                < (rhs.line, rhs.column, rhs.mutationOperatorId.rawValue)
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.filePath, lhs.inFile, lhs.occurrence) < (rhs.filePath, rhs.inFile, rhs.occurrence)
    }
}
