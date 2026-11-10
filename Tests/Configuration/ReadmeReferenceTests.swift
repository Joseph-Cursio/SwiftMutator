import ArgumentParser
@testable import muterCore
import XCTest

/// README.md is the user guide, and its reference sections must keep up with the code: every configuration key is a
/// row of the Configuration table, and every command has a subsection of Commands and flags that names each of its
/// flags and no other (#124).
final class ReadmeReferenceTests: MuterTestCase {
    func test_everyConfigurationKey_isARowOfTheConfigurationTable() throws {
        let lines = try section("Configuration").split(separator: "\n")
        let header = try XCTUnwrap(
            lines.firstIndex { $0.hasPrefix("| Key |") },
            "README.md's Configuration section has no table of keys."
        )
        let table = lines[header...].prefix { $0.hasPrefix("|") }
        let rows = Set(table.compactMap(Self.keyOfRow))
        let keys = MuterConfiguration.CodingKeys.allCases.map(\.rawValue)

        for key in keys {
            XCTAssertTrue(rows.contains(key), "README.md's Configuration table has no row for `\(key)`.")
        }
        for row in rows.subtracting(keys).sorted() {
            XCTFail("README.md's Configuration table has a row for `\(row)`, which isn't a configuration key.")
        }
    }

    func test_everyCommand_hasASubsectionInCommandsAndFlags() throws {
        let headings = Set(
            try section("Commands and flags").split(separator: "\n")
                .filter { $0.hasPrefix("### ") }
                .map { String($0.dropFirst(4)) }
        )

        for command in Self.displayedCommands {
            let name = try XCTUnwrap(command.configuration.commandName)
            XCTAssertTrue(headings.contains(name), "README.md's Commands and flags has no `### \(name)` subsection.")
        }
    }

    // run's and triage's tables list every flag they take, and no other.
    func test_runAndTriage_haveARowForEveryFlag() throws {
        for command in Self.commandsWithEveryFlagInATable {
            let name = try XCTUnwrap(command.configuration.commandName)
            let rows = Set(Self.rowFlags(try subsection(name)).joined().filter { $0.hasPrefix("--") })
            let flags = Set(Self.longFlags(inTheHelpOf: command))

            for flag in flags.subtracting(rows).sorted() {
                XCTFail("README.md's ### \(name) has no row for \(flag).")
            }
            for row in rows.subtracting(flags).sorted() {
                XCTFail("README.md's ### \(name) has a row for \(row), which isn't a flag of \(name).")
            }
        }
    }

    // The other commands take some of run's flags, which their text names, and a table of their own for the rest.
    func test_everyOtherCommand_namesEveryFlagItTakes() throws {
        let runRows = Self.rowFlags(try subsection("run"))
        let others = Self.displayedCommands.filter { command in
            !Self.commandsWithEveryFlagInATable.contains { ObjectIdentifier($0) == ObjectIdentifier(command) }
        }
        for command in others {
            let name = try XCTUnwrap(command.configuration.commandName)
            let text = try subsection(name)
            let own = Set(Self.rowFlags(text).joined().filter { $0.hasPrefix("--") })
            let flags = Set(Self.longFlags(inTheHelpOf: command))
            let namedRunRows = runRows.filter { row in row.contains { Self.names($0, in: text) } }
            let range = text.contains("from `-f` to `--property-tests`")
                ? Set(Self.longFlags(inTheHelpOf: ReportArguments.self))
                : []

            for flag in flags.sorted() {
                let named = own.contains(flag) || range.contains(flag)
                    || namedRunRows.contains { $0.contains(flag) }
                XCTAssertTrue(named, "README.md's ### \(name) doesn't name \(flag).")
            }
            for row in own.subtracting(flags).sorted() {
                XCTFail("README.md's ### \(name) has a row for \(row), which isn't a flag of \(name).")
            }
            for row in namedRunRows where !row.contains(where: flags.contains) {
                let rowText = row.joined(separator: ", ")
                XCTFail("README.md's ### \(name) names run's \(rowText), which \(name) doesn't take.")
            }
        }
    }

