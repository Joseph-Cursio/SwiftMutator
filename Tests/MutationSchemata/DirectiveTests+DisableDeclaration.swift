@testable import muterCore
import XCTest

extension DirectiveTests {
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
}
