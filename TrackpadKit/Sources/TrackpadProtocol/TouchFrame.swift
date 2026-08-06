import Foundation

public enum ProtocolError: Error, Equatable, Sendable {
    case truncated
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case tooManyContacts(Int)
}

/// Wire protocol version. Bump only on incompatible layout changes.
public let protocolVersion: UInt8 = 1

/// Hard ceiling on contacts per frame. Keeps every frame inside one MTU and bounds
/// decode work on hostile input.
public let maxContactsPerFrame = 10

public enum TouchPhase: UInt8, Sendable, Equatable, CaseIterable {
    case began = 0
    case moved = 1
    case stationary = 2
}

public struct FrameFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// This frame is a deliberate retransmit of one already sent. The receiver
    /// dedupes on `seq`; we repeat frames where the contact count changed, because
    /// a lost touch-down or touch-up is the one loss a snapshot protocol can't hide.
    public static let redundant = FrameFlags(rawValue: 1 << 0)
    // bits 1-2 reserved for surface orientation.
}

/// One finger on the surface.
///
/// Coordinates are normalized to the surface (0...1), not points. The physical size
/// travels once in `Hello`, so the Mac works in millimetres and its tuning stays
/// valid across devices and orientations. Values may fall slightly outside 0...1
/// when a finger drags past the edge — that is intentional, hence signed encoding.
public struct Contact: Sendable, Equatable {
    public var id: UInt8
    public var phase: TouchPhase
    public var x: Float
    public var y: Float
    /// Radius of the contact patch in millimetres. Unused in v1; groundwork for palm rejection.
    public var majorRadiusMM: Float

    public init(id: UInt8, phase: TouchPhase, x: Float, y: Float, majorRadiusMM: Float = 0) {
        self.id = id
        self.phase = phase
        self.x = x
        self.y = y
        self.majorRadiusMM = majorRadiusMM
    }
}

/// A complete snapshot of the surface at one instant.
///
/// Deliberately a snapshot rather than a diff: a finger absent from `contacts` has
/// lifted. A dropped packet therefore costs one skipped frame instead of leaving a
/// finger stuck down forever, which is what a delta protocol would do over UDP.
public struct TouchFrame: Sendable, Equatable {
    public var seq: UInt16
    /// Microseconds on the phone's monotonic clock since the session began.
    public var tSensorUs: UInt32
    public var flags: FrameFlags
    public var contacts: [Contact]

    public init(seq: UInt16, tSensorUs: UInt32, flags: FrameFlags = [], contacts: [Contact]) {
        self.seq = seq
        self.tSensorUs = tSensorUs
        self.flags = flags
        self.contacts = contacts
    }
}

/// Sent by the phone when a session starts, and repeated a few times because UDP
/// gives no delivery guarantee and everything downstream depends on it.
public struct Hello: Sendable, Equatable {
    /// Changes on every app launch. `tSensorUs` restarts from zero with it, so the Mac
    /// must discard accumulated timing state when it sees a new session.
    public var sessionID: UInt32
    public var surfaceWidthMM: Float
    public var surfaceHeightMM: Float
    public var maxContacts: UInt8

    public init(sessionID: UInt32, surfaceWidthMM: Float, surfaceHeightMM: Float, maxContacts: UInt8) {
        self.sessionID = sessionID
        self.surfaceWidthMM = surfaceWidthMM
        self.surfaceHeightMM = surfaceHeightMM
        self.maxContacts = maxContacts
    }
}

/// Mac → phone, mirroring a frame's identity so the phone can measure round-trip time.
public struct EchoReply: Sendable, Equatable {
    public var seq: UInt16
    public var tSensorUs: UInt32
    /// Mac-side receive time, for later one-way estimates. Unused while we only need RTT.
    public var tServerUs: UInt32

    public init(seq: UInt16, tSensorUs: UInt32, tServerUs: UInt32) {
        self.seq = seq
        self.tSensorUs = tSensorUs
        self.tServerUs = tServerUs
    }
}

/// Circular comparison for wrapping 16-bit sequence numbers: true when `a` is newer
/// than `b`. Plain `>` would treat the wrap from 65535 to 0 as a huge jump backwards
/// and stall the stream for 32k frames.
public func isNewer(_ a: UInt16, than b: UInt16) -> Bool {
    let delta = a &- b
    return delta != 0 && delta < 0x8000
}
