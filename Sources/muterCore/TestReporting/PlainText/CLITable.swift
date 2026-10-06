import Rainbow

/// A plain-text table. Columns are padded by the width shown, so a cell's colour codes don't push the columns after it
/// out of line.
struct CLITable: Equatable {
    static let empty = CLITable(padding: 0, columns: [])

    let padding: Int
    let columns: [Column]

    var description: String {
        columns.enumerated().accumulate(into: "") {
            let columnIndex = $1.offset
            let column = $1.element
            let previousColumn = columns[max(0, columnIndex - 1)]
            let previousColumnWidth = previousColumn.width

            var alreadyRenderedCLITableSplitByLine = $0.split(separator: "\n")

            let previousColumnRows = previousColumn.description.split(separator: "\n")
            let columnRows = column.description.split(separator: "\n")

            return zip(previousColumnRows, columnRows).accumulate(into: "") { workingValue, currentRows in
                let previousRowWidth = String(currentRows.0).raw.count
                let newRow = currentRows.1

                let nextLineThatsBeenRendered = alreadyRenderedCLITableSplitByLine.first ?? ""
                alreadyRenderedCLITableSplitByLine = Array(alreadyRenderedCLITableSplitByLine.dropFirst())

                let padding = paddingForColumn(
                    at: columnIndex,
                    previousColumnWidth: previousColumnWidth,
                    previousRowWidth: previousRowWidth
                )

                return workingValue + "\(nextLineThatsBeenRendered)" + padding + newRow + "\n"
            }
        }
    }

    private func paddingForColumn(at index: Int, previousColumnWidth: Int, previousRowWidth: Int) -> String {
        let lengthOfPadding = previousColumnWidth - previousRowWidth
        return index == 0 ? "" : " ".repeated(lengthOfPadding + padding)
    }
}

extension CLITable {

    struct Column: Equatable {
        let title: String
        let rows: [Row]
        /// The widest cell or title as shown: colour codes take no room on screen.
        var width: Int {
            let stringLengths = rows.map { $0.value.raw.count } + [title.raw.count]
            return stringLengths.reduce(0, max)
        }

        var description: String {

            guard rows.count >= 1 else {
                return ""
            }

            let content = rows.accumulate(into: "") { $0 + "\($1.value)\n" }

            let numberOfDashes = title.count
            let dashes = "-".repeated(numberOfDashes)

            return """
            \(title)
            \(dashes)
            \(content)
            """
        }
    }

    struct Row: Equatable {
        let value: String
    }
}
