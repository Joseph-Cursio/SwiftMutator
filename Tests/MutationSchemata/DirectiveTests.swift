@testable import muterCore
import XCTest

/// A directive is `muter:` and its word, first in a comment of any kind. `disable-next-line` leaves out the line after
/// its own, and `disable-declaration` the declaration it is above or beside.
final class DirectiveTests: MuterTestCase {
    private func changes(in code: String, by id: MutationOperator.Id = .flipBooleanLiteral) throws -> [String] {
        let source = try sourceCode(code)
        let visitor = id.visitor(nil, .init(path: "/path/to/file", code: source), .empty)
        visitor.walk(source)
        return visitor.schemataMappings.mutationSchemata
            .map { "\($0.position.line) \($0.snapshot.description)" }
            .sorted()
    }

    private func lines(in code: String, by id: MutationOperator.Id = .flipBooleanLiteral) throws -> [Int] {
        try changes(in: code, by: id).compactMap { Int($0.prefix { $0 != " " }) }.sorted()
    }

    // MARK: - Where a directive is read

    func test_aDirective_isReadInEveryKindOfComment() throws {
        for comment in [
            "// muter:disable", "/// muter:disable", "/* muter:disable */", "/** muter:disable */",
            "//muter:disable", "/*muter:disable*/", "// muter:disable because it's generated",
        ] {
            let code = "func f() {\n    g(true)\n    \(comment)\n    g(true)\n}"
            XCTAssertEqual(try lines(in: code), [2], comment)
        }
    }

    // A comment that only mentions one used to turn off the rest of the file.
    func test_aCommentThatOnlyMentionsADirective_doesNothing() throws {
        for comment in [
            "// see muter:disable", "// TODO: muter:disable", "/* uses muter:disable */",
            "// muter:disabled", "// muter:disable-everything", "// muter:disable:next",
        ] {
            let code = "func f() {\n    \(comment)\n    g(true)\n}"
            XCTAssertEqual(try lines(in: code), [3], comment)
        }
    }

    // MARK: - disable-next-line

    func test_disableNextLine_leavesOutTheNextLineAlone() throws {
        let code = """
        func f() {
            g(true)
            // muter:disable-next-line
            g(true, true)
            g(true)
        }
        """
        XCTAssertEqual(try lines(in: code), [2, 5])
    }

    func test_disableNextLine_besideCode_leavesOutTheLineAfterIt() throws {
        let code = """
        func f() {
            g(true) // muter:disable-next-line
            g(true)
            g(true)
        }
        """
        XCTAssertEqual(try lines(in: code), [2, 4])
    }

    func test_disableNextLine_leavesOutAStatementThatStartsThere_whereverItEnds() throws {
        let code = """
        func f() {
            // muter:disable-next-line
            work(
                1
            )
            work(2)
        }
        """
        XCTAssertEqual(try changes(in: code, by: .removeSideEffects).count, 1)
    }

    func test_disableNextLine_aboveABlankLine_leavesOutNothing() throws {
        let code = "func f() {\n    // muter:disable-next-line\n\n    g(true)\n}"
        XCTAssertEqual(try lines(in: code), [4])
    }

    func test_disableNextLine_onTheLastLine_leavesOutNothing() throws {
        let code = "func f() {\n    g(true)\n}\n// muter:disable-next-line"
        XCTAssertEqual(try lines(in: code), [2])
    }

    // MARK: - disable-declaration

    func test_disableDeclaration_leavesOutTheFunctionBelow_andNothingAfter() throws {
        let code = """
        // muter:disable-declaration
        func f() {
            g(true)
        }

        func h() {
            g(true)
        }
        """
        XCTAssertEqual(try lines(in: code), [7])
    }

    func test_disableDeclaration_seesPastDocCommentsAttributesAndModifiers() throws {
        for header in [
            "/// Does f.\n// muter:disable-declaration\n@MainActor public func f() {",
            "// muter:disable-declaration\n/// Does f.\n@MainActor public func f() {",
            "@MainActor\n// muter:disable-declaration\npublic func f() {",
            "@MainActor public\n// muter:disable-declaration\nfunc f() {",
        ] {
            let code = "\(header)\n    g(true)\n}\n\nfunc h() {\n    g(true)\n}"
            XCTAssertEqual(try changes(in: code).count, 1, header)
        }
    }

    func test_disableDeclaration_leavesOutATypesMembers() throws {
        let code = """
        // muter:disable-declaration
        struct S {
            var a = true
            func f() { g(true) }
        }
        extension S {
            func h() { g(true) }
        }
        """
        XCTAssertEqual(try lines(in: code), [7])
    }

    func test_disableDeclaration_leavesOutOneMember() throws {
        let code = """
        struct S {
            var a = true
            // muter:disable-declaration
            var b: Bool { g(true) }
            init() { g(true) }
            // muter:disable-declaration
            subscript(i: Int) -> Bool { g(true) }
        }
        """
        XCTAssertEqual(try lines(in: code), [2, 5])
    }

