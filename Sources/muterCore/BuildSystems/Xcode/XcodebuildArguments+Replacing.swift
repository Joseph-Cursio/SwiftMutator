extension XcodebuildArguments {
    /// Where `replacing(_:with:placing:)` writes an option the arguments lack.
    enum Placement: Equatable {
        /// Right after the first of these options, with its value, or at the front when there is none.
        case after(Set<String>)
        /// Just before the first action, or at the end when there is none.
        case beforeTheFirstAction
    }

    /// Each option named one of `names`, in the order written. A value that reads like one, as `-scheme` in
    /// `-only-testing -scheme`, is the option's value, not an option.
    func options(named names: Set<String>) -> [Argument] {
        arguments.filter { $0.kind == .option && names.contains($0.name) }
    }

    /// The arguments as written, with every option named one of `names` left out, each with its value, and
    /// `replacement` written where the first of them was, or where `placement` says when there is none.
    func replacing(_ names: Set<String>, with replacement: [String], placing placement: Placement) -> [String] {
        let isReplaced = { (argument: Argument) in argument.kind == .option && names.contains(argument.name) }
        if let first = arguments.firstIndex(where: isReplaced) {
            return arguments.indices.flatMap { index -> [String] in
                if index == first {
                    return replacement
                }
                return isReplaced(arguments[index]) ? [] : arguments[index].written
            }
        }
        let index: Int
        switch placement {
        case let .after(options):
            let found = arguments.firstIndex { $0.kind == .option && options.contains($0.name) }
            index = found.map { $0 + 1 } ?? 0

        case .beforeTheFirstAction:
            index = arguments.firstIndex { $0.kind == .action } ?? arguments.count
        }
        return arguments[..<index].flatMap(\.written) + replacement + arguments[index...].flatMap(\.written)
    }
}

extension XcodebuildArguments.Argument {
    /// The option's value, as `App` is `-scheme App`'s; nil for an option written without one, and for any other
    /// argument.
    var value: String? {
        written.count > 1 ? written[1] : nil
    }
}
