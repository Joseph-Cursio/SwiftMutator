import Foundation

/// A run's coverage, as its report shows it.
struct CoverageSummary: Codable, Equatable {
    let percent: Int
    let filesWithoutCoverage: [String]
}
