extension String {
    /// `bytes` read as UTF-8, with U+FFFD in place of any byte that isn't. For text SwiftMutator didn't write (test
    /// output, logs, source files, project files), where one stray byte mustn't cost the whole text, as the failable
    /// `String(bytes:encoding:)` would.
    init(lossyUTF8 bytes: some Collection<UInt8>) {
        self.init(decoding: bytes, as: UTF8.self)
    }
}
