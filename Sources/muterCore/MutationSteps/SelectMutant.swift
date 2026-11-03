import Foundation

/// Narrows the run's mutants to the one `--mutant` names, before anything is rewritten or tested: in a run, after
/// discovery and before the copy is rewritten, so the copy gets only that mutant's switch; in a run of a test plan,
/// right after the plan is read, so its checks look only at that mutant's file, and the copy isn't touched. A mutant
/// that isn't there, a reference that names several, and one of several mutants that share a place, and so a switch,
/// are refused. A place without repeats holds only occurrence 0, so the narrowed jobs key the mutant as the whole run's
/// do.
struct SelectMutant: MutationStep {
    /// How many mutants near the place a refused reference names are listed.
    static let nearbyListed = 5

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        guard let reference = state.runOptions.mutant else { return [] }
        let root = state.mutatedProjectDirectoryURL
        // As `PerformMutationTesting.jobs(of:)` lists them, so the keys and their occurrences are the run's.
        let keys = MutantKey.keys(for: state.mutationMapping.flatMap(\.mutationSchemata), under: root)
        let key = try Self.select(reference, among: keys, roots: [state.projectDirectoryURL, root])

        let mappings: [SchemataMutationMapping] = state.mutationMapping.compactMap { mapping in
            var kept = mapping
            kept.keepOnly { Self.place(of: $0, under: root) == key }
            return kept.isEmpty ? nil : kept
        }
        return [.mutationMappingsDiscovered(mappings), .mutantSelected(key)]
    }

    /// The key of the one mutant among `keys` that `reference` names, its path made relative to the first of `roots`
    /// that holds it; or why there is none to test on its own. A refusal lists each place once, with how many mutants
    /// share its switch, so that every `--mutant` it offers is one this accepts.
    static func select(_ reference: MutantReference, among keys: [MutantKey], roots: [URL]) throws -> MutantKey {
        let wanted = reference.relative(toFirstOf: roots)
        let sharing = Dictionary(keys.map { (place(of: $0), 1) }, uniquingKeysWith: +)
        let matches = keys.filter(wanted.matches)
        let places = Self.places(of: matches)

        guard let place = places.first else {
            let inFiles = keys.filter { wanted.matchesPath($0.path) }
            let files = Set(inFiles.map(\.path)).count
            let placesInFiles = Self.places(of: inFiles)
            // The nearest by line, and of those at the same distance the first in the jobs; listed in job order.
            let nearby = placesInFiles.indices
                .sorted {
                    (abs(placesInFiles[$0].line - wanted.line), $0) < (abs(placesInFiles[$1].line - wanted.line), $1)
                }
                .prefix(nearbyListed)
                .sorted()
                .map { MutantRefused.Listed(key: placesInFiles[$0], sharing: sharing[placesInFiles[$0]] ?? 1) }
            throw MutantRefused(reference: reference, reason: .notFound(nearby: nearby, files: files))
        }
        guard places.count == 1 else {
            let listed = places.map { MutantRefused.Listed(key: $0, sharing: sharing[$0] ?? 1) }
            throw MutantRefused(reference: reference, reason: .ambiguous(listed))
        }
        let atThePlace = sharing[place] ?? 1
        guard atThePlace == 1 else {
            throw MutantRefused(reference: reference, reason: .repeated(matches[0], count: atThePlace))
        }
        return place
    }

    /// The places of `keys`' mutants, each once, in the order of the first key at each.
    private static func places(of keys: [MutantKey]) -> [MutantKey] {
        var places: [MutantKey] = []
        var seen: Set<MutantKey> = []
        for key in keys where seen.insert(place(of: key)).inserted {
            places.append(place(of: key))
        }
        return places
    }

    /// `key` without its occurrence: where its mutant is, and which operator mutates it there.
    private static func place(of key: MutantKey) -> MutantKey {
        MutantKey(
            path: key.path,
            mutationOperatorId: key.mutationOperatorId,
            line: key.line,
            column: key.column,
            occurrence: 0
        )
    }

    /// The place of `schema`'s mutant, keyed as `MutantKey.keys(for:under:)` keys it under `root`.
    private static func place(of schema: MutationSchema, under root: URL) -> MutantKey {
        MutantKey(
            path: RepoRelativePath.of(schema.filePath, under: root),
            mutationOperatorId: schema.mutationOperatorId,
            line: schema.position.line,
            column: schema.position.column,
            occurrence: 0
        )
    }
}

/// Why `--mutant` tests nothing: the mutant it names isn't one the run has, or can't be tested on its own. The run
/// stops with an error's status, and its message lists what can be given instead.
struct MutantRefused: Error, Equatable, CustomStringConvertible {
    /// As given.
    let reference: MutantReference
    let reason: Reason

    enum Reason: Equatable {
        /// No mutant is at the place given. `nearby` are the places nearest to its line, at most
        /// `SelectMutant.nearbyListed`, in the `files` files whose path its path names; none when no file does.
        case notFound(nearby: [Listed], files: Int)
        /// The reference matches mutants at more than one place: these.
        case ambiguous([Listed])
        /// The mutant is one of `count` that one operator makes at one place, which share one switch.
        case repeated(MutantKey, count: Int)
    }

    /// A place a refusal lists: its key, and how many mutants one operator makes there, which share one switch. Only
    /// a place with one can be tested on its own.
    struct Listed: Equatable {
        let key: MutantKey
        let sharing: Int
    }

    var description: String {
        switch reason {
        case let .notFound(nearby, files):
            guard !nearby.isEmpty else {
                return "No mutant is at \(reference): no file with mutants matches \(reference.path). "
                    + "Nothing was tested."
            }
            let inFiles = files == 1 ? "the file" : "the \(files) files"
            return "No mutant is at \(reference). Mutants near line \(reference.line) in \(inFiles) it names:\n"
                + Self.options(nearby) + "\nNothing was tested."
        case let .ambiguous(places):
            let count = places.map(\.sharing).reduce(0, +)
            let choice = places.contains { $0.sharing == 1 }
                ? "give one of these:" : "none of them can be tested on its own:"
            return "\(reference) names \(count) mutants; \(choice)\n" + Self.options(places) + "\nNothing was tested."
        case let .repeated(key, count):
            return "\(Logger.shellQuoted(key.description)) is one of \(count) \(key.mutationOperatorId.rawValue) "
                + "mutants at the same place. They share one switch, so none of them can be tested on its own. "
                + "Nothing was tested."
        }
    }

    /// Each place on a line of its own: as the option that names it, quoted for a shell, when it can be tested on its
    /// own, and otherwise as a note that it can't, which isn't an option to paste.
    private static func options(_ places: [Listed]) -> String {
        places.map { place in
            place.sharing == 1
                ? "  --mutant " + Logger.shellQuoted(place.key.description)
                : "  " + Logger.shellQuoted(place.key.description) + ": one of \(place.sharing) "
                    + "\(place.key.mutationOperatorId.rawValue) mutants that share one switch, so can't be tested alone"
        }
        .joined(separator: "\n")
    }
}
