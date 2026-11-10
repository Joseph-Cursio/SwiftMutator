import Foundation

/// How a test plan is written and read. It is a file people read, diff and commit, so it is pretty-printed and ends in
/// a newline; its keys are sorted and its paths are relative to the project, so a plan of the same mutants in a
/// folder of the same name is the same bytes wherever the folder is; and its slashes are unescaped, so paths read as
/// paths.
enum TestPlanCoding {
    /// The format this SwiftMutator writes. A format changes only for a change that a reader of the earlier one would
    /// misread. A new key needs none: readers ignore keys they don't know.
    ///
    /// Format 2 is format 1 with a copy whose name ends in `.noindex`, as `<project>_mutated.noindex`. Its keys are
    /// format 1's, but a SwiftMutator from before `.noindex` would lock `<project>_mutated.noindex.lock` for that copy,
    /// while this one locks `<project>_mutated.lock` (`MutatedProjectNames.lockFile(of:)`), and a run of this one could
    /// remove the copy while the older one tested in it. Such a SwiftMutator refuses format 2 before it locks anything.
    static let formatVersion = 2
    /// The newest format this SwiftMutator reads. It refuses a plan in a newer one.
    static let newestFormatVersion = formatVersion

    static var encoder: JSONEncoder {
        let planEncoder = JSONEncoder()
        planEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return planEncoder
    }

    /// The plan's text, as `CreateMuterTestPlan` writes it into `projectRoot`: in `formatVersion`, whichever format
    /// the plan was read in, with its copy's path relative to `projectRoot` and its mutants' paths relative to the
    /// copy.
    static func encode(_ plan: MuterTestPlan, under projectRoot: URL) throws -> String {
        let file = TestPlanFile(
            formatVersion: formatVersion,
            swiftMutatorVersion: plan.swiftMutatorVersion ?? version,
            mutatedProject: RelativePath.from(projectRoot, to: plan.mutatedProjectURL),
            projectCoverage: plan.projectCoverage == .null ? nil : plan.projectCoverage.percent,
            operators: (plan.scope?.operators ?? .allOperators).map(\.rawValue).sorted(),
            filesToMutate: plan.scope?.filesToMutate ?? [],
            sources: plan.sources,
            mutatedFiles: plan.mutatedFiles,
            linkedFiles: plan.linkedFiles,
            mappings: plan.mappings.map { $0.relative(to: plan.mutatedProjectURL) },
            mutantsNotCovered: plan.mutantsNotCovered
        )
        return try String(decoding: encoder.encode(file), as: UTF8.self) + "\n"
    }

    /// The plan at `path`, whose bytes are `data`, with its paths resolved: a format-1 or later copy's under
    /// `projectRoot`, the folder the plan was made in, and its mutants' under the copy. A plan in format 0 holds
    /// absolute paths, which are kept, and doesn't say what its mutants were chosen by or record the project's files. A
    /// plan in a format newer than `newestFormatVersion` is refused.
    static func read(_ data: Data, path: String, under projectRoot: URL) throws -> MuterTestPlan {
        guard let found = try JSONDecoder().decode(FormatVersion.self, from: data).formatVersion else {
            let file = try JSONDecoder().decode(LegacyTestPlanFile.self, from: data)
            let copy = resolvedCopy(file.mutatedProjectPath, under: projectRoot)
            return MuterTestPlan(
                formatVersion: 0,
                swiftMutatorVersion: nil,
                mutatedProjectURL: copy,
                projectCoverage: file.projectCoverage < 0 ? .null : Coverage(percent: file.projectCoverage),
                scope: nil,
                mappings: file.mappings.map { $0.resolved(under: copy) }
            )
        }
        guard found <= newestFormatVersion else {
            throw TestPlanRefused(path: path, reason: .newerFormat(found: found))
        }
        let file = try JSONDecoder().decode(TestPlanFile.self, from: data)
        let copy = resolvedCopy(file.mutatedProject, under: projectRoot)
        return MuterTestPlan(
            formatVersion: file.formatVersion,
            swiftMutatorVersion: file.swiftMutatorVersion,
            mutatedProjectURL: copy,
            projectCoverage: file.projectCoverage.map { Coverage(percent: $0) } ?? .null,
            // A mutant by an operator this SwiftMutator doesn't know would have stopped the plan being read, so such
            // an operator chose none of its mutants.
            scope: TestPlanScope(
                operators: file.operators.compactMap(MutationOperator.Id.init(rawValue:)),
                filesToMutate: file.filesToMutate
            ),
            sources: file.sources,
            mutatedFiles: file.mutatedFiles,
            linkedFiles: file.linkedFiles,
            mappings: file.mappings.map { $0.resolved(under: copy) },
            mutantsNotCovered: file.mutantsNotCovered
        )
    }

