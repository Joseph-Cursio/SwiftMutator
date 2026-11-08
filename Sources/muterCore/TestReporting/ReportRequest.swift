import Foundation

/// A report saved besides `-f`'s, in a format of its own: `--report`'s or the `reports:` key's `format:path`, such as
/// `markdown:summary.md`. Written and read as that one string, so YAML reads `reports: [markdown:summary.md]` and a
/// results file's header records it as given.
struct ReportRequest: Hashable, Sendable, CustomStringConvertible, Codable {
    let format: ReportFormat
    let path: String

    init(format: ReportFormat, path: String) {
        self.format = format
        self.path = path
    }

    /// The request `text` gives, as `format:path`, split at the first `:` only, as a path may hold one; or what is
    /// wrong with it, completing "give …" in a flag's refusal or a key's, without its period. The flag and the key
    /// both parse through this, so they refuse alike.
    static func parse(_ text: String) -> Result<ReportRequest, Problem> {
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else {
            return .failure(Problem("name the format and then the path, as format:path, such as \(example)"))
        }
        let name = String(text[..<colon])
        let path = String(text[text.index(after: colon)...])
        guard let format = ReportFormat(rawValue: name) else {
            return .failure(Problem(
                "start with one of the formats \(savedFormats), as format:path, such as \(example)"
            ))
        }
        // Its warnings are printed as each mutant finishes, which only `-f`'s reporter is told of; a saved copy would
        // hold the summary alone.
        guard format != .xcode else {
            return .failure(Problem(
                "save the Xcode format with -f xcode, as its warnings are printed while the run goes, which only -f's "
                    + "report is; here give another format, such as \(example)"
            ))
        }
        guard !path.isEmpty else {
            return .failure(Problem("give a path after the format, as format:path, such as \(example)"))
        }
        return .success(ReportRequest(format: format, path: path))
    }

    /// What is wrong with a `format:path`.
    struct Problem: Error, Equatable, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    /// The formats a request can name: every one but `xcode`, whose warnings only `-f xcode` prints.
    static var savedFormats: String {
        ReportFormat.allCases.filter { $0 != .xcode }.map(\.rawValue).joined(separator: ", ")
    }

    static let example = "markdown:summary.md"

    var description: String {
        "\(format.rawValue):\(path)"
    }

    /// This request with a relative path resolved against `folder`, as a run's own folder is the project's; an
    /// absolute path is kept. A leading `~` is the home folder: a shell expands it in `-o ~/r.md`, but not after
    /// `markdown:`, and YAML never does, so `markdown:~/r.md` would otherwise be a `~` folder in `folder`.
    func resolved(in folder: String) -> ReportRequest {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return ReportRequest(format: format, path: expanded) }
        return ReportRequest(format: format, path: (folder as NSString).appendingPathComponent(path))
    }

    /// This request with a relative path resolved against the current directory, as `-o`'s is.
    var resolved: ReportRequest {
        resolved(in: current.fileManager.currentDirectoryPath)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        switch Self.parse(text) {
        case let .success(request):
            self = request
        case let .failure(problem):
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(problem), not \(text)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension ReportRequest {
    /// A report a command saves, by what names it in a refusal ("-o report.html", "--report markdown:summary.md") and
    /// the path it is saved at.
    typealias Output = (option: String, path: String)

    /// Why two of `outputs` can't both be saved, or nil when none clash: two at one path, or, for a run's `outputs`,
    /// one at the path another's partial report would take when the run stops (`PartialReport.path(besides:)`), which
    /// `report` never writes. Paths are compared standardized, so `./r.md` is `r.md`; `ResultsFile.isSameFile` judges
    /// spellings of one file only once it exists.
    static func clash(among outputs: [Output], ofARun isARun: Bool) -> String? {
        let standardized = outputs.map { URL(fileURLWithPath: $0.path).standardized.path }
        for later in outputs.indices {
            for earlier in outputs.indices where earlier < later {
                if standardized[earlier] == standardized[later] {
                    return "\(outputs[earlier].option) and \(outputs[later].option) would save to the same file"
                }
                for (one, other) in [(earlier, later), (later, earlier)]
                    where isARun && PartialReport.path(besides: standardized[one]) == standardized[other] {
                    return "\(outputs[other].option) would save where \(outputs[one].option)'s partial report goes "
                        + "when a run stops"
                }
            }
        }
        return nil
    }
}
