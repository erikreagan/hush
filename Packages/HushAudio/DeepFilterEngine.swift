import CDeepFilter
import Foundation
import Synchronization

public enum EngineID: String, CaseIterable, Identifiable, Sendable {
    case apple, deepFilter
    public var id: Self { self }
}

/// The three presets, and what they mean to each engine. Starting values from the spec — tune by ear.
public enum Strength: String, CaseIterable, Identifiable, Sendable {
    case light, medium, max
    public var id: Self { self }
    /// AUSoundIsolation wet/dry mix.
    public var wetDryPercent: Float { [.light: 60, .medium: 85, .max: 100][self]! }
    /// DeepFilterNet attenuation limit: how many dB of noise it may remove (100 ≈ unlimited).
    public var attenuationDB: Float { [.light: 12, .medium: 24, .max: 100][self]! }
}

/// What the pipeline and hush-cli need from any engine. 48 kHz mono; `process` is called on the audio thread.
public protocol NoiseEngine: AnyObject {
    var latencyFrames: Int { get }
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int)
}

extension AppleEngine: NoiseEngine {}

/// DeepFilterNet 3 (open-source speech enhancement), via libDF's C API. 48 kHz mono, 10 ms frames.
// ponytail: libDF's inference (tract) may allocate on the audio thread. No dropouts seen so far;
// if a soak ever shows them, move inference to a worker thread with a lock-free hand-off.
public final class DeepFilterEngine: NoiseEngine, @unchecked Sendable {
    private let state: OpaquePointer
    private let hop: Int
    private let inBlock: UnsafeMutablePointer<Float>
    private let outBlock: UnsafeMutablePointer<Float>
    private var position = 0
    private let attenuationBits = Atomic<UInt32>(Float(100).bitPattern)
    private var appliedAttenuation: Float = 100
    public let latencyFrames: Int

    /// The DFN3 model: bundled in Hush.app, or straight from the submodule when run from the repo (tests, hush-cli).
    public static var defaultModelPath: String {
        Bundle.main.path(forResource: "DeepFilterNet3_onnx.tar", ofType: "gz")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appending(path: "../../Engines/deepfilter/DeepFilterNet/models/DeepFilterNet3_onnx.tar.gz").standardized.path
    }

    public init(modelPath: String = DeepFilterEngine.defaultModelPath) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else { throw HushError("DeepFilterNet model not found at \(modelPath)") }
        guard let state = df_create(modelPath, 100, nil) else { throw HushError("DeepFilterNet failed to load") }
        self.state = state
        hop = df_get_frame_length(state)
        inBlock = .allocate(capacity: hop)
        outBlock = .allocate(capacity: hop)
        inBlock.initialize(repeating: 0, count: hop)
        outBlock.initialize(repeating: 0, count: hop)
        // One hop of re-blocking delay here + libDF's own delay (measured: see Tests).
        latencyFrames = hop + Self.algorithmicDelayFrames
    }

    /// libDF's internal delay for the DFN3 model, measured by cross-correlating input and output.
    static let algorithmicDelayFrames = 1440

    deinit {
        df_free(state)
        inBlock.deallocate()
        outBlock.deallocate()
    }

    /// Thread-safe: picked up by the audio thread at the next frame.
    public func setAttenuation(dB: Float) { attenuationBits.store(dB.bitPattern, ordering: .relaxed) }

    /// Accepts any buffer size; internally re-blocks to libDF's fixed 480-sample frames.
    public func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            output[i] = outBlock[position]
            inBlock[position] = input[i]
            position += 1
            if position == hop {
                let wanted = Float(bitPattern: attenuationBits.load(ordering: .relaxed))
                if wanted != appliedAttenuation { df_set_atten_lim(state, wanted); appliedAttenuation = wanted }
                _ = df_process_frame(state, inBlock, outBlock)
                position = 0
            }
        }
    }
}
