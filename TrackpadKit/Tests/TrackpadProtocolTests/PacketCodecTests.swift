import Foundation
import Testing

@testable import TrackpadProtocol

/// One quantization step of the i16 coordinate encoding, with room to spare.
private let coordTolerance: Float = 1e-4

@Suite("Packet codec")
struct PacketCodecTests {
    @Test("Touch frame survives a round trip")
    func touchFrameRoundTrip() throws {
        let frame = TouchFrame(
            seq: 4242,
            tSensorUs: 123_456_789,
            flags: .redundant,
            contacts: [
                Contact(id: 0, phase: .began, x: 0.0, y: 1.0, majorRadiusMM: 4.5),
                Contact(id: 7, phase: .moved, x: 0.5, y: 0.25, majorRadiusMM: 9.0),
                Contact(id: 255, phase: .stationary, x: 0.123_45, y: 0.987_65, majorRadiusMM: 0),
            ]
        )

        guard case .touchFrame(let decoded) = try Packet.decode(Packet.touchFrame(frame).encode()) else {
            Issue.record("decoded to the wrong case")
            return
        }

        #expect(decoded.seq == frame.seq)
        #expect(decoded.tSensorUs == frame.tSensorUs)
        #expect(decoded.flags == frame.flags)
        #expect(decoded.contacts.count == frame.contacts.count)

        for (original, result) in zip(frame.contacts, decoded.contacts) {
            #expect(result.id == original.id)
            #expect(result.phase == original.phase)
            #expect(abs(result.x - original.x) < coordTolerance)
            #expect(abs(result.y - original.y) < coordTolerance)
            #expect(abs(result.majorRadiusMM - original.majorRadiusMM) < 0.01)
        }
    }

    /// The size claim the transport design rests on: frames must never fragment.
    @Test("Frame is 10 + 8N bytes and a full hand fits one datagram")
    func frameSize() {
        for count in 0 ... 5 {
            let contacts = (0 ..< count).map {
                Contact(id: UInt8($0), phase: .moved, x: 0.5, y: 0.5)
            }
            let size = Packet.touchFrame(
                TouchFrame(seq: 1, tSensorUs: 0, contacts: contacts)
            ).encode().count
            #expect(size == 10 + 8 * count)
        }

        let fiveFingers = (0 ..< 5).map { Contact(id: UInt8($0), phase: .moved, x: 0.5, y: 0.5) }
        let size = Packet.touchFrame(TouchFrame(seq: 1, tSensorUs: 0, contacts: fiveFingers)).encode().count
        #expect(size == 50)
        #expect(size < 1200, "must stay well inside the smallest MTU we could meet")
    }

    @Test("Empty frame means all fingers lifted")
    func emptyFrame() throws {
        let encoded = Packet.touchFrame(TouchFrame(seq: 9, tSensorUs: 5, contacts: [])).encode()
        guard case .touchFrame(let decoded) = try Packet.decode(encoded) else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(decoded.contacts.isEmpty)
        #expect(decoded.seq == 9)
    }

    @Test("Hello survives a round trip")
    func helloRoundTrip() throws {
        let hello = Hello(sessionID: 0xDEAD_BEEF, surfaceWidthMM: 71.5, surfaceHeightMM: 155.25, maxContacts: 5)
        guard case .hello(let decoded) = try Packet.decode(Packet.hello(hello).encode()) else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(decoded == hello)
    }


    /// Cyrillic and emoji are the point of routing text as Unicode rather than key codes.
    @Test("Typed text survives a round trip", arguments: ["hello", "Привіт", "🙂 ok", "", "a"])
    func keyInputTextRoundTrip(text: String) throws {
        let input = KeyInput(modifiers: [.command, .shift], text: text)
        guard case .keyInput(let decoded) = try Packet.decode(Packet.keyInput(input).encode()) else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(decoded == input)
    }

    @Test("A named key survives a round trip")
    func keyInputCodeRoundTrip() throws {
        let input = KeyInput(keyCode: 126, modifiers: [.control])
        guard case .keyInput(let decoded) = try Packet.decode(Packet.keyInput(input).encode()) else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(decoded == input)
    }

    /// The length field is one byte, so an over-long string has to be cut on the way out
    /// rather than corrupting the frame.
    @Test("Over-long text is truncated, not mangled")
    func keyInputTextTruncated() throws {
        let input = KeyInput(text: String(repeating: "я", count: 300))
        let encoded = Packet.keyInput(input).encode()
        guard case .keyInput(let decoded) = try Packet.decode(encoded) else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(decoded.text.utf8.count <= KeyInput.maxTextBytes)
        #expect(encoded.count < 256)
    }

    @Test("Feedback survives a round trip", arguments: FeedbackKind.allCases)
    func feedbackRoundTrip(kind: FeedbackKind) throws {
        let feedback = Feedback(kind: kind, intensity: 173)
        guard case .feedback(let decoded) = try Packet.decode(Packet.feedback(feedback).encode()) else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(decoded == feedback)
        #expect(Packet.feedback(feedback).encode().count == 4, "small enough to send on every click")
    }

    /// A future kind must not silently drop the buzz on an older build.
    @Test("An unknown feedback kind decodes as a click")
    func unknownFeedbackKind() throws {
        let bytes = Data([protocolVersion, 0x11, 99, 200])
        guard case .feedback(let decoded) = try Packet.decode(bytes) else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(decoded.kind == .click)
        #expect(decoded.intensity == 200)
    }