    func test_disableDeclaration_besideCode_leavesOutTheDeclarationOnThatLine() throws {
        let code = """
        func f() { // muter:disable-declaration
            g(true)
        }
        let a = true // muter:disable-declaration
        let b = true
        """
        XCTAssertEqual(try lines(in: code), [5])
    }

    func test_disableDeclaration_aboveALocalDeclaration_leavesOutThatOne() throws {
        let code = """
        func f() {
            // muter:disable-declaration
            let a = items.map { g(true) }
            g(true)
        }
        """
        XCTAssertEqual(try lines(in: code), [4])
    }

    func test_disableDeclaration_aboveAStatement_leavesOutThatStatement() throws {
        let code = """
        func f() {
            // muter:disable-declaration
            if a {
                g(true)
            }
            g(true)
        }
        """
        XCTAssertEqual(try lines(in: code), [6])
    }

    func test_disableDeclaration_aboveAnIfConfig_leavesOutAllOfIt() throws {
        let code = """
        // muter:disable-declaration
        #if os(macOS)
        func f() { g(true) }
        #else
        func f() { g(true) }
        #endif
        func h() { g(true) }
        """
        XCTAssertEqual(try lines(in: code), [7])
    }

    func test_aDisableInsideADisabledDeclaration_stillRunsToItsEnable() throws {
        let code = """
        // muter:disable-declaration
        func f() {
            // muter:disable
            g(true)
        }
        func h() { g(true) }
        // muter:enable
        func k() { g(true) }
        """
        XCTAssertEqual(try lines(in: code), [8])
    }

    func test_disableDeclaration_coversEveryOperator() throws {
        let code = """
        // muter:disable-declaration
        func f(a: Int, b: Bool) -> Int {
            if a == 1 && b { work() }
            let c = b ? a + 1 : a - 1
            return c
        }
        """
        for id in MutationOperator.Id.allCases {
            XCTAssertEqual(try changes(in: code, by: id), [], "\(id)")
        }
    }

    // MARK: - What the review found

    func test_disableDeclaration_aboveTheFirstOfAList_leavesOutThatOneAlone() throws {
        let cases = """
        func f(x: E) {
            switch x {
            // muter:disable-declaration
            case .a: g(true)
            case .b: g(true)
            }
        }
        """
        XCTAssertEqual(try lines(in: cases), [5])

        let elements = """
        let rules = [
            // muter:disable-declaration
            Rule(on: true),
            Rule(on: true),
        ]
        """
        XCTAssertEqual(try lines(in: elements), [4])

        let arguments = """
        func f() {
            g(
                // muter:disable-declaration
                true,
                true
            )
        }
        """
        XCTAssertEqual(try lines(in: arguments), [5])
    }

    func test_aDisableBesideTheLastElement_leavesTheEarlierOnesOn() throws {
        let code = """
        func f() {
            g([
                true,
                true, // muter:disable
            ])
        }
        """
        XCTAssertEqual(try lines(in: code), [3])
    }

    func test_disableDeclaration_seesPastAnIfConfigAmongTheAttributes() throws {
        for header in [
            "// muter:disable-declaration\n#if canImport(UIKit)\n@MainActor\n#endif\nfunc f() {",
            "#if canImport(UIKit)\n// muter:disable-declaration\n@MainActor\n#endif\nfunc f() {",
        ] {
            let code = "\(header)\n    g(true)\n}\n\nfunc h() {\n    g(true)\n}"
            XCTAssertEqual(try changes(in: code).count, 1, header)
        }
    }

    func test_disableDeclaration_besideCode_coversTheWholeLine() throws {
        let defaultArgument = """
        func f(flag: Bool = true) { // muter:disable-declaration
            g(true)
        }
        func h() { g(true) }
        """
        XCTAssertEqual(try lines(in: defaultArgument), [4])

        let multilineString = """
        func f() {
            let message = \"\"\"
                total \\(g(true))
                \"\"\" // muter:disable-declaration
            g(true)
        }
        """
        XCTAssertEqual(try lines(in: multilineString), [5])
    }

    func test_disableNextLine_aboveATernarysBranches_leavesOutItsSwap() throws {
        let code = """
        func f(flag: Bool) -> Int {
            let x = flag
                // muter:disable-next-line
                ? 1 : 2
            return flag ? 1 : 2
        }
        """
        XCTAssertEqual(try lines(in: code, by: .swapTernary), [5])
    }

    func test_codeADirectiveLeavesOut_isNotCountedAsDropped() throws {
        let code = """
        // muter:disable-declaration
        func f() { g(true) }
        func h() {
            // muter:disable-next-line
            g(true)
            g(true)
        }
        """
        let source = try sourceCode(code)
        let visitor = MutationOperator.Id.flipBooleanLiteral
            .visitor(nil, .init(path: "/path/to/file", code: source), .empty)
        visitor.inactiveRegions = [source.position ..< source.endPosition]
        visitor.walk(source)
        XCTAssertEqual(visitor.droppedMutants.map(\.position.line), [6])
    }
}
