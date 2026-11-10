/// an arbitrary string that can be added to the progress bar.
struct ProgressString: ProgressElementType {
    let string: String

    func value(_: ProgressBar) -> String {
        string
    }
}
