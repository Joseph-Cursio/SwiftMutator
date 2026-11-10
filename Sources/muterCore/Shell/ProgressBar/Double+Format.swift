extension Double {
    func format(_ decimalPartLength: Int, minimumIntegerPartLength: Int = 0) -> String {
        let value = String(self)
        let components = value
            .split { $0 == "." }
            .map { String($0) }

        var integerPart = components.first ?? "0"

        let missingLeadingZeros = minimumIntegerPartLength - integerPart.count
        if missingLeadingZeros > 0 {
            integerPart = stringWithZeros(missingLeadingZeros) + integerPart
        }

        if decimalPartLength == 0 {
            return integerPart
        }

        var decimalPlaces = components.last?.substringWithRange(0, end: decimalPartLength) ?? "0"
        let missingPlaceCount = decimalPartLength - decimalPlaces.count
        decimalPlaces += stringWithZeros(missingPlaceCount)

        return "\(integerPart).\(decimalPlaces)"
    }

    private func stringWithZeros(_ count: Int) -> String {
        Array(repeating: "0", count: count).joined()
    }
}
