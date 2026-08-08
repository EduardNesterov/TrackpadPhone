import Foundation

/// Everything that can cross the wire.
///
/// Layout (little-endian, byte-packed — no alignment padding anywhere):
///
///     common      u8 version, u8 type
///     touchFrame  + u16 seq, u32 tSensorUs, u8 count, u8 flags, count × contact
///     contact     u8 id, u8 phase, i16 x, i16 y, u16 majorRadius     (8 bytes)
///     hello       + u32 sessionID, f32 widthMM, f32 heightMM, u8 maxContacts
///     keyInput    + u16 keyCode, u8 modifiers, u8 textLength, textLength × u8 (UTF-8)
///     feedback    + u8 kind, u8 intensity
///     alive       — nothing but the header
///
/// A 5-finger frame is 50 bytes, so frames never fragment.
public enum Packet: Sendable, Equatable {
    case touchFrame(TouchFrame)
    case hello(Hello)
    case keyInput(KeyInput)
    case feedback(Feedback)
    /// Mac → phone, in answer to `hello`.
    ///
    /// The only thing the phone can hear that proves the Mac is there. UDP has no session:
    /// a socket is "ready" whether or not anything is listening, so without an answer the
    /// phone's own indicator is only ever reporting that it managed to open a socket. Sent
    /// once per `hello`, which is every two seconds — not per frame, which is what the old
    /// echo did and what made it worth deleting.
    case alive

    enum WireType: UInt8 {
        case touchFrame = 0x01
        case hello = 0x02
        case keyInput = 0x03
        case feedback = 0x11
        case alive = 0x12
    }
}

// MARK: - Fixed point

/// Normalized coordinates are carried as i16 scaled by 2^14, giving a range of ±2.0.
///
/// The headroom is the point: the surface may not span the whole screen, so a finger
/// can legitimately sit outside 0...1, and a full-scale 32767 would clip those reports
/// back to the border. Resolution costs nothing here — 1/16384 of a 71 mm phone is
/// 0.004 mm, far finer than any touch digitizer resolves.
private let coordScale: Float = 16384

@inline(__always)
private func encodeCoord(_ v: Float) -> Int16 {
    // Guard against NaN reaching `Int16(clamping:)`, which would trap.
    guard v.isFinite else { return 0 }
    return Int16(clamping: Int((v * coordScale).rounded()))
}

@inline(__always)
private func decodeCoord(_ v: Int16) -> Float { Float(v) / coordScale }

/// Contact radius in millimetres, 1/256 mm resolution, up to 255 mm.
private let radiusScale: Float = 256

@inline(__always)
private func encodeRadius(_ mm: Float) -> UInt16 {
    guard mm.isFinite, mm > 0 else { return 0 }
    return UInt16(clamping: Int((mm * radiusScale).rounded()))
}

@inline(__always)
private func decodeRadius(_ raw: UInt16) -> Float { Float(raw) / radiusScale }

// MARK: - Encoding

public extension Packet {
    func encode() -> Data {
        var w = ByteWriter()
        w.u8(protocolVersion)

        switch self {
        case .touchFrame(let frame):
            w.u8(WireType.touchFrame.rawValue)
            w.u16(frame.seq)
            w.u32(frame.tSensorUs)
            w.u8(UInt8(min(frame.contacts.count, maxContactsPerFrame)))
            w.u8(frame.flags.rawValue)
            for contact in frame.contacts.prefix(maxContactsPerFrame) {
                w.u8(contact.id)
                w.u8(contact.phase.rawValue)
                w.i16(encodeCoord(contact.x))
                w.i16(encodeCoord(contact.y))
                w.u16(encodeRadius(contact.majorRadiusMM))
            }

        case .hello(let hello):
            w.u8(WireType.hello.rawValue)
            w.u32(hello.sessionID)
            w.f32(hello.surfaceWidthMM)
            w.f32(hello.surfaceHeightMM)
            w.u8(hello.maxContacts)

        case .keyInput(let key):
            w.u8(WireType.keyInput.rawValue)
            w.u16(key.keyCode)
            w.u8(key.modifiers.rawValue)
            let bytes = Array(key.text.utf8.prefix(KeyInput.maxTextBytes))
            w.u8(UInt8(bytes.count))
            for byte in bytes { w.u8(byte) }

        case .feedback(let feedback):
            w.u8(WireType.feedback.rawValue)
            w.u8(feedback.kind.rawValue)
            w.u8(feedback.intensity)

        case .alive:
            w.u8(WireType.alive.rawValue)
        }

        return w.data
    }
}

// MARK: - Decoding

public extension Packet {
    static func decode(_ data: Data) throws -> Packet {
        var r = ByteReader(data)

        let version = try r.u8()
        guard version == protocolVersion else { throw ProtocolError.unsupportedVersion(version) }

        let rawType = try r.u8()
        guard let type = WireType(rawValue: rawType) else { throw ProtocolError.unknownType(rawType) }

        switch type {
        case .touchFrame:
            let seq = try r.u16()
            let tSensorUs = try r.u32()
            let count = Int(try r.u8())
            let flags = FrameFlags(rawValue: try r.u8())
            guard count <= maxContactsPerFrame else { throw ProtocolError.tooManyContacts(count) }

            var contacts: [Contact] = []
            contacts.reserveCapacity(count)
            for _ in 0 ..< count {
                let id = try r.u8()
                let rawPhase = try r.u8()
                let x = decodeCoord(try r.i16())
                let y = decodeCoord(try r.i16())
                let radius = decodeRadius(try r.u16())
                // An unrecognised phase is not worth dropping the frame over — the
                // position is still good, and `moved` is the harmless reading.
                let phase = TouchPhase(rawValue: rawPhase) ?? .moved
                contacts.append(Contact(id: id, phase: phase, x: x, y: y, majorRadiusMM: radius))
            }
            return .touchFrame(TouchFrame(seq: seq, tSensorUs: tSensorUs, flags: flags, contacts: contacts))

        case .hello:
            return .hello(Hello(
                sessionID: try r.u32(),
                surfaceWidthMM: try r.f32(),
                surfaceHeightMM: try r.f32(),
                maxContacts: try r.u8()
            ))

        case .keyInput:
            let keyCode = try r.u16()
            let modifiers = KeyModifiers(rawValue: try r.u8())
            let length = Int(try r.u8())
            var bytes: [UInt8] = []
            bytes.reserveCapacity(length)
            for _ in 0 ..< length { bytes.append(try r.u8()) }
            // Invalid UTF-8 is not worth dropping the packet over when a key code may be
            // the real payload; the modifiers and key still mean something.
            let text = String(decoding: bytes, as: UTF8.self)
            return .keyInput(KeyInput(keyCode: keyCode, modifiers: modifiers, text: text))

        case .feedback:
            let rawKind = try r.u8()
            let intensity = try r.u8()
            // An unknown kind is not worth dropping the packet over: something happened
            // that deserves a buzz, and a plain click is the harmless reading.
            return .feedback(Feedback(kind: FeedbackKind(rawValue: rawKind) ?? .click, intensity: intensity))

        case .alive:
            return .alive
        }
    }
}
