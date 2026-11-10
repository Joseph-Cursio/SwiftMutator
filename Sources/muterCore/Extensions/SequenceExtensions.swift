public extension Sequence {
    /// How many elements `isIncluded` holds for.
    func count(_ isIncluded: (Self.Element) throws -> Bool) rethrows -> Int {
        try include(isIncluded).count
    }

    /// The elements `isIncluded` holds for, in order: `filter` by a name that reads beside `exclude`.
    func include(_ isIncluded: (Self.Element) throws -> Bool) rethrows -> [Self.Element] {
        try filter(isIncluded)
    }

    /// The elements `isExcluded` doesn't hold for, in order.
    func exclude(_ isExcluded: (Self.Element) throws -> Bool) rethrows -> [Self.Element] {
        try filter { try !isExcluded($0) }
    }

    /// `reduce`, by a name that says the result builds up.
    func accumulate<Result>(
        into initialResult: Result,
        _ nextPartialResult: (Result, Self.Element) throws -> Result
    ) rethrows -> Result {
        try reduce(initialResult, nextPartialResult)
    }
}
