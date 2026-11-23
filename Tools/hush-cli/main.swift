// Offline WAV processor using exactly the engines the app uses, for A/B comparisons and regression tests.
//   hush-cli process --engine apple|deepFilter --strength light|medium|max in.wav out.wav
import AVFAudio
import HushAudio

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("hush-cli: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    defer { arguments.removeSubrange(index...index + 1) }
    return arguments[index + 1]
}
guard let engineID = EngineID(rawValue: option("--engine") ?? "apple") else { fail("--engine must be apple or deepFilter") }
guard let strength = Strength(rawValue: option("--strength") ?? "medium") else { fail("--strength must be light, medium, or max") }
guard arguments.count == 3, arguments[0] == "process" else {
    fail("usage: hush-cli process --engine apple|deepFilter --strength light|medium|max in.wav out.wav")
}

do {
    let input = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[1]))
    let format = input.processingFormat
    // ponytail: 48 kHz mono only (what the test recorder writes). Add a converter if other files matter.
    guard format.sampleRate == 48_000, format.channelCount == 1 else { fail("input must be 48 kHz mono") }

    let engine: NoiseEngine
    switch engineID {
    case .apple:
        let apple = try AppleEngine(sampleRate: 48_000, maxFrames: 4096)
        apple.setWetDry(percent: strength.wetDryPercent)
        engine = apple
    case .deepFilter:
        let deepFilter = try DeepFilterEngine()
        deepFilter.setAttenuation(dB: strength.attenuationDB)
        engine = deepFilter
    }

    let output = try AVAudioFile(forWriting: URL(fileURLWithPath: arguments[2]), settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
    ])
    let block: AVAudioFrameCount = 256
    let inBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)!
    let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)!
    while input.framePosition < input.length {
        try input.read(into: inBuffer, frameCount: block)
        guard inBuffer.frameLength > 0 else { break }
        engine.process(inBuffer.floatChannelData![0], outBuffer.floatChannelData![0], frames: Int(inBuffer.frameLength))
        outBuffer.frameLength = inBuffer.frameLength
        try output.write(from: outBuffer)
    }
    print("\(engineID.rawValue) \(strength.rawValue): wrote \(arguments[2]) (engine latency \(engine.latencyFrames) frames)")
} catch {
    fail("\(error)")
}
