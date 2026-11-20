import Foundation
import Testing
@testable import HushAudio

@Test func ringBufferRoundTripsAndRefusesOverflow() {
    let ring = RingBuffer(minimumCapacity: 8)
    let block: [Float] = [1, 2, 3, 4, 5, 6]
    #expect(ring.write(block, count: 6))
    #expect(!ring.write(block, count: 6))   // would overflow: dropped whole
    #expect(ring.fill == 6)
    #expect(ring.sample(ring.readIndex + 5) == 6)
    ring.advance(6)
    #expect(ring.write(block, count: 6))    // wraps
    #expect(ring.sample(ring.readIndex + 5) == 6)
}

/// 60 simulated seconds: a 44.1 kHz mic whose clock runs 300 ppm fast feeding a 48 kHz output.
/// The buffer must hold its fill level, never under/overrun, and the output must stay a clean sine.
@Test func resamplerTracksDriftWithoutGlitches() {
    let inRate = 44_100.0 * 1.0003, outRate = 48_000.0, block = 256
    let ring = RingBuffer(minimumCapacity: 44_100)
    let target = 256 + 236 + 132
    let resampler = DriftResampler(ring: ring, inputRate: 44_100, outputRate: outRate, targetFill: target)
    var input = [Float](repeating: 0, count: block), output = [Float](repeating: 0, count: block)
    var phase = 0.0, written = 0, maxJump: Float = 0, previous: Float = 0, started = false
    let step = 2 * Double.pi * 440 / inRate
    let maxCleanJump = Float(2 * Double.pi * 440 / outRate * 1.05)

    for outBlock in 0..<Int(60 * outRate) / block {
        let now = Double(outBlock * block) / outRate
        while Double(written + block) / inRate <= now {   // mic delivers blocks on its own clock
            for i in 0..<block { input[i] = Float(sin(phase)); phase += step }
            ring.write(input, count: block)
            written += block
        }
        resampler.read(into: &output, frames: block)
        if now > 1 {   // after start-up fade-in
            for sample in output {
                if started { maxJump = max(maxJump, abs(sample - previous)) }
                previous = sample
                started = true
            }
        }
    }
    #expect(resampler.underruns == 0)
    #expect(resampler.overruns == 0)
    #expect(maxJump < maxCleanJump)   // a dropped or repeated sample would exceed this
    #expect(abs(resampler.driftPPM - 300) < 60)
    #expect(abs(resampler.fillSeconds * 44_100 - Double(target)) < 64)
}

/// Apple's engine really removes noise on this Mac: white noise in, far less out.
@Test func appleEngineAttenuatesNoise() throws {
    let engine = try AppleEngine(sampleRate: 48_000, maxFrames: 4096)
    print("AUSoundIsolation latency: \(engine.latencyFrames) frames\n\(engine.parameterDump)")
    engine.setWetDry(percent: 100)
    var input = [Float](repeating: 0, count: 256), output = [Float](repeating: 0, count: 256)
    var inEnergy = 0.0, outEnergy = 0.0
    for block in 0..<Int(3 * 48_000) / 256 {
        for i in 0..<256 { input[i] = Float.random(in: -0.1...0.1) }
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in engine.process(src.baseAddress!, dst.baseAddress!, frames: 256) }
        }
        if block > 200 {   // skip the first second while the model settles
            inEnergy += input.reduce(0) { $0 + Double($1 * $1) }
            outEnergy += output.reduce(0) { $0 + Double($1 * $1) }
        }
    }
    let reductionDB = 10 * log10(inEnergy / max(outEnergy, 1e-12))
    print("Noise reduction on white noise: \(reductionDB) dB")
    #expect(reductionDB > 12)
}
