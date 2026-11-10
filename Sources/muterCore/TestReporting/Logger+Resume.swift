import Foundation

/// What the Logger says when a run resumes: which results still hold, what is left to test and why.
extension Logger {
    /// How many of a resumed run's results still hold, and how many mutants are left to test and why; then how its
    /// discovery differs from the last session's, each change no result depends on, and what `--force-resume` and
    /// `--resume-ignoring` let through. A run that reuses an earlier run's results says the same, with `--reuse`'s
    /// flags, and names the changed files other than tests that make it test every mutant again. The progress bar or
    /// the progress lines then count only the mutants left.
    func resumePlanned(_ summary: ResumeSummary) {
        numberOfMutationPoints = summary.toTest
        let resuming = summary.isReuse
            ? "♻️ Reusing the results in \(summary.path.bold): "
            : "♻️ Resuming the run in \(summary.path.bold): "
        let reused = summary.reused == 1 ? "1 result still holds" : "\(summary.reused) results still hold"
        if summary.toTest == 0 {
            var held = summary.reused == 1 ? "its only result still holds" : "all \(summary.reused) results still hold"
            if summary.noLongerDiscovered > 0 || summary.outsideTheSample > 0 {
                // Not all the file's results: some no longer count.
                held = reused
            }
            print(resuming + "\(held), so nothing is left to test.")
        } else {
            let reasons = ResumePlan.Reason.allCases.compactMap { reason in
                summary.retestedBecause[reason].flatMap { $0 > 0 ? Self.retested($0, because: reason) : nil }
            }
            let left = summary.toTest == 1 ? "1 mutant is" : "\(summary.toTest) mutants are"
            let why = reasons.isEmpty ? "" : " (\(reasons.joined(separator: ", ")))"
            print(resuming + "\(reused), so \(left) left to test\(why).")
        }
        if let selectionChange = summary.selectionChange {
            print("ℹ️ \(selectionChange)")
        } else if let discoveryChange = Self.discoveryChange(summary) {
            print("⚠️ \(discoveryChange)")
        } else if let coverageChange = summary.coverageChange {
            // Gathered in both sessions, and the mutants are as many as before, so only said.
            let change = "\(coverageChange)"
            print(
                "ℹ️ \(change.prefix(1).uppercased() + change.dropFirst()), "
                    + "but every earlier result's mutant is still discovered."
            )
        }
        // Still discovered, but not sampled: a reuse of another sample, or of none, says why in `selectionChange`.
        if !summary.sampleChanged, summary.outsideTheSample > 0 {
            print(
                summary.outsideTheSample == 1
                    ? "ℹ️ 1 earlier result no longer counts, as the sample no longer takes its mutant."
                    : "ℹ️ \(summary.outsideTheSample) earlier results no longer count, as the sample no longer takes "
                    + "their mutants."
            )
        }
        for notice in summary.notices {
            print("ℹ️ \(notice)")
        }
        if let otherFiles = Self.otherFilesChanged(summary) {
            print("⚠️ \(otherFiles)")
        } else if summary.testFilesChanged > 0 {
            let files = summary.testFilesChanged == 1 ? "1 test file" : "\(summary.testFilesChanged) test files"
            print(
                "ℹ️ \(files) changed, so every survivor is tested again, and every kill that no unchanged test "
                    + "still holds."
            )
        }
        let force = summary.isReuse ? "--force-reuse" : "--force-resume"
        let ignoring = summary.isReuse ? "--reuse-ignoring" : "--resume-ignoring"
        if !summary.forced.isEmpty {
            let subjects = summary.forced.map { name in
                let subject = ResumeCheck.subject(of: name)
                return subject.hasPrefix("The ") ? "the " + subject.dropFirst(4) : subject
            }
            print("⚠️ Results are reused although \(Self.listed(subjects)) changed (\(force)).")
        }
        if !summary.waived.isEmpty {
            let named = summary.waived.prefix(ResumeRefusal.changedFilesNamed)
            let others = summary.waived.count - named.count
            let one = summary.waived.count == 1
            // As `ResumeRefusal.copyChanged` names them.
            let files = summary.testPlanCopy.map { copy in
                "\(summary.waived.count) file\(one ? "" : "s") of the test plan's copy, \(copy),"
            } ?? (one ? "1 project file" : "\(summary.waived.count) project files")
            print(
                "⚠️ Results are reused although \(files) changed (\(ignoring)): "
                    + named.joined(separator: ", ") + (others > 0 ? ", and \(others) more" : "")
            )
        }
    }

