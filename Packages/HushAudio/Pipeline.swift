import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// The whole signal chain:
///   mic (any rate) → ring buffer → [Hush Feed's clock] drift-correcting resample to 48 kHz
///   → noise engine (crossfaded against the raw signal) → gain/mute → meter → Hush Feed (stereo).
/// Capture runs on the mic's audio thread; everything else on Hush Feed's audio thread.
public final class Pipeline: @unchecked Sendable {
    public static let sampleRate = 48_000.0
    static let ioFrames: UInt32 = 256   // ~5 ms; hardware knob, tune per interface if it crackles
    static let maxFrames = 4096

    // Controls: written from the main thread, read on the audio thread.
    private let enabledFlag = Atomic<Bool>(true)
    private let mutedFlag = Atomic<Bool>(false)
    /// Noise removal on/off. Off = raw mic passes through (never silence).
    public var enabled: Bool {
        get { enabledFlag.load(ordering: .relaxed) }
        set { enabledFlag.store(newValue, ordering: .relaxed) }
    }
    /// Hard mute: silence regardless of engine state.
    public var muted: Bool {
        get { mutedFlag.load(ordering: .relaxed) }
        set { mutedFlag.store(newValue, ordering: .relaxed) }
    }

    private let highPassOn = Atomic<Bool>(false)
    private let highPassHzBits = Atomic<UInt32>(Float(80).bitPattern)
    private let inputGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let outputGainBits = Atomic<UInt32>(Float(1).bitPattern)
    /// Optional rumble filter ahead of the noise engine (12 dB/octave).
    public func setHighPass(enabled: Bool, hz: Float) {
        highPassOn.store(enabled, ordering: .relaxed)
        highPassHzBits.store(max(20, min(500, hz)).bitPattern, ordering: .relaxed)
    }
    /// Input trim is applied before the engine, output trim after it. Both ramp, never jump.
    public func setGains(inputDB: Float, outputDB: Float) {
        inputGainBits.store(pow(10, inputDB / 20).bitPattern, ordering: .relaxed)
        outputGainBits.store(pow(10, outputDB / 20).bitPattern, ordering: .relaxed)
    }

    // Meter: written on the audio thread, read from the main thread.
    private let peakBits = Atomic<UInt32>(0)
    private let meanSquareBits = Atomic<UInt32>(0)
    /// Post-processing level in dBFS (floor −120).
    public var meter: (rms: Float, peak: Float) {
        let peak = Float(bitPattern: peakBits.load(ordering: .relaxed))
        let meanSquare = Float(bitPattern: meanSquareBits.load(ordering: .relaxed))
        return (max(-120, 10 * log10(meanSquare + 1e-12)), max(-120, 20 * log10(peak + 1e-6)))
    }

    public private(set) var engine: AppleEngine?
    public private(set) var engineError: String?
    public private(set) var deepFilter: DeepFilterEngine?
    public private(set) var deepFilterError: String?
    private let selectedEngine = Atomic<Int>(0)   // 0 = Apple, 1 = DeepFilterNet
    /// Which engine apps hear. Switching warms the incoming engine up, then crossfades (no click).
    public var engineID: EngineID {
        get { selectedEngine.load(ordering: .relaxed) == 1 ? .deepFilter : .apple }
        set { selectedEngine.store(newValue == .deepFilter ? 1 : 0, ordering: .relaxed) }
    }
    public private(set) var resampler: DriftResampler?
    public private(set) var isRunning = false
    private var ioLatencyFrames = 0

