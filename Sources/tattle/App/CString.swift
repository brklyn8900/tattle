extension String {
    /// The text in a NUL-terminated C buffer, as filled by libc and libproc calls.
    init(cBuffer: [CChar]) {
        self.init(decoding: cBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
