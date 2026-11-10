@testable import muterCore
import XCTest

extension XCTestCase {
    /// The Tests folder of this checkout.
    var rootTestDirectory: String {
        String(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .withoutScheme()
        )
    }

    /// The fixtures the tests read.
    var fixturesDirectory: String { "\(rootTestDirectory)/fixtures" }
    /// The fixtures' example sources to mutate.
    var mutationExamplesDirectory: String { "\(fixturesDirectory)/MutationExamples" }
}
