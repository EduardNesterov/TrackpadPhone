import Foundation

/// Everything that can cross the wire.
///
/// Layout (little-endian, byte-packed — no alignment padding anywhere):
///
///     common      u8 version, u8 type
///     touchFrame  + u16 seq, u32 tSensorUs, u8 count, u8 flags, count × contact
///     contact     u8 id, u8 phase, i16 x, i16 y, u16 majorRadius     (8 bytes)
///     hello       + u32 sessionID, f32 widthMM, f32 heightMM, u8 maxContacts
///     echoReply   + u16 seq, u32 tSensorUs, u32 tServerUs
///     feedback    + u8 kind, u8 intensity
///
/// A 5-finger frame is 50 bytes, so frames never fragment.
public enum Packet: Sendable, Equatable {
    case touchFrame(TouchFrame)
    case hello(Hello)
    case echoReply(EchoReply)
    case feedback(Feedback)

    enum WireType: UInt8 {
        case touchFrame = 0x01
        case hello = 0x02
        case echoReply = 0x10
        case feedback = 0x11
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

        case .echoReply(let echo):
            w.u8(WireType.echoReply.rawValue)
            w.u16(echo.seq)
            w.u32(echo.tSensorUs)
            w.u32(echo.tServerUs)

        case .feedback(let feedback):
            w.u8(WireType.feedback.rawValue)
            w.u8(feedback.kind.rawValue)
            w.u8(feedback.intensity)
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

        case .echoReply:
            return .echoReply(EchoReply(
                seq: try r.u16(),
                tSensorUs: try r.u32(),
                tServerUs: try r.u32()
            ))

        case .feedback:
            let rawKind = try r.u8()
            let intensity = try r.u8()
            // An unknown kind is not worth dropping the packet over: something happened
            // that deserves a buzz, and a plain click is the harmless reading.
            return .feedback(Feedback(kind: FeedbackKind(rawValue: rawKind) ?? .click, intensity: intensity))
        }
    }
}