    /// The copy at `path`, relative to `projectRoot` or absolute, with no `.` or `..` left to reach its lock's path or
    /// the reports. Only those go: the rest keeps the form `projectRoot` has, as `standardizedFileURL` wouldn't, which
    /// turns an existing `/private/tmp/…` into `/tmp/…`. Its mutants' paths are resolved under this same path, which
    /// `MutationTestOutcome` finds each of them in.
    private static func resolvedCopy(_ path: String, under projectRoot: URL) -> URL {
        URL(fileURLWithPath: RepoRelativePath.resolve(path, under: projectRoot.path)).standardized
    }

    /// What a plan's format is read from before the rest: format 0 has no `formatVersion`.
    private struct FormatVersion: Decodable {
        let formatVersion: Int?
    }
}

/// A test plan as it is written, in format 1 or 2, which have the same keys. Its paths are relative, so the project and
/// its copy can move together: the copy's to the folder the plan was made in, and each mutant's to the copy. A path
/// that isn't inside the folder it is relative to is kept absolute.
struct TestPlanFile: Codable, Equatable {
    let formatVersion: Int
    /// Recorded for people to read; never compared. Without the executable's SHA-256, so two builds of one version
    /// write the same plan.
    let swiftMutatorVersion: String
    /// The copy of the project, relative to the folder the plan was made in, as `../Foo_mutated.noindex`.
    let mutatedProject: String
    /// Left out when coverage wasn't gathered.
    let projectCoverage: Int?
    /// The operators the mutants were chosen by (`Run.Options.chosenOperators(given:)`), by name and sorted.
    let operators: [String]
    /// The files the mutants were chosen from, `--files-to-mutate` as given; empty when it wasn't.
    let filesToMutate: [String]
    /// The project's own files as they were when the plan was made, before any was rewritten, which a run of the plan
    /// checks the project against (`CheckTestPlanSources`). Left out only by a plan made without them.
    let sources: ProjectTree?
    /// The SHA-256 of each file with mutants, as the plan left it in the copy, by its path relative to the copy. Left
    /// out only by a plan made without them.
    let mutatedFiles: [String: String]?
    /// The SHA-256 of what each file with mutants that is a symbolic link in the project held when the plan was made,
    /// by its path relative to the project, which a run of the plan checks the link's file against. Left out when no
    /// such file is a link.
    let linkedFiles: [String: String]?
    /// By file, each file's mutants in the order mutation testing runs them.
    let mappings: [SchemataMutationMapping]
    /// The mutants of code no test ran, which the plan makes none of, with their paths relative to the copy, sorted by
    /// key (`MuterTestPlan.mutantsNotCovered`); empty when there are none. A new key, so the format is the same: a
    /// plan from before it leaves it out, and its run records none, so it writes no baseline file.
    var mutantsNotCovered: [UncoveredMutant]?
}

/// A test plan as SwiftMutators from before `TestPlanFile` wrote it, which is format 0: with no `formatVersion`,
/// absolute paths, and a coverage of -1 when it wasn't gathered.
struct LegacyTestPlanFile: Codable, Equatable {
    let mutatedProjectPath: String
    let projectCoverage: Int
    let mappings: [SchemataMutationMapping]
}
