import Foundation

extension Strength: Codable {}
extension EngineID: Codable {}

/// A named snapshot of the audio settings, so "Desk" and "Laptop" each carry their own microphone and tuning.
/// Everything not listed here (Listen, shortcuts, mute, the on/off switch, …) is not part of a preset.
public struct Preset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var inputUID: String
    public var channel: Int
    public var inputGainDB: Double
    public var highPassEnabled: Bool
    public var highPassHz: Double
    public var outputGainDB: Double
    public var strength: Strength
    public var engine: EngineID

    public init(id: UUID = UUID(), name: String, inputUID: String, channel: Int = 0, inputGainDB: Double = 0, highPassEnabled: Bool = false,
                highPassHz: Double = 80, outputGainDB: Double = 0, strength: Strength = .max, engine: EngineID = .deepFilter) {
        (self.id, self.name, self.inputUID, self.channel) = (id, name, inputUID, channel)
        (self.inputGainDB, self.highPassEnabled, self.highPassHz, self.outputGainDB) = (inputGainDB, highPassEnabled, highPassHz, outputGainDB)
        (self.strength, self.engine) = (strength, engine)
    }
}

public extension Preset {
    /// Where the settings in use are parked when Hush has to switch away from unsaved ("Manual") settings.
    static let lastManualID = UUID(uuidString: "00000000-0000-0000-0000-00004D414E55")!

    /// Same settings, whatever the name. This is how Hush knows which preset (if any) is in use.
    func matches(_ other: Preset) -> Bool {
        var copy = self
        (copy.id, copy.name) = (other.id, other.name)
        return copy == other
    }
}

/// The two rules for moving between presets. List order is the priority order; `connected` holds the UIDs of the mics
/// plugged in; `active` is nil when the settings in use match no preset ("Manual").
public extension [Preset] {
    /// Where to go when the mic in use disconnects: the first other preset whose mic is connected, or nil to stay and wait.
    func fallback(from active: Preset.ID?, connected: Set<String>) -> Preset? {
        first { $0.id != active && connected.contains($0.inputUID) }
    }

    /// "Next preset": the next one after the active whose mic is connected, wrapping round; nil if there is no other.
    /// From Manual, the first one whose mic is connected.
    func next(after active: Preset.ID?, connected: Set<String>) -> Preset? {
        guard let start = firstIndex(where: { $0.id == active }) else { return fallback(from: active, connected: connected) }
        return (1..<Swift.max(count, 1)).map { self[(start + $0) % count] }.first { connected.contains($0.inputUID) }
    }
}
