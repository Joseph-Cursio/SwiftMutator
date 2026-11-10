public extension Sequence {
    /// The number of elements that satisfy `isIncluded`.
    func count(_ isIncluded: (Self.Element) throws -> Bool) rethrows -> Int {
        try include(isIncluded).count
    }

    /// The elements that satisfy `isIncluded`, in order: `filter` under a name that reads beside `exclude`.
    func include(_ isIncluded: (Self.Element) throws -> Bool) rethrows -> [Self.Element] {
        try filter(isIncluded)
    }

    /// The elements that don't satisfy `isExcluded`, in order.
    func exclude(_ isExcluded: (Self.Element) throws -> Bool) rethrows -> [Self.Element] {
        try filter { try !isExcluded($0) }
    }

    /// The elements combined, starting from `initialResult`: `reduce(_:_:)` under another name.
    func accumulate<Result>(
        into initialResult: Result,
        _ nextPartialResult: (Result, Self.Element) throws -> Result
    ) rethrows -> Result {
        try reduce(initialResult, nextPartialResult)
    }
}