    /// "2 project files other than tests changed since that run's results were tested, so they are tested again:
    /// Package.resolved (changed), README.md (changed). If they can't change any test's result: --reuse-ignoring
    /// 'Package.resolved' …": what made a reuse test results again whatever they were; nil if nothing did. A file that
    /// changed after one session of the earlier run, and before the next, makes it test only the first one's.
    static func otherFilesChanged(_ summary: ResumeSummary) -> String? {
        let changes = summary.otherFilesChanged
        guard !changes.isEmpty else { return nil }
        let named = changes.prefix(ResumeRefusal.changedFilesNamed)
        let others = changes.count - named.count
        let one = changes.count == 1
        let files = named.map { "\($0.path) (\($0.kind.rawValue))" }.joined(separator: ", ")
            + (others > 0 ? ", and \(others) more" : "")
        let flags = named.map { "--reuse-ignoring " + shellQuoted(ResumeRefusal.glob(matching: $0.path)) }
            .joined(separator: " ")
            + (others > 0 ? ", plus globs for the other \(others)" : "")
        return "\(changes.count) project file\(one ? "" : "s") other than tests changed since that run's results were "
            + "tested, so they are tested again: \(files). If \(one ? "it" : "they") can't change any test's result: "
            + flags
    }

    /// "412 earlier results no longer count, as this session doesn't discover their mutants: coverage couldn't be
    /// gathered then, and is now.": how a resumed run's discovery differs from the last session's, and the coverage
    /// change that may explain it; nil if nothing shows it does. Based on the counts, as discovery can change while
    /// coverage looks the same: xcodebuild can lose regions without a word, `--force-resume` lets a SwiftMutator that
    /// discovers differently through, and the files discovery picks from come from `swift package describe` or git,
    /// which may work in one session only.
    static func discoveryChange(_ summary: ResumeSummary) -> String? {
        let lost = summary.noLongerDiscovered
        if lost > 0 {
            let because = reason(summary.coverageChange, if: \.canLeaveOutMutants)
            return lost == 1
                ? "1 earlier result no longer counts, as this session doesn't discover its mutant\(because)."
                : "\(lost) earlier results no longer count, as this session doesn't discover their mutants\(because)."
        }
        // A partial sample's count is the sample's, which moves as new mutants rank into it, not discovery's.
        if summary.discovered != summary.discoveredBefore, !summary.sampleIsPartial {
            let more = summary.discovered > summary.discoveredBefore
            let because = reason(summary.coverageChange, if: more ? \.canBringInMutants : \.canLeaveOutMutants)
            let mutants = summary.discovered == 1 ? "1 mutant" : "\(summary.discovered) mutants"
            return "This session discovers \(mutants), and the last one discovered \(summary.discoveredBefore)"
                + "\(because)."
        }
        if let change = summary.coverageChange, change.isGatheredInOneSessionOnly {
            return "This session discovers as many mutants as the last one, although \(change)."
        }
        return nil
    }

    /// ": coverage couldn't be gathered then, and is now": `change`, if it `fits` the way discovery changed; empty if
    /// there is none, or it would push the count the other way, as losing coverage can't leave out a mutant.
    static func reason(
        _ change: ResumeCheck.CoverageChange?,
        if fits: KeyPath<ResumeCheck.CoverageChange, Bool>
    ) -> String {
        guard let change, change[keyPath: fits] else { return "" }
        return ": \(change)"
    }

    /// "5 build errors": how many mutants are tested again for `reason`.
    static func retested(_ count: Int, because reason: ResumePlan.Reason) -> String {
        let one = count == 1
        switch reason {
        case .notRecorded:
            return "\(count) never tested"

        case .buildError:
            return "\(count) build error\(one ? "" : "s")"

        case .fileChanged:
            return "\(count) in \(one ? "a changed file" : "changed files")"

        case .mutationChanged:
            return "\(count) changed mutation\(one ? "" : "s")"

        case .repeated:
            return "\(count) repeated in \(one ? "its" : "their") file"

        case .timeoutNotRerun:
            return "\(count) timeout\(one ? "" : "s") not run again at lower load"

        case .timeoutUnderShorterLimit:
            return "\(count) timeout\(one ? "" : "s") under a shorter limit"

        case .timedOut:
            return "\(count) timeout\(one ? "" : "s")"

        case .codeNotShownRunning:
            return "\(count) failed without running \(one ? "its" : "their") code"

        case .sessionShowedNoCodeRunning:
            return "\(count) from a session that switched on no mutant"

        case .otherFileChanged:
            return "\(count) as other project files changed"

        case .testsChanged:
            return "\(count) as test files changed"
        }
    }

    /// "a, b and c".
    static func listed(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
