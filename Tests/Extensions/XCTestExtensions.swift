import Difference
@testable import muterCore
import SnapshotTesting
import XCTest

/// Asserts that two values are equal, and on failure lists the differences between them.
public func XCTAssertEqual<T: Equatable>(
    _ expected: @autoclosure () throws -> T,
    _ received: @autoclosure () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let expectedValue = try expected()
        let receivedValue = try received()
        XCTAssertEqual(
            expectedValue,
            receivedValue,
            "Found difference for \n" + diff(expectedValue, receivedValue).joined(separator: ", "),
            file: file,
            line: line
        )
    } catch {
        XCTFail("Caught error while testing: \(error)", file: file, line: line)
    }
}

/// Asserts that an optional Boolean expression is true, failing when it is nil.
public func XCTAssertTrue(
    // swiftlint:disable:next discouraged_optional_boolean - the overload exists to fail on a nil Bool
    _ expression: @autoclosure () throws -> Bool?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let actual = try? expression() else {
        XCTFail("Expected boolean, got nil")
        return
    }

    XCTAssertTrue(actual, message(), file: file, line: line)
}

/// Asserts that an optional Boolean expression is false, failing when it is nil.
public func XCTAssertFalse(
    // swiftlint:disable:next discouraged_optional_boolean - the overload exists to fail on a nil Bool
    _ expression: @autoclosure () throws -> Bool?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let actual = try? expression() else {
        XCTFail("Expected boolean, got nil")
        return
    }

    XCTAssertFalse(actual, message(), file: file, line: line)
}

/// Asserts that a value is not nil and is exactly of the given type.
public func XCTAssertTypeEqual(
    _ lhs: Any?,
    _ rhs: (some Any).Type,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let lhs else {
        XCTFail("First argument should not be nil", file: file, line: line)
        return
    }

    if type(of: lhs) != rhs {
        XCTFail("Expected \(rhs), got \(type(of: lhs))", file: file, line: line)
    }
}

/// Asserts that a string matches its recorded line-by-line snapshot.
public func AssertSnapshot( // swiftlint:disable:this identifier_name - capitalized like the XCTAssert functions
    _ matching: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    testName: String = #function
) {
    assertSnapshot(
        of: matching,
        as: .lines,
        file: file,
        testName: testName,
        line: line
    )
}

/// Asserts that an async expression throws, and passes the error to `errorHandler`.
public func AssertThrowsError( // swiftlint:disable:this identifier_name - capitalized like XCTAssertThrowsError
    _ expression: @autoclosure () async throws -> some Any,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: Error) throws -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        do {
            try errorHandler(error)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }
}
