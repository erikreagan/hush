import CoreAudio
import Foundation

public struct HushError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw HushError("\(what) failed (error \(status))") }
}

public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannels: Int
}

/// Thin Core Audio property helpers.
public enum Devices {
    /// UIDs baked into the driver by scripts/build-driver.sh.
    public static let micUID = "Hush_2_UID"   // visible input apps read from
    public static let feedUID = "Hush_UID"    // hidden output Hush writes to

    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T: BitwiseCopyable>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, default value: T) -> T {
        var addr = addr, value = value, size = UInt32(MemoryLayout<T>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = address(selector), size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    public static func uid(of id: AudioDeviceID) -> String { string(id, kAudioDevicePropertyDeviceUID) }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Real input devices. Never includes Hush's own devices (no feedback loops).
    public static func inputDevices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let uid = string(id, kAudioDevicePropertyDeviceUID)
            let channels = inputChannelCount(id)
            guard channels > 0, uid != micUID, uid != feedUID else { return nil }
            return AudioDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName), inputChannels: channels)
        }
    }

    /// Looks a device up by UID. Works for hidden devices too, which never show up in the device list.
    public static func device(uid: String) -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString, id = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cfUID) {
            AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    public static var defaultInput: AudioDeviceID {
        get { get(system, address(kAudioHardwarePropertyDefaultInputDevice), default: AudioDeviceID(kAudioObjectUnknown)) }
        set {
            var addr = address(kAudioHardwarePropertyDefaultInputDevice), id = newValue
            AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        }
    }

    static func sampleRate(_ id: AudioDeviceID) -> Double {
        get(id, address(kAudioDevicePropertyNominalSampleRate), default: 0.0)
    }

    static func bufferFrames(_ id: AudioDeviceID) -> Int {
        Int(get(id, address(kAudioDevicePropertyBufferFrameSize), default: UInt32(512)))
    }

    static func setBufferFrames(_ id: AudioDeviceID, _ frames: UInt32) {
        var addr = address(kAudioDevicePropertyBufferFrameSize), frames = frames
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
    }
}