    /// Estimated mic-to-app delay added by Hush, in milliseconds.
    public var latencyMs: Double {
        guard let resampler else { return 0 }
        let active: NoiseEngine? = engineID == .deepFilter ? (deepFilter ?? engine) : (engine ?? deepFilter)
        return 1000 * (resampler.fillSeconds + Double(ioLatencyFrames + (active?.latencyFrames ?? 0)) / Self.sampleRate)
    }

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var ring: RingBuffer?
    private var captureList: UnsafeMutableAudioBufferListPointer?
    private var channel = 0
    private let dry = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let wet = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let wet2 = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private var engineMix: Float = 0      // 0 = Apple, 1 = DeepFilterNet
    private var engineTarget: Float = 0
    private var warmup = 0                // frames the incoming engine still runs before the crossfade starts
    // Audio-thread state.
    private var mix: Float = 1    // 0 = raw, 1 = engine
    private var gain: Float = 1
    private var heldPeak: Float = 0
    private var inputGain: Float = 1
    private var highPassMix: Float = 0          // 0 = filter out of circuit, 1 = in
    private var highPassHz: Float = 0           // frequency the coefficients below were computed for
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
    private var meanSquare: Float = 0

    // Test recorder taps: filled on the audio thread while `recording`, drained by recordTest().
    private let recording = Atomic<Bool>(false)
    private let rawTap = RingBuffer(minimumCapacity: 96_000)
    private let processedTap = RingBuffer(minimumCapacity: 96_000)

    // Listen (self-monitoring): the processed signal is copied here and played out by a third audio unit
    // on the headphone device, with its own drift correction because that device has its own clock.
    private let monitoring = Atomic<Bool>(false)
    private let monitorRing = RingBuffer(minimumCapacity: 48_000)
    private var monitorResampler: DriftResampler?
    private var monitorUnit: AudioUnit?
    private let monitorScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    public var isMonitoring: Bool { monitorUnit != nil }

    public init() {}

    deinit {
        stop()
        stopMonitor()
        monitorScratch.deallocate()
        dry.deallocate()
        wet.deallocate()
        wet2.deallocate()
    }

