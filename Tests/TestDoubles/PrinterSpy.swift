import Foundation
@testable import muterCore

// A test sets it up, then the code under test uses it from one task at a time, so it needs no lock.
final class PrinterSpy: @unchecked Sendable {
    private(set) var linesPassed: [String] = []

    func print(_ line: String) {
        linesPassed.append(line)
    }
}
