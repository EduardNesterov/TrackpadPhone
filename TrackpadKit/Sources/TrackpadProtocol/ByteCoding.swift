import Foundation

/// Little-endian byte writer. Both ends are Apple ARM, so LE is the native order,
/// but we spell it out rather than reinterpreting memory — the wire format must not
/// depend on struct layout or alignment.
struct ByteWriter {
    private(set) var bytes: [UInt8]

    init(capacity: Int = 64) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }

    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
    }

    mutating func f32(_ v: Float) { u32(v.bitPattern) }

    var data: Data { Data(bytes) }
}

/// Little-endian byte reader. Every read is bounds-checked: packets arrive from the
/// network and a truncated one must throw, never trap.
struct ByteReader {
    private let bytes: [UInt8]
    private var offset: Int = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard remaining >= n else { throw ProtocolError.truncated }
        defer { offset += n }
        return bytes[offset ..< offset + n]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }

    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        let i = b.startIndex
        return UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        let i = b.startIndex
        return UInt32(b[i])
            | (UInt32(b[i + 1]) << 8)
            | (UInt32(b[i + 2]) << 16)
            | (UInt32(b[i + 3]) << 24)
    }

    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
}
