import AudioToolbox
import CoreAudio
import Foundation

/// Captures whatever the Mac is playing.
///
/// Core Audio taps (macOS 14.4+) rather than ScreenCaptureKit: the tap needs only the
/// "System Audio Recording" permission, while ScreenCaptureKit demands full Screen
/// Recording *and* a capture target — a display or window — even when nothing but audio is
/// wanted. Neither needs a virtual audio driver like BlackHole; taps are exactly what Apple
/// added to replace that.
///
/// The shape of it: a tap object produces the audio, an aggregate device wraps the tap so
/// it can be read, and an IO block on that device hands over buffers.
@available(macOS 14.2, *)
public final class AudioCapture {
    public struct Format: Sendable, Equatable {
        public var sampleRate: Double
        public var channels: Int
        /// Frames the driver hands over at a time — the first term in the latency budget.
        public var framesPerBuffer: Int

        public var bufferMilliseconds: Double {
            sampleRate > 0 ? Double(framesPerBuffer) / sampleRate * 1000 : 0
        }
    }

    public enum CaptureError: Error {
        case noOutputDevice
        case tapFailed(OSStatus)
        case aggregateFailed(OSStatus)
        case formatUnavailable(OSStatus)
        case ioFailed(OSStatus)
    }

    /// Interleaved Float32 as Core Audio delivers it, with the host time of the first frame.
    public var onAudio: ((UnsafePointer<Float>, Int, Int, UInt64) -> Void)?

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private(set) public var format: Format?

    public init() {}

    public func start() throws {
        let outputUID = try Self.defaultOutputDeviceUID()

        // A global tap: everything the machine plays, nothing excluded. `.unmuted` matters —
        // the muting variants silence the speakers while capturing, which would be right
        // for a recorder and wrong for us, since the Mac should keep playing normally.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CaptureError.tapFailed(status) }

        // The tap cannot be read directly; it has to be a sub-device of an aggregate.
        // Drift compensation is on because the tap and the output device run on separate
        // clocks even inside one machine.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TrackpadPhone Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw CaptureError.aggregateFailed(status) }

        let streamFormat = try tapFormat()
        format = Format(
            sampleRate: streamFormat.mSampleRate,
            channels: Int(streamFormat.mChannelsPerFrame),
            framesPerBuffer: Int(try bufferFrameSize())
        )

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inputData, inputTime, _, _ in
            guard let self, let onAudio = self.onAudio else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = buffers.first, let data = first.mData else { return }
            let channels = Int(first.mNumberChannels)
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1))
            onAudio(data.assumingMemoryBound(to: Float.self), frames, channels,
                    inputTime.pointee.mHostTime)
        }
        guard status == noErr, let ioProcID else { throw CaptureError.ioFailed(status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw CaptureError.ioFailed(status) }
    }

    public func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    // MARK: - Device queries

    private func tapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw CaptureError.formatUnavailable(status) }
        return format
    }

    private func bufferFrameSize() throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &frames)
        guard status == noErr else { throw CaptureError.formatUnavailable(status) }
        return frames
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else {
            throw CaptureError.noOutputDevice
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr else {
            throw CaptureError.noOutputDevice
        }
        return uid as String
    }
}
