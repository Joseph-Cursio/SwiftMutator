import ArgumentParser
@testable import muterCore
import XCTest

extension RunCommandTests {
    /// Checks that parsing `arguments` fails validation with `message`.
    func assertUsageError(
        _ arguments: [String],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(arguments), file: file, line: line) { error in
            XCTAssertEqual(MuterCommand.exitCode(for: error), .validationFailure, file: file, line: line)
            XCTAssertEqual(MuterCommand.message(for: error), message, file: file, line: line)
        }
    }
}
