import Rainbow

/// The colours of code, as the operators' documentation shows it.
extension String {
    var asKeyword: String {
        hex("#FF7B72")
    }

    var asDeclaration: String {
        hex("#D2A8FE")
    }

    var asTypeDeclaration: String {
        hex("#79C0FF")
    }

    var onCodeEscape: String {
        onHex("#343940")
    }

    var onCodeBlock: String {
        onHex("#161B22")
    }

    var asComment: String {
        hex("#50575F")
    }
}
