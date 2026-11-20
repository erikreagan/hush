import Synchronization

/// Single-producer / single-consumer float ring. Lock-free; no allocation after init.
public final class RingBuffer: @unchecked Sendable {
    private let buf: UnsafeMutablePointer<Float>
    private let mask: Int
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    public let capacity: Int

    public init(minimumCapacity: Int) {
        var c = 1
        while c < minimumCapacity { c <<= 1 }
        capacity = c
        mask = c - 1
        buf = .allocate(capacity: c)
        buf.initialize(repeating: 0, count: c)
    }

    deinit { buf.deallocate() }

    public var fill: Int { written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring) }

    /// Producer side. Drops the whole block (returns false) if it doesn't fit.
    @discardableResult
    public func write(_ src: UnsafePointer<Float>, count n: Int) -> Bool {
        let w = written.load(ordering: .relaxed)
        guard n <= capacity - (w - consumed.load(ordering: .acquiring)) else { return false }
        for i in 0..<n { buf[(w &+ i) & mask] = src[i] }
        written.store(w &+ n, ordering: .releasing)
        return true
    }

    // Consumer side.
    /// Copies out up to `n` frames; returns how many were available.
    public func read(into dst: UnsafeMutablePointer<Float>, count n: Int) -> Int {
        let r = consumed.load(ordering: .relaxed)
        let m = min(n, written.load(ordering: .acquiring) - r)
        for i in 0..<m { dst[i] = buf[(r &+ i) & mask] }
        consumed.store(r &+ m, ordering: .releasing)
        return m
    }
    var readIndex: Int { consumed.load(ordering: .relaxed) }
    @inline(__always) func sample(_ index: Int) -> Float { buf[index & mask] }
    func advance(_ n: Int) { consumed.store(consumed.load(ordering: .relaxed) &+ n, ordering: .releasing) }
}

/// Pulls audio out of a RingBuffer at the output device's pace. One resampler does two jobs:
/// converts the mic's sample rate to the output rate, and nudges that ratio so the buffer
/// stays near `targetFill` even though the two devices' clocks drift apart.
/// All methods are consumer-thread only, except the stats getters.
public final class DriftResampler: @unchecked Sendable {
    private let ring: RingBuffer
    private let nominal: Double  // input frames per output frame
    private let inputRate: Double
    private let outputRate: Double
    public let targetFill: Int
    private var frac = 0.0
    private var smoothedFill: Double
    private var buffering = true
    private var fadeIn = false

    private let underrunCount = Atomic<Int>(0)
    private let overrunCount = Atomic<Int>(0)
    private let ppmX10 = Atomic<Int>(0)
    private let fillNow = Atomic<Int>(0)
    public var underruns: Int { underrunCount.load(ordering: .relaxed) }
    public var overruns: Int { overrunCount.load(ordering: .relaxed) }
    /// Current clock correction in parts per million (≈ measured drift once settled).
    public var driftPPM: Double { Double(ppmX10.load(ordering: .relaxed)) / 10 }
    /// Smoothed buffer fill in seconds (the latency this stage adds).
    public var fillSeconds: Double { Double(fillNow.load(ordering: .relaxed)) / inputRate }

    static let fadeFrames = 64
    static let maxCorrection = 0.005  // ±0.5% — far beyond any real clock drift
    static let loopGain = 0.5         // per second; with 1 s smoothing gives a well-damped loop

    public init(ring: RingBuffer, inputRate: Double, outputRate: Double, targetFill: Int) {
        self.ring = ring
        self.inputRate = inputRate
        self.outputRate = outputRate
        self.nominal = inputRate / outputRate
        self.targetFill = targetFill
        self.smoothedFill = Double(targetFill)
    }

    public func read(into out: UnsafeMutablePointer<Float>, frames n: Int) {
        var fill = ring.fill
        if buffering {
            // (Re)starting: wait until we have a full cushion, then fade in.
            guard fill >= targetFill else { zero(out, 0, n); return }
            buffering = false
            fadeIn = true
            smoothedFill = Double(fill)
        }
        if fill > targetFill * 4 {
            // Overrun (e.g. this side stalled): jump ahead to the target.
            ring.advance(fill - targetFill)
            fill = targetFill
            smoothedFill = Double(fill)
            fadeIn = true
            overrunCount.add(1, ordering: .relaxed)
        }

        smoothedFill += min(1, Double(n) / outputRate) * (Double(fill) - smoothedFill)  // ~1 s time constant
        let error = (smoothedFill - Double(targetFill)) / inputRate                     // seconds too full
        let correction = max(-Self.maxCorrection, min(Self.maxCorrection, error * Self.loopGain))
        let ratio = nominal * (1 + correction)
        ppmX10.store(Int(correction * 1e7), ordering: .relaxed)
        fillNow.store(Int(smoothedFill), ordering: .relaxed)

        // Cubic interpolation reads 4 input samples around each output position.
        var produce = n
        if Double(fill) < frac + ratio * Double(n) + 4 {
            produce = max(0, Int((Double(fill) - 4 - frac) / ratio))
            underrunCount.add(1, ordering: .relaxed)
            buffering = true
        }
        let base = ring.readIndex
        var pos = frac
        for i in 0..<produce {
            let k = Int(pos)
            let t = Float(pos - Double(k))
            let y0 = ring.sample(base + k), y1 = ring.sample(base + k + 1)
            let y2 = ring.sample(base + k + 2), y3 = ring.sample(base + k + 3)
            // ponytail: 4-point Hermite. Clean for drift correction and fine for voice at 44.1→48k;
            // swap in a windowed-sinc if a non-48k mic ever sounds dull or aliased.
            let c1 = 0.5 * (y2 - y0)
            let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
            let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
            out[i] = ((c3 * t + c2) * t + c1) * t + y1
            pos += ratio
        }
        ring.advance(Int(pos))
        frac = pos - Double(Int(pos))

        if fadeIn {
            let f = min(produce, Self.fadeFrames)
            for i in 0..<f { out[i] *= Float(i) / Float(f) }
            fadeIn = false
        }
        if produce < n {
            // Underrun: fade out what we have instead of cutting to silence with a click.
            let f = min(produce, Self.fadeFrames)
            for i in 0..<f { out[produce - 1 - i] *= Float(i) / Float(f) }
            zero(out, produce, n)
            frac = 0
        }
    }

    private func zero(_ out: UnsafeMutablePointer<Float>, _ from: Int, _ to: Int) {
        for i in from..<to { out[i] = 0 }
    }
}