    /// Starts (or restarts) the chain. `channel` is zero-based.
    public func start(input: AudioDeviceID, channel: Int, output: AudioDeviceID) throws {
        stop()
        do {
            let inputRate = Devices.sampleRate(input)
            guard inputRate > 0 else { throw HushError("Can't read the mic's sample rate") }
            Devices.setBufferFrames(input, Self.ioFrames)
            Devices.setBufferFrames(output, Self.ioFrames)
            let inFrames = Devices.bufferFrames(input), outFrames = Devices.bufferFrames(output)

            // Cushion: one capture block + one render block + 3 ms of scheduling slack.
            let target = inFrames + Int(Double(outFrames) * inputRate / Self.sampleRate) + Int(inputRate * 0.003)
            let ring = RingBuffer(minimumCapacity: Int(inputRate))
            self.ring = ring
            resampler = DriftResampler(ring: ring, inputRate: inputRate, outputRate: Self.sampleRate, targetFill: target)
            ioLatencyFrames = outFrames

            if engine == nil {
                do { engine = try AppleEngine(sampleRate: Self.sampleRate, maxFrames: Self.maxFrames); engineError = nil }
                catch { engineError = "\(error)" }  // chain still runs as passthrough
            }
            if deepFilter == nil {
                do { deepFilter = try DeepFilterEngine(); deepFilterError = nil }
                catch { deepFilterError = "\(error)" }
            }
            engineTarget = Self.engineTarget(selected: selectedEngine.load(ordering: .relaxed), apple: engine, deepFilter: deepFilter)
            engineMix = engineTarget   // start on the chosen engine, no crossfade
            warmup = 0

            let inUnit = try Self.makeHAL(device: input, isInput: true)
            inputUnit = inUnit
            var deviceFormat = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size), "Read mic format")
            let channels = Int(deviceFormat.mChannelsPerFrame)
            guard channel < channels else { throw HushError("Input channel \(channel + 1) doesn't exist on this device") }
            self.channel = channel
            var clientFormat = monoOrStereoFloat(inputRate, channels: UInt32(channels))
            try check(AudioUnitSetProperty(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientFormat, size), "Set capture format")
            captureList = AudioBufferList.allocate(maximumBuffers: channels)
            var callback = AURenderCallbackStruct(inputProc: captureCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            let callbackSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            try check(AudioUnitSetProperty(inUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, callbackSize), "Set capture callback")

            let outUnit = try Self.makeHAL(device: output, isInput: false)
            outputUnit = outUnit
            var outFormat = monoOrStereoFloat(Self.sampleRate, channels: 2)
            try check(AudioUnitSetProperty(outUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outFormat, size), "Set render format")
            callback.inputProc = renderCallback
            try check(AudioUnitSetProperty(outUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, callbackSize), "Set render callback")

            try check(AudioUnitInitialize(inUnit), "Open mic")
            try check(AudioUnitInitialize(outUnit), "Open Hush Feed")
            try check(AudioOutputUnitStart(outUnit), "Start Hush Feed")
            try check(AudioOutputUnitStart(inUnit), "Start mic")
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        for unit in [inputUnit, outputUnit].compactMap({ $0 }) {
            AudioOutputUnitStop(unit)   // synchronous: no callback is running after this returns
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        inputUnit = nil
        outputUnit = nil
        captureList.map { free($0.unsafeMutablePointer) }
        captureList = nil
        isRunning = false
        peakBits.store(0, ordering: .relaxed)
        meanSquareBits.store(0, ordering: .relaxed)
    }

    /// Records the raw mic and what apps hear, side by side, as two 48 kHz mono WAVs for A/B listening.
    /// (The processed file lags the raw one by the engine's latency.)
    public func recordTest(seconds: Double, directory: URL) async throws -> [URL] {
        guard isRunning else { throw HushError("Audio isn't running") }
        guard !recording.load(ordering: .relaxed) else { throw HushError("A test recording is already in progress") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: .now)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
        ]
        let taps = [rawTap, processedTap]
        let urls = ["raw", "processed"].map { directory.appending(path: "\(stamp) \($0).wav") }
        let files = try urls.map { try AVAudioFile(forWriting: $0, settings: settings) }
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!,
                                      frameCapacity: 48_000)!
        let samples = buffer.floatChannelData![0]
        for tap in taps { while tap.read(into: samples, count: 48_000) > 0 {} }   // discard anything stale

