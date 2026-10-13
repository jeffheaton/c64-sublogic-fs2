/// `value` in uppercase hexadecimal, zero-padded to `width` digits: `String(format: "%0<width>X")`
/// without Foundation (the WebAssembly build links none). For the non-negative values the port
/// prints (addresses, bytes, hashes).
public func hex(_ value: some BinaryInteger, width: Int = 2) -> String {
    let digits = String(UInt64(truncatingIfNeeded: value), radix: 16, uppercase: true)
    return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
}

/// `bytes` as lowercase hexadecimal, two digits per byte (digest strings).
public func hexString(_ bytes: some Sequence<UInt8>) -> String {
    let digits = Array("0123456789abcdef")
    var s = ""
    for b in bytes {
        s.append(digits[Int(b >> 4)])
        s.append(digits[Int(b & 0x0F)])
    }
    return s
}
