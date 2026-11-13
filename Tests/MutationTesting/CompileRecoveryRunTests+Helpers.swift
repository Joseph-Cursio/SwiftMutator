@testable import muterCore
import XCTest

extension CompileRecoveryRunTests {
    func recordEvents(named names: [RunEvent.Name]) -> () -> [RunEvent] {
        var sent: [RunEvent] = []
        for name in names {
            let observer = runEvents.observe(name) { sent.append($0) }
            addTeardownBlock { observer.cancel() }
        }
        return { sent }
    }

    func errorLog(for id: String) throws -> String {
        try errorLine(for: id) + "\nerror: fatalError\n"
    }

    func errorLine(for id: String) throws -> String {
        let place = try branchPlace(of: id, in: rewritten)
        return "\(path):\(place.line):\(place.column): error: no such operator '\(id)'"
    }

    func branchPlace(of id: String, in code: String) throws -> (line: Int, column: Int) {
        let idRange = try XCTUnwrap(code.range(of: "\"\(id)\"] != nil"), code)
        let brace = try XCTUnwrap(code[idRange.upperBound...].firstIndex(of: "{"), code)
        let condition = brace ..< code.index(after: brace)
        let start = try XCTUnwrap(code[condition.upperBound...].firstIndex { !$0.isWhitespace && !$0.isNewline })
        let before = code[..<start].utf8
        let lineStart = before.lastIndex(of: UInt8(ascii: "\n")).map { before.index(after: $0) } ?? before.startIndex
        return (
            before.count { $0 == UInt8(ascii: "\n") } + 1,
            before.distance(from: lineStart, to: before.endIndex) + 1
        )
    }
}
