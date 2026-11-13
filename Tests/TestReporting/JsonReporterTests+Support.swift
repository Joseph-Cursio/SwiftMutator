@testable import muterCore
import XCTest

extension JsonReporterTests {
    func topLevelKeys(of outcome: MutationTestOutcome) throws -> [String: Any] {
        let json = JsonReporter().report(from: outcome)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}
