import SwiftParser

struct PrepareSourceCode {
    @Dependency(\.writeFile)
    private var writeFile: WriteFile
    @Dependency(\.loadSourceCode)
    private var loadSourceCode: LoadSourceCode

    /// The file at `path` as discovery mutates it, with the import and the comments that turn linters off, which it
    /// writes back, unless not `writing`: a file coverage leaves out is walked for its mutants, which are counted as
    /// not covered, at the lines and columns the same file would give them, but nothing is made of them in the copy.
    func prepareSourceCode(
        _ path: String,
        writing: Bool = true
    ) -> PreparedSourceCode? {
        guard let source = loadSourceCode(path) else {
            return nil
        }

        let addImport = AddImportRewriter(accessLevel: FoundationImportStyle.accessLevel(forFileAt: path))
        let addImportSource = addImport.visit(source.code)

        let disableLinters = DisableLintersRewriter()
        let disableLintersSource = disableLinters.visit(addImportSource)

        let newSourceCode = disableLintersSource.description

        let numberOfNewLines = addImport.newLinesAddedToFile + disableLinters.newLinesAddedToFile
        let changes = MutationSourceCodePreparationChange(
            newLines: numberOfNewLines
        )

        guard writing else {
            return (source: SourceCodeInfo(path: path, code: Parser.parse(source: newSourceCode)), changes: changes)
        }

        do {
            try writeFile(
                newSourceCode,
                path
            )

            return loadSourceCode(path)
                .map { sourceCode in
                    PreparedSourceCode(
                        source: sourceCode,
                        changes: changes
                    )
                }
        } catch {
            return nil
        }
    }
}