    // The flags are read from a command's help: its own, and not another command's.
    func test_longFlags_areReadFromTheHelp() {
        let flags = Self.longFlags(inTheHelpOf: Run.self)

        XCTAssertTrue(flags.contains("--files-to-mutate"), "\(flags)")
        XCTAssertTrue(flags.contains("--configuration"), "\(flags)")
        XCTAssertTrue(flags.contains("--force-reuse"), "\(flags)")
        XCTAssertFalse(flags.contains("--plan-ignoring"), "\(flags)")
        XCTAssertFalse(flags.contains("--help"), "\(flags)")
    }

    // A row's flags are read from its first cell, without their values, and an argument's row has none.
    func test_rowFlags_areReadFromTheFirstCell() {
        let rows = Self.rowFlags(
            """
            | Flag | Meaning | Default |
            |---|---|---|
            | `<plan>` | The test plan | Required |
            | `-c`, `--configuration <path>` | A file, or `--other` | `muter.conf.yml` |
            """
        )

        XCTAssertEqual(rows, [["-c", "--configuration"]])
    }

    private static let commandsWithEveryFlagInATable: [ParsableCommand.Type] = [Run.self, Triage.self]

    private static var displayedCommands: [ParsableCommand.Type] {
        // swiftlint:disable:next prefer_key_path - a key path through ParsableCommand.Type crashes Swift 6.4's SILGen
        MuterCommand.configuration.subcommands.filter { $0.configuration.shouldDisplay }
    }

    /// The long names on the help's option lines, such as `--configuration` in
    /// `  -c, --configuration <configuration>   The path to the configuration file.`, but not `--help`.
    private static func longFlags(inTheHelpOf arguments: ParsableArguments.Type) -> [String] {
        arguments.helpMessage(columns: 200).split(separator: "\n")
            .filter { $0.hasPrefix("  -") }
            .flatMap { line in
                let names = line.dropFirst(2).components(separatedBy: "  ").first ?? ""
                return names.split(separator: " ")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
                    .filter { $0.hasPrefix("--") && $0 != "--help" }
            }
    }

    /// The flags of each table row that names any, from its first cell: `["-c", "--configuration"]` from
    /// "| `-c`, `--configuration <path>` | …". A row for an argument, such as `<plan>`, names none.
    private static func rowFlags(_ text: String) -> [[String]] {
        text.split(separator: "\n")
            .filter { $0.hasPrefix("| `") }
            .map { line in
                let cell = line.dropFirst(2).components(separatedBy: " |").first ?? ""
                return cell.components(separatedBy: "`").enumerated()
                    .filter { !$0.offset.isMultiple(of: 2) }
                    .compactMap { $0.element.split(separator: " ").first.map(String.init) }
                    .filter { $0.hasPrefix("-") }
            }
            .filter { !$0.isEmpty }
    }

    /// Whether `text` names `flag` in backticks, alone or with a value: "`-c`" or "`-c <path>`".
    private static func names(_ flag: String, in text: String) -> Bool {
        text.contains("`\(flag)`") || text.contains("`\(flag) ")
    }

    /// The key a table row names in its first cell, such as `executable` in "| `executable` | The program…".
    private static func keyOfRow(_ line: Substring) -> String? {
        guard line.hasPrefix("| `") else {
            return nil
        }
        let afterTick = line.dropFirst(3)
        return afterTick.firstIndex(of: "`").map { String(afterTick[..<$0]) }
    }

    /// The `### <name>` subsection of Commands and flags, up to the next `### ` heading.
    private func subsection(_ name: String) throws -> String {
        let reference = try section("Commands and flags")
        let start = try XCTUnwrap(
            reference.range(of: "\n### \(name)\n"),
            "README.md's Commands and flags has no ### \(name) subsection."
        )
        let rest = reference[start.upperBound...]
        let end = rest.range(of: "\n### ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// README.md's `## <title>` section, up to the next `## ` heading.
    private func section(_ title: String) throws -> String {
        let readme = try String(contentsOfFile: Self.readmePath, encoding: .utf8)
        let start = try XCTUnwrap(readme.range(of: "\n## \(title)\n"), "README.md has no ## \(title) section.")
        let rest = readme[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    private static var readmePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Configuration
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
            .appendingPathComponent("README.md")
            .path
    }
}
