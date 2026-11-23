// Prints whether any app is currently listening to Hush Mic. Run before relaunching Hush:
// a relaunch cuts that app's audio for a few seconds.   swift scripts/mic-in-use.swift
import CoreAudio
var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var uid = "Hush_2_UID" as CFString, device = AudioDeviceID(0), size = UInt32(4)
_ = withUnsafePointer(to: &uid) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 8, $0, &size, &device) }
address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
var running = UInt32(0)
AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
print(device == 0 ? "Hush Mic not installed" : running != 0 ? "IN USE" : "idle")
