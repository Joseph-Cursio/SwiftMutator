@testable import muterCore
import SnapshotTesting
import SwiftSyntax
import TestingExtensions
import XCTest

extension RemoveSideEffectsOperatorTests {
    // A builder that takes no `if` gets no mutant, its lowercase parts included, as no mutant's switch builds there.
    func test_neverRemovesFromABuilderThatTakesNoIf() throws {
        let removed = try removedStatements(in: buildersThatTakeNoIf)

        // Only `find`'s own statements, which are a plain function's.
        XCTAssertEqual(removed, [
            "_ = line.firstMatch { digits() sign() }", "_ = line.replacing { sign() digits() } with: { _ in \"\" }",
        ])
    }

    /// Bodies of builders that take no `if` (scenes, widgets, shortcuts, regexes), and a plain function beside them.
    private var buildersThatTakeNoIf: String {
        """
        struct Demo: App {
            var body: some Scene {
                mainWindow()
                Group {
                    settings()
                    extras()
                }
            }
        }

        struct Bundle: WidgetBundle {
            var body: some Widget {
                clock()
                weather()
            }
        }

        struct Shortcuts: AppShortcutsProvider {
            static var appShortcuts: [AppShortcut] {
                open()
                search()
            }
        }

        struct Parser {
            @RegexComponentBuilder
            var number: some RegexComponent {
                sign()
                digits()
            }

            @RegexComponentBuilder
            var pattern: Regex<Substring> {
                sign()
                digits()
            }

            @SceneBuilder
            subscript(index: Int) -> some Scene {
                window(index)
                settings()
            }

            func find(_ line: String) {
                _ = line.firstMatch {
                    digits()
                    sign()
                }
                _ = line.replacing {
                    sign()
                    digits()
                } with: { _ in "" }
            }

            func parse(_ line: String) -> Bool {
                let separator = Regex {
                    spaces()
                    ","
                    spaces()
                }
                return line.wholeMatch {
                    number()
                    separator
                    number()
                } != nil
            }
        }
        """
    }

    // These only look like a builder's parts: a method of a value a type holds, a `Task`, the calls of a `some` body
    // that returns a value, a closure called as a statement, and one whose code merely names a regex type.
    func test_removesCallsThatOnlyLookLikeABuildersParts() throws {
        let removed = try removedStatements(
            in: """
            func save(_ items: [Int]) async throws {
                items.forEach { item in
                    persist(item)
                    NotificationCenter.default.post(name: .saved, object: nil)
                }
                items.forEach { item in
                    Task { await sync(item) }
                    log(item)
                }
                try {
                    try load()
                    refresh()
                }()
                await {
                    await sync(1)
                    finish()
                }()
                _ = {
                    prepare()
                    flush()
                }()
                let limit: Int = {
                    configure()
                    reload()
                    return Mode.One.rawValue
                }()
                use(limit)
            }

            func makeIterator() -> some IteratorProtocol<Int> {
                Metrics.record("iterate")
                return storage.makeIterator()
            }
            """
        )

        XCTAssertEqual(removed, [
            "persist(item)", "NotificationCenter.default.post(name: .saved, object: nil)",
            "items.forEach { item in persist(item) NotificationCenter.default.post(name: .saved, object: nil) }",
            "Task { await sync(item) }", "log(item)", "items.forEach { item in Task { await sync(item) } log(item) }",
            "try load()", "refresh()", "try { try load() refresh() }()", "await sync(1)", "finish()",
            "await { await sync(1) finish() }()", "prepare()", "flush()", "_ = { prepare() flush() }()", "configure()",
            "reload()", "use(limit)",
            "Metrics.record(\"iterate\")",
        ])
    }

    func test_neverRemovesFromAFilesTopLevel_orAnIfConfigClause() throws {
        let removed = try removedStatements(
            in: """
            setUp()

            func run() {
                #if DEBUG
                trace()
                #endif
                work()
            }
            """
        )

        XCTAssertEqual(removed, ["work()"])
    }
}
