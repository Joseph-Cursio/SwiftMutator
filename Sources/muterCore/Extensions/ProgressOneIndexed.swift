struct ProgressOneIndexed: ProgressElementType {
    func value(_ progressBar: ProgressBar) -> String {
        let index = progressBar.element + 1 > progressBar.total ?
            progressBar.element :
            progressBar.element + 1
        return "\(index) of \(progressBar.total)"
    }
}
