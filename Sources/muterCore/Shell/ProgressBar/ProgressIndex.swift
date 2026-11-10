/// the index element e.g. "2 of 3"
struct ProgressIndex: ProgressElementType {
    func value(_ progressBar: ProgressBar) -> String {
        "\(progressBar.element) of \(progressBar.total)"
    }
}
