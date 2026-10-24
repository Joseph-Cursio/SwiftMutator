import Foundation
@testable import muterCore
import XCTest

final class MutationSchemaTests: XCTestCase {
    private let mutatedRoot = URL(fileURLWithPath: "/project_mutated")
    private let position = MutationPosition(utf8Offset: 40, line: 3, column: 5)

    // Each executable target has its own `main.swift`. Named by the file's name alone, a mutant in each at one place
    // had one ID, and a test run switched both on.
    func test_sameNamedFilesInTwoFolders_haveIDsOfTheirOwn() throws {
        let first = try MutationSchema.make(
            filePath: "/project_mutated/First/Sources/main.swift",
            position: position,
            under: mutatedRoot
        )
        let second = try MutationSchema.make(
            filePath: "/project_mutated/Second/Sources/main.swift",
            position: position,
            under: mutatedRoot
        )

        XCTAssertEqual(first.id, "main_b330b3005aaa8181_RelationalOperatorReplacement_3_5_40")
        XCTAssertEqual(second.id, "main_c6072ceae280262d_RelationalOperatorReplacement_3_5_40")
    }

    // The hash is of the path in the project, so the rewritten code is the same on every machine.
    func test_theIDIsTheSameWhereverTheProjectIs() throws {
        let here = try MutationSchema.make(
            filePath: "/project_mutated/First/Sources/main.swift",
            position: position,
            under: mutatedRoot
        )
        let elsewhere = try MutationSchema.make(
            filePath: "/Users/me/code/project_mutated/First/Sources/main.swift",
            position: position,
            under: URL(fileURLWithPath: "/Users/me/code/project_mutated")
        )

        XCTAssertEqual(here.id, elsewhere.id)
    }

    func test_aTestPlanRecordsEachID() throws {
        let schema = try MutationSchema.make(
            filePath: "/project_mutated/First/Sources/main.swift",
            position: position,
            under: mutatedRoot
        )

        let decoded = try JSONDecoder().decode(MutationSchema.self, from: JSONEncoder().encode(schema))

        XCTAssertEqual(decoded.id, schema.id)
    }

    // A plan made before the hash records no ID, and its code switches each mutant on by the file's name alone.
    func test_aTestPlanFromBeforeTheHash_switchesOnWhatItsCodeHolds() throws {
        let schema = try MutationSchema.make(
            filePath: "/project_mutated/First/Sources/main.swift",
            position: position,
            under: mutatedRoot
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any])
        json["id"] = nil

        let decoded = try JSONDecoder().decode(MutationSchema.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(decoded.id, "main_RelationalOperatorReplacement_3_5_40")
    }
}