    /// A finger dragged past the edge keeps reporting, which is why coordinates are signed.
    @Test("Coordinates outside the surface stay signed and are preserved")
    func outOfBoundsCoordinates() throws {
        let frame = TouchFrame(seq: 1, tSensorUs: 0, contacts: [
            Contact(id: 1, phase: .moved, x: -0.2, y: 1.15),
        ])
        guard case .touchFrame(let decoded) = try Packet.decode(Packet.touchFrame(frame).encode()) else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(abs(decoded.contacts[0].x - -0.2) < coordTolerance)
        #expect(abs(decoded.contacts[0].y - 1.15) < coordTolerance)
    }

    /// Beyond ±2.0 the encoding does clamp. Nothing real reaches that — it is twice the
    /// surface in either direction — but the behaviour should be stated, not discovered.
    @Test("Coordinates clamp at the edge of the representable range")
    func coordinateClamping() throws {
        let frame = TouchFrame(seq: 1, tSensorUs: 0, contacts: [
            Contact(id: 1, phase: .moved, x: -50, y: 50),
        ])
        guard case .touchFrame(let decoded) = try Packet.decode(Packet.touchFrame(frame).encode()) else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(decoded.contacts[0].x < -1.99)
        #expect(decoded.contacts[0].y > 1.99)
    }

    /// UIKit can hand us a NaN if a touch is cancelled mid-update; encoding must not trap.
    @Test("Non-finite coordinates encode as zero rather than trapping")
    func nonFiniteCoordinates() throws {
        let frame = TouchFrame(seq: 1, tSensorUs: 0, contacts: [
            Contact(id: 1, phase: .moved, x: .nan, y: .infinity, majorRadiusMM: .nan),
        ])
        guard case .touchFrame(let decoded) = try Packet.decode(Packet.touchFrame(frame).encode()) else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(decoded.contacts[0].x == 0)
        #expect(decoded.contacts[0].y == 0)
        #expect(decoded.contacts[0].majorRadiusMM == 0)
    }

    @Test("Contact count is capped on the way out")
    func contactCountCapped() throws {
        let tooMany = (0 ..< 20).map { Contact(id: UInt8($0), phase: .moved, x: 0.1, y: 0.1) }
        guard case .touchFrame(let decoded) = try Packet.decode(
            Packet.touchFrame(TouchFrame(seq: 1, tSensorUs: 0, contacts: tooMany)).encode()
        ) else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(decoded.contacts.count == maxContactsPerFrame)
    }
}

@Suite("Malformed input")
struct MalformedInputTests {
    @Test("Truncated packets throw at every prefix length")
    func truncated() {
        let full = Packet.touchFrame(TouchFrame(seq: 1, tSensorUs: 0, contacts: [
            Contact(id: 1, phase: .moved, x: 0.5, y: 0.5),
            Contact(id: 2, phase: .moved, x: 0.6, y: 0.6),
        ])).encode()

        for length in 0 ..< full.count {
            #expect(throws: (any Error).self) {
                _ = try Packet.decode(full.prefix(length))
            }
        }
        #expect(throws: Never.self) { _ = try Packet.decode(full) }
    }

    @Test("Wrong version is rejected")
    func wrongVersion() {
        var bytes = [UInt8](Packet.hello(Hello(sessionID: 1, surfaceWidthMM: 70, surfaceHeightMM: 150, maxContacts: 5)).encode())
        bytes[0] = 99
        #expect(throws: ProtocolError.unsupportedVersion(99)) {
            _ = try Packet.decode(Data(bytes))
        }
    }

    @Test("Unknown packet type is rejected")
    func unknownType() {
        #expect(throws: ProtocolError.unknownType(0x7F)) {
            _ = try Packet.decode(Data([protocolVersion, 0x7F, 0, 0]))
        }
    }

    /// A hostile count field must not make us allocate or read past the buffer.
    @Test("Declared contact count beyond the cap is rejected")
    func contactCountBeyondCap() {
        var w = ByteWriter()
        w.u8(protocolVersion)
        w.u8(0x01)
        w.u16(1)
        w.u32(0)
        w.u8(200)
        w.u8(0)
        #expect(throws: ProtocolError.tooManyContacts(200)) {
            _ = try Packet.decode(w.data)
        }
    }

    @Test("Empty data throws")
    func empty() {
        #expect(throws: ProtocolError.truncated) { _ = try Packet.decode(Data()) }
    }
}

@Suite("Sequence numbers")
struct SequenceNumberTests {
    @Test("Ordinary ordering")
    func ordinary() {
        #expect(isNewer(5, than: 4))
        #expect(!isNewer(4, than: 5))
        #expect(!isNewer(5, than: 5), "a repeat is not newer — that is what dedupes redundant frames")
    }

    /// Plain `>` would stall the stream for 32k frames at the wrap point.
    @Test("Wrap-around is handled")
    func wrapAround() {
        #expect(isNewer(0, than: 65535))
        #expect(isNewer(5, than: 65530))
        #expect(!isNewer(65535, than: 0))
        #expect(!isNewer(65530, than: 5))
    }

    @Test("A full sweep of the sequence space never goes backwards")
    func fullSweep() {
        var previous: UInt16 = 0
        for _ in 0 ..< 70000 {
            let next = previous &+ 1
            #expect(isNewer(next, than: previous))
            previous = next
        }
    }

    @Test("The Mac's answer to hello survives the wire")
    func aliveRoundTrips() throws {
        #expect(try Packet.decode(Packet.alive.encode()) == .alive)
        // Two bytes and no more: it is sent every couple of seconds for as long as the
        // phone is connected, and it says one thing.
        #expect(Packet.alive.encode().count == 2)
    }
}
