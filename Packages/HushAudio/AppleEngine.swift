import AudioToolbox
import Foundation

func monoOrStereoFloat(_ sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
}

/// Apple's on-device voice isolation (AUSoundIsolation), run inside our own chain.
/// Independent of the system "Mic Mode" setting. Mono, 48 kHz.
// ponytail: no NoiseEngine protocol yet — one engine. Extract it when DeepFilterNet lands (M4).
public final class AppleEngine: @unchecked Sendable {
    private let unit: AudioUnit
    private var input: UnsafePointer<Float>?
    private var sampleTime = 0.0
    public private(set) var latencyFrames = 0
    /// Every parameter the unit exposes on this macOS version, for Diagnostics.
    public private(set) var parameterDump = ""

    public init(sampleRate: Double, maxFrames: Int) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw HushError("AUSoundIsolation not found") }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "Create AUSoundIsolation")
        unit = instance!

        var format = monoOrStereoFloat(sampleRate, channels: 1)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize), "Set engine input format")
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, formatSize), "Set engine output format")
        var maxFrames = UInt32(maxFrames)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4), "Set engine max frames")
        var callback = AURenderCallbackStruct(inputProc: engineInput, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set engine input callback")
        try check(AudioUnitInitialize(unit), "Initialize AUSoundIsolation")

        var latency = 0.0, size = UInt32(MemoryLayout<Double>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size)
        latencyFrames = Int((latency * sampleRate).rounded())
        parameterDump = dumpParameters()
        AudioUnitSetParameter(unit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0,
                              Float(kAUSoundIsolationSoundType_Voice), 0)
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// 0…100. Thread-safe; callers ramp it in small steps to avoid zipper noise.
    public func setWetDry(percent: Float) {
        AudioUnitSetParameter(unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, percent, 0)
    }

    /// Real-time safe. `input` and `output` must not overlap.
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int) {
        self.input = input
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        sampleTime += Double(frames)
        var flags = AudioUnitRenderActionFlags()
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: output))
        let status = AudioUnitRender(unit, &flags, &timestamp, 0, UInt32(frames), &list)
        if status != noErr {
            memcpy(output, input, frames * 4)  // fail open: raw mic rather than silence
        } else if let rendered = list.mBuffers.mData, rendered != UnsafeMutableRawPointer(output) {
            memcpy(output, rendered, frames * 4)
        }
    }

    fileprivate func supplyInput(_ ioData: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard let input else { return }
        if let destination = ioData.pointee.mBuffers.mData {
            memcpy(destination, input, frames * 4)
        } else {
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: input)
        }
        ioData.pointee.mBuffers.mDataByteSize = UInt32(frames * 4)
    }

    private func dumpParameters() -> String {
        var size: UInt32 = 0
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, nil) == noErr,
              size > 0 else { return "(no parameters)" }
        var ids = [AudioUnitParameterID](repeating: 0, count: Int(size) / MemoryLayout<AudioUnitParameterID>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &ids, &size)
        return ids.map { id in
            var info = AudioUnitParameterInfo(), infoSize = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &info, &infoSize)
            let name = info.cfNameString.map { $0.takeUnretainedValue() as String } ?? "?"
            var value: AudioUnitParameterValue = 0
            AudioUnitGetParameter(unit, id, kAudioUnitScope_Global, 0, &value)
            return "id \(id) \"\(name)\" range \(info.minValue)…\(info.maxValue) default \(info.defaultValue) current \(value) unit \(info.unit.rawValue)"
        }.joined(separator: "\n")
    }
}

private let engineInput: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    Unmanaged<AppleEngine>.fromOpaque(refCon).takeUnretainedValue().supplyInput(ioData, frames: Int(frames))
    return noErr
}
