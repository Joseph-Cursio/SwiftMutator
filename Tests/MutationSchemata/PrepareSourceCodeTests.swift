@testable import muterCore
import TestingExtensions
import XCTest

final class PrepareSourceCodeTests: MuterTestCase {
    private lazy var outputFilePath = fixturesDirectory + "/preparedSourceCode.swift"

    override func setUpWithError() throws {
        try super.setUpWithError()

        let contents = Data("""
        func foo() {
            true && false
        }
        """.utf8)

        FileManager.default.createFile(
            atPath: outputFilePath,
            contents: contents
        )
    }

    override func setUp() {
        super.setUp()

        current.writeFile = { try $0.write(toFile: $1, atomically: true, encoding: .utf8) }
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()

        try FileManager.default.removeItem(atPath: outputFilePath)
    }

    func test_prepareSourceCode() throws {
        let sut = try XCTUnwrap(PrepareSourceCode().prepareSourceCode(outputFilePath))

        AssertSnapshot(formatCode(sut.source.code.description))
    }

    // A file coverage leaves out is walked for the mutants it would have, at the same lines and columns, but nothing is
    // made of them in the copy, so it stays as it was.
    func test_withoutWriting_givesTheSameCode_andLeavesTheFileAsItWas() throws {
        let original = try String(contentsOfFile: outputFilePath, encoding: .utf8)
        let read = try XCTUnwrap(PrepareSourceCode().prepareSourceCode(outputFilePath, writing: false))

        XCTAssertEqual(try String(contentsOfFile: outputFilePath, encoding: .utf8), original)
        let written = try XCTUnwrap(PrepareSourceCode().prepareSourceCode(outputFilePath))
        XCTAssertEqual(read.source.code.description, written.source.code.description)
        XCTAssertEqual(read.changes, written.changes)
        XCTAssertEqual(read.source.path, outputFilePath)
    }
}
