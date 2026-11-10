import Foundation
import Yams

extension BaselineFile {
    private struct Saved: Encodable {
        let formatVersion: Int
        let swiftMutator: String
        let score: Score
        let scope: SavedScope
        let survivors: [SavedSurvivor]
    }

    private struct SavedScope: Encodable {
        let operators: [String]
        let skipCoverage: Bool
        let configuration: SavedConfiguration
    }

    private struct SavedConfiguration: Encodable {
        let arguments: [String]
        let buildSystem: String?
        let coverageThreshold: WrittenNumber
        let exclude: [String]
        let excludeCalls: [String]
        let mutationTestTimeout: WrittenNumber?
    }

    private struct SavedSurvivor: Encodable {
        let mutant: String
        let outcome: String
        let before: String
        let after: String
        let line: String?
    }

    /// A number as YAML writes it in plain digits, as a person would (`ScoreGate.shown`): 60, 72.5; never 6e+1.
    private struct WrittenNumber: Encodable, YAMLEncodable {
        let value: Double

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(Decimal(string: ScoreGate.shown(value)) ?? Decimal(value))
        }

        func box() -> Node {
            Node(ScoreGate.shown(value), Tag(value == value.rounded() ? .int : .float))
        }
    }

    /// Its survivors by path, line, column, operator and repeat, so a commit's diff shows only what changed.
    var sortedSurvivors: [BaselineSurvivor] {
        survivors.sorted { $0.mutant.comesBefore($1.mutant) }
    }

    /// The file as YAML, after `introduction`: the keys in the order a reader wants them, the survivors sorted.
    func yaml() throws -> String {
        let configuration = scope.configuration
        let saved = Saved(
            formatVersion: formatVersion,
            swiftMutator: swiftMutator,
            score: score,
            scope: .init(
                operators: scope.operators,
                skipCoverage: scope.skipCoverage,
                configuration: .init(
                    arguments: configuration.arguments,
                    buildSystem: configuration.buildSystem,
                    coverageThreshold: WrittenNumber(value: configuration.coverageThreshold),
                    exclude: configuration.exclude,
                    excludeCalls: configuration.excludeCalls,
                    mutationTestTimeout: configuration.mutationTestTimeout.map(WrittenNumber.init)
                )
            ),
            survivors: sortedSurvivors.map {
                .init(
                    mutant: $0.mutant.description,
                    outcome: $0.outcome.rawValue,
                    before: $0.before,
                    after: $0.after,
                    line: $0.line
                )
            }
        )
        // Each value on one line, however long, so that a changed line of code changes one line of the file's diff.
        let encoder = YAMLEncoder()
        encoder.options.width = -1
        return Self.introduction + "\n" + (try encoder.encode(saved))
    }

    /// Saves it at `path`, `~` expanded, making any folder on the way that isn't there, as a report is saved
    /// (`ReportWriter.save`); says whether it was saved.
    func save(using fileManager: FileSystemManager) -> Bool {
        guard let text = try? yaml() else { return false }
        return ReportWriter.save(text, to: URL.expandingTilde(path), using: fileManager)
    }
}
