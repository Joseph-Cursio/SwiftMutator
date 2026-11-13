import Foundation

/// How a results file's lines are written and read: JSON Lines, one record per line, each with a `kind`.
enum ResultsCoding {
    /// A first session's header's format. A format changes only for a change that a reader of the earlier one would
    /// misread. A new key, or a new kind a reader can skip, needs none: readers ignore keys and skip kinds they don't
    /// know.
    static let formatVersion = 1
    /// A resumed session's header's format: its file holds `retired` lines, which a format-1 reader would skip, so it
    /// would report results the run no longer stands by. A file that was never resumed stays in format 1, which older
    /// SwiftMutators read.
    static let resumedFormatVersion = 2
    /// A resumed session's header that records its project tree as what changed since the last session's
    /// (`ResultsHeader.projectDelta`). A format-2 reader would take it for a session with no tree, which `--reuse` and
    /// a merge of shards skip, rather than check.
    static let projectDeltaFormatVersion = 3
    /// A session's header whose `mutant` lines may have no `log`, as a mutant killed by a failed test its line names
    /// keeps none unless `keepAllLogs` is set. A format-3 reader would skip those lines, as it can't read them, and
    /// lose their results. A session that writes a `log` on every line keeps to the formats above.
    static let omittedLogsFormatVersion = 4
    /// The newest format this SwiftMutator reads. It refuses a file with a header in a newer one.
    static let newestFormatVersion = omittedLogsFormatVersion

    /// Sorted keys, so lines read and compare alike; slashes unescaped, so paths read as paths; never pretty-printed,
    /// so a record is one line, any line break in it escaped. Dates are ISO 8601 in UTC, to the millisecond.
    static var encoder: JSONEncoder {
        let lineEncoder = JSONEncoder()
        lineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        lineEncoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(text(of: date))
        }
        return lineEncoder
    }

    /// Reads dates as `encoder` writes them, or without fractional seconds.
    static var decoder: JSONDecoder {
        let lineDecoder = JSONDecoder()
        lineDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return lineDecoder
    }

    /// Every line's first question: what kind of record it is.
    struct Kind: Decodable {
        let kind: String
    }

    /// `date` in UTC to the nearest millisecond, `2026-10-04T13:16:04.512Z`. Rounded here rather than by
    /// `ISO8601FormatStyle`, which truncates: a date read back from `.004` is a hair under it, and would be written
    /// back as `.003`.
    private static func text(of date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        let seconds = (milliseconds / 1_000).rounded(.down)
        let time = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: seconds)
        )
        return String(
            format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld.%03ldZ",
            time.year ?? 0,
            time.month ?? 0,
            time.day ?? 0,
            time.hour ?? 0,
            time.minute ?? 0,
            time.second ?? 0,
            Int(milliseconds - seconds * 1_000)
        )
    }

    private static func date(from text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar
    }()
}