        recording.store(true, ordering: .relaxed)
        defer { recording.store(false, ordering: .relaxed) }
        let total = Int(seconds * Self.sampleRate)
        var written = [0, 0]
        while written.min()! < total {
            try await Task.sleep(for: .milliseconds(100))
            guard isRunning else { throw HushError("Audio stopped during the test recording") }
            for i in 0..<2 {
                let n = taps[i].read(into: samples, count: min(48_000, total - written[i]))
                guard n > 0 else { continue }
                buffer.frameLength = AVAudioFrameCount(n)
                try files[i].write(from: buffer)
                written[i] += n
            }
        }
        return urls
    }

    /// Plays exactly what apps hear (after engine, gain, and mute) to `output`, e.g. headphones.
    /// Adds a little more delay on top of Hush's own, so your voice comes back as a short echo.
    public func startMonitor(output: AudioDeviceID) throws {
        stopMonitor()
        do {
            Devices.setBufferFrames(output, Self.ioFrames)
            let frames = Devices.bufferFrames(output)
            while monitorRing.read(into: monitorScratch, count: Self.maxFrames) > 0 {}   // discard stale audio
            monitorResampler = DriftResampler(ring: monitorRing, inputRate: Self.sampleRate, outputRate: Self.sampleRate,
                                              targetFill: Int(Self.ioFrames) + frames + 144)
            let unit = try Self.makeHAL(device: output, isInput: false)
            monitorUnit = unit
            // 48 kHz stereo on our side; AUHAL converts to whatever rate and layout the device runs at.
            var format = monoOrStereoFloat(Self.sampleRate, channels: 2)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set monitor format")
            var callback = AURenderCallbackStruct(inputProc: monitorCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set monitor callback")
            try check(AudioUnitInitialize(unit), "Open monitor output")
            try check(AudioOutputUnitStart(unit), "Start monitor output")
            monitoring.store(true, ordering: .relaxed)
        } catch {
            stopMonitor()
            throw error
        }
    }

    public func stopMonitor() {
        monitoring.store(false, ordering: .relaxed)
        if let unit = monitorUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        monitorUnit = nil
    }

    fileprivate func renderMonitor(_ ioData: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        let n = Int(frames)
        guard let monitorResampler, n <= Self.maxFrames else {
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return noErr
        }
        monitorResampler.read(into: monitorScratch, frames: n)
        for buffer in buffers { memcpy(buffer.mData, monitorScratch, n * 4) }
        return noErr
    }

    private static func engineTarget(selected: Int, apple: AppleEngine?, deepFilter: DeepFilterEngine?) -> Float {
        (selected == 1 && deepFilter != nil) || apple == nil ? 1 : 0
    }

    /// Plain AUHAL — deliberately NOT the Voice Processing I/O unit (that triggers Mic Modes and ducking).
    private static func makeHAL(device: AudioDeviceID, isInput: Bool) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw HushError("AUHAL not found") }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "Create AUHAL")
        let unit = instance!
        if isInput {
            var on: UInt32 = 1, off: UInt32 = 0
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4), "Enable capture")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4), "Disable playback")
        }
        var device = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)), "Select audio device")
        return unit
    }

    // MARK: Audio threads — no allocation, locks, or logging below.

    fileprivate func capture(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             _ timestamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let inputUnit, let captureList, let ring else { return noErr }
        for i in 0..<captureList.count {
            captureList[i].mData = nil   // AUHAL lends us its own buffers
            captureList[i].mDataByteSize = frames * 4
        }
        let status = AudioUnitRender(inputUnit, flags, timestamp, 1, frames, captureList.unsafeMutablePointer)
        guard status == noErr, let data = captureList[channel].mData else { return status }
        ring.write(data.assumingMemoryBound(to: Float.self), count: Int(frames))
        return noErr
    }

    fileprivate func render(_ ioData: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        let n = Int(frames)
        guard let resampler, n <= Self.maxFrames else {
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return noErr
        }
        resampler.read(into: dry, frames: n)
        let isRecording = recording.load(ordering: .relaxed)
        if isRecording { rawTap.write(dry, count: n) }

        // Input trim + high-pass. The filter always runs so switching it in/out is a 50 ms blend, not a click.
        let hz = Float(bitPattern: highPassHzBits.load(ordering: .relaxed))
        if hz != highPassHz {
            highPassHz = hz
            let w = 2 * Double.pi * Double(hz) / Self.sampleRate, alpha = sin(w) / (2 * 0.7071), a0 = 1 + alpha
            b0 = (1 + cos(w)) / 2 / a0; b1 = -(1 + cos(w)) / a0; b2 = b0
            a1 = -2 * cos(w) / a0; a2 = (1 - alpha) / a0
        }
        let highPassTarget: Float = highPassOn.load(ordering: .relaxed) ? 1 : 0
        let inputTarget = Float(bitPattern: inputGainBits.load(ordering: .relaxed))
        let blendStep = 1 / Float(0.05 * Self.sampleRate)
        for i in 0..<n {
            if inputGain != inputTarget {
                inputGain += (inputTarget - inputGain) * 0.002
                if abs(inputTarget - inputGain) < 1e-5 { inputGain = inputTarget }
            }
            if highPassMix != highPassTarget {
                highPassMix = highPassTarget > highPassMix ? min(1, highPassMix + blendStep) : max(0, highPassMix - blendStep)
            }
            let x = Double(dry[i] * inputGain)
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            dry[i] = Float(x + Double(highPassMix) * (y - x))
        }

        if engine == nil && deepFilter == nil {
            memcpy(wet, dry, n * 4)   // fail open: raw mic
        } else {
            // Engine selection. Only the selected engine runs, except during a switch: the incoming one
            // runs alongside for a 300 ms warm-up, then a 50 ms equal-power crossfade.
            let wanted = Self.engineTarget(selected: selectedEngine.load(ordering: .relaxed), apple: engine, deepFilter: deepFilter)
            if wanted != engineTarget { engineTarget = wanted; warmup = Int(0.3 * Self.sampleRate) }
            if engineMix < 1 || engineTarget == 0 {
                if let engine { engine.process(dry, wet, frames: n) } else { memcpy(wet, dry, n * 4) }
            }
            if engineMix > 0 || engineTarget == 1, let deepFilter { deepFilter.process(dry, wet2, frames: n) }
            let step = 1 / Float(0.05 * Self.sampleRate)
            if warmup > 0 { warmup -= n }
            for i in 0..<n {
                if warmup <= 0, engineMix != engineTarget {
                    engineMix = engineTarget > engineMix ? min(1, engineMix + step) : max(0, engineMix - step)
                }
                if engineMix >= 1 {
                    wet[i] = wet2[i]
                } else if engineMix > 0 {
                    let angle = engineMix * .pi / 2
                    wet[i] = wet[i] * cos(angle) + wet2[i] * sin(angle)
                }
            }

            // Bypass. ponytail: the engine keeps running while bypassed so toggling is instant and click-free.
            // Costs idle CPU; skip processing once mix has settled at 0 if that ever matters.
            let target: Float = enabledFlag.load(ordering: .relaxed) ? 1 : 0
            for i in 0..<n {
                if mix != target { mix = target > mix ? min(target, mix + step) : max(target, mix - step) }
                if mix <= 0 {
                    wet[i] = dry[i]
                } else if mix < 1 {
                    let angle = mix * .pi / 2
                    wet[i] = dry[i] * cos(angle) + wet[i] * sin(angle)
                }
            }
        }

        let gainTarget: Float = mutedFlag.load(ordering: .relaxed) ? 0 : Float(bitPattern: outputGainBits.load(ordering: .relaxed))
        let gainStep = 1 / Float(0.01 * Self.sampleRate)   // 10 ms mute ramp
        var peak: Float = 0, sum: Float = 0
        for i in 0..<n {
            if gain != gainTarget { gain = gainTarget > gain ? min(gainTarget, gain + gainStep) : max(gainTarget, gain - gainStep) }
            let sample = wet[i] * gain
            wet[i] = sample
            peak = max(peak, abs(sample))
            sum += sample * sample
        }
        heldPeak = max(peak, heldPeak * 0.98)
        meanSquare += 0.1 * (sum / Float(max(n, 1)) - meanSquare)
        peakBits.store(heldPeak.bitPattern, ordering: .relaxed)
        meanSquareBits.store(meanSquare.bitPattern, ordering: .relaxed)

        if isRecording { processedTap.write(wet, count: n) }
        if monitoring.load(ordering: .relaxed) { monitorRing.write(wet, count: n) }
        for buffer in buffers { memcpy(buffer.mData, wet, n * 4) }   // mono → both channels
        return noErr
    }
}

private let captureCallback: AURenderCallback = { refCon, flags, timestamp, _, frames, _ in
    Unmanaged<Pipeline>.fromOpaque(refCon).takeUnretainedValue().capture(flags, timestamp, frames: frames)
}

private let renderCallback: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    return Unmanaged<Pipeline>.fromOpaque(refCon).takeUnretainedValue().render(ioData, frames: frames)
}

private let monitorCallback: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    return Unmanaged<Pipeline>.fromOpaque(refCon).takeUnretainedValue().renderMonitor(ioData, frames: frames)
}
