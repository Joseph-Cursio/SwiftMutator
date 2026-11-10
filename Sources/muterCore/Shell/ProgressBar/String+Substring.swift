extension String {
    func substringWithRange(_ start: Int, end: Int) -> String {
        var end = end
        if start < 0 || start > count {
            return ""
        }
        if end < 0 || end > count {
            end = count
        }
        let range = index(startIndex, offsetBy: start) ..< index(startIndex, offsetBy: end)
        return String(self[range])
    }
}
