extension ResumeCheck {
    /// When either session worked its configuration out, as it found no file: with a configuration change that
    /// refuses, `operatorsChanged` among them, a reason more that says so, and how to get the same configuration again;
    /// else, when only one did, a notice that the configuration came from elsewhere, with the same values unless it
    /// `differs` in what no recorded result depends on.
    static func sayWhereTheConfigurationCameFrom(
        then: Bool,
        now: Bool,
        differs: Bool,
        operatorsChanged: Bool,
        into verdict: inout Verdict
    ) {
        guard then || now else { return }
        let changed = operatorsChanged || verdict.refusals.contains { refusal in
            switch refusal {
            case .configurationChanged, .timeLimitUnknown: true
            default: false
            }
        }
        if changed {
            verdict.refusals.append(.configurationWorkedOut(then: then, now: now))
        } else if then != now {
            let file = MuterConfiguration.fileNameWithExtension
            let values = differs ? ": what differs changes no recorded result." : ", with the same values."
            verdict.notices.append(
                then
                    ? "The last session worked out its configuration, as there was no \(file), and this run reads "
                    + "\(file)\(values)"
                    : "The last session read \(file), and this run works out its configuration, as there is "
                    + "none\(values)"
            )
        }
    }
}
