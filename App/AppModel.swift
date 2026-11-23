import AVFoundation
import AppKit
import CoreAudio
import HushAudio
import Observation
import ServiceManagement
import UserNotifications

/// The one place state changes. The UI calls these today; hotkeys and the Stream Deck socket will later.
@MainActor @Observable
final class AppModel {
    private let pipeline = Pipeline()
    /// `Hush --snapshot out.png` renders the popover to an image and exits, without touching audio or settings.
    static let isSnapshot = CommandLine.arguments.contains("--snapshot")
    private let defaults = isSnapshot ? UserDefaults(suiteName: "com.erikreagan.hush.snapshot")! : .standard
    private var wetDry: Float = 0
    private var rampTask: Task<Void, Never>?
    private var peakHeldAt = Date.distantPast
    let server = ControlServer()

    var devices: [AudioDevice] = []
    var inputUID: String { didSet { defaults.set(inputUID, forKey: "inputUID"); if inputUID != oldValue, !applyingPreset { channel = 0; restart() } } }
    var channel: Int { didSet { defaults.set(channel, forKey: "channel"); if channel != oldValue, !applyingPreset { restart() } } }
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); pipeline.enabled = enabled && !comparing } }
    /// A/B: true while the hold-to-compare button is down (momentary bypass, never saved).
    var comparing = false { didSet { pipeline.enabled = enabled && !comparing } }
    // Settings (all persisted).
    var highPassEnabled: Bool { didSet { defaults.set(highPassEnabled, forKey: "highPassEnabled"); applyProcessing() } }
    var highPassHz: Double { didSet { defaults.set(highPassHz, forKey: "highPassHz"); applyProcessing() } }
    var inputGainDB: Double { didSet { defaults.set(inputGainDB, forKey: "inputGainDB"); applyProcessing() } }
    var outputGainDB: Double { didSet { defaults.set(outputGainDB, forKey: "outputGainDB"); applyProcessing() } }
    var claimDefaultOnLaunch: Bool { didSet { defaults.set(claimDefaultOnLaunch, forKey: "claimDefaultOnLaunch") } }
    var restoreDefaultOnQuit: Bool { didSet { defaults.set(restoreDefaultOnQuit, forKey: "restoreDefaultOnQuit") } }
    var port: Int { didSet { defaults.set(port, forKey: "port") } }
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do { try launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            catch { loginItemError = "\(error.localizedDescription)" }
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
        }
    }
    var loginItemError: String?
    var engineInfo = ""
    private var claimedDefault = false
    private var terminateSignal: DispatchSourceSignal?

    /// Listen: play what apps hear to headphones. Never restored on launch — it must be a deliberate act.
    var listening = false { didSet { if listening != oldValue { applyListening() } } }
    /// Output for Listen; empty = whatever the Mac's current output is.
    var monitorUID: String { didSet { defaults.set(monitorUID, forKey: "monitorUID"); if listening { applyListening() } } }
    var outputDevices: [AudioDevice] = []
    var monitorName = ""
    var monitorError: String?

    // Presets: saved snapshots of the mic, channel, trims, high-pass, strength and engine. Using one copies it into the
    // live settings above; nothing ever writes back into a preset by itself. The preset "in use" is simply the one the
    // live settings match — change any of them and there is none ("Manual") until a preset is used or updated.
    var presets: [Preset] = [] { didSet { savePresets() } }
    /// The preset last used, updated or created: only breaks the tie when several presets hold the same settings.
    private var lastPresetID: Preset.ID? { didSet { savePresets() } }
    var autoSwitchPresets: Bool { didSet { defaults.set(autoSwitchPresets, forKey: "autoSwitchPresets") } }
    var activePreset: Preset? {
        let live = snapshot(id: UUID(), name: "")
        return presets.first { $0.id == lastPresetID && $0.matches(live) } ?? presets.first { $0.matches(live) }
    }
    private var applyingPreset = false
    /// True while the pipeline is running on the chosen mic; lets restart() tell "the mic just went away" from "still waiting".
    private var hadMic = false
    private var micLostTask: Task<Void, Never>?

    // Global shortcuts (system-wide, user-assignable; none by default).
    let hotkeys = Hotkeys()
    var toggleShortcut: Shortcut? { didSet { bindShortcut(1, toggleShortcut, key: "shortcut.toggle") { [weak self] in self?.enabled.toggle() } } }
    var muteShortcut: Shortcut? { didSet { bindShortcut(2, muteShortcut, key: "shortcut.mute") { [weak self] in self?.muted.toggle() } } }
    var cycleShortcut: Shortcut? { didSet { bindShortcut(3, cycleShortcut, key: "shortcut.cycle") { [weak self] in self?.cycleStrength() } } }
    var shortcutError: String?

    var recordingTest = false
    var testResult: String?
    var testFiles: [URL] = []
    var muted = false { didSet { pipeline.muted = muted } }
    var strength: Strength { didSet { defaults.set(strength.rawValue, forKey: "strength"); applyStrength() } }
    var engine: EngineID { didSet { defaults.set(engine.rawValue, forKey: "engine"); pipeline.engineID = engine } }
    var deepFilterAvailable = true

    var error: String?
    var driverInstalled = false
    var hushMicIsDefault = false
    var rms: Float = -120
    var peak: Float = -120
    var peakHold: Float = -120
    var latencyMs = 0.0
    var driftPPM = 0.0
    var underruns = 0
    var overruns = 0
    var engineNote: String?

    /// One line under the title saying what apps are hearing right now.
    var statusLine: String {
        if error != nil { return "Not running" }
        let mic = selectedDevice?.name ?? "your microphone"
        if muted { return "Muted — apps hear silence" }
        if comparing { return "Comparing — raw \(mic)" }
        return enabled ? "Cleaning up \(mic)" : "Off — raw \(mic)"
    }

    var selectedDevice: AudioDevice? { devices.first { $0.uid == inputUID } }

    init() {
        autoSwitchPresets = defaults.object(forKey: "autoSwitchPresets") as? Bool ?? true
        inputUID = defaults.string(forKey: "inputUID") ?? ""
        channel = defaults.integer(forKey: "channel")
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        strength = Strength(rawValue: defaults.string(forKey: "strength") ?? "") ?? .max
        highPassEnabled = defaults.bool(forKey: "highPassEnabled")
        highPassHz = defaults.object(forKey: "highPassHz") as? Double ?? 80
        inputGainDB = defaults.double(forKey: "inputGainDB")
        outputGainDB = defaults.double(forKey: "outputGainDB")
        claimDefaultOnLaunch = defaults.object(forKey: "claimDefaultOnLaunch") as? Bool ?? true
        restoreDefaultOnQuit = defaults.object(forKey: "restoreDefaultOnQuit") as? Bool ?? true
        port = defaults.object(forKey: "port") as? Int ?? 47823
        launchAtLogin = SMAppService.mainApp.status == .enabled
        monitorUID = defaults.string(forKey: "monitorUID") ?? ""
        engine = EngineID(rawValue: defaults.string(forKey: "engine") ?? "") ?? .deepFilter
        pipeline.enabled = enabled
        pipeline.engineID = engine
        wetDry = strength.wetDryPercent
        applyProcessing()

        // Presets. None saved (an upgrade, or a new install) simply means Manual: the settings above carry on as they were.
        if !Self.isSnapshot {
            presets = defaults.data(forKey: "presets").flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
            lastPresetID = defaults.string(forKey: "activePresetID").flatMap(UUID.init)
        }

        if Self.isSnapshot { return }

        // Assigning after init runs the didSet observers, which register the hotkeys with macOS.
        Task {
            toggleShortcut = savedShortcut("shortcut.toggle")
            muteShortcut = savedShortcut("shortcut.mute")
            cycleShortcut = savedShortcut("shortcut.cycle")
        }

        // Quit (menu, logout, or `kill`): hand the default input back before we go silent.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreDefaultInput() }
        }
        signal(SIGTERM, SIG_IGN)
        terminateSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminateSignal?.setEventHandler { NSApplication.shared.terminate(nil) }
        terminateSignal?.resume()

        // Hot-plug: Core Audio tells us whenever a device appears or disappears.
        var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        // Sleep/wake: rebuild the audio units so we never come back stuck on silence.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }

        server.onCommand = { [weak self] in self?.handle(command: $0) }
        server.start(port: UInt16(clamping: port))

        Task {
            if defaults.object(forKey: "launchAtLogin") == nil { launchAtLogin = true }   // spec default: ON
            if await AVCaptureDevice.requestAccess(for: .audio) {
                restart()
            } else {
                error = "Microphone access denied. Allow Hush in System Settings → Privacy & Security → Microphone."
            }
            while !Task.isCancelled {   // ~15 Hz UI + socket refresh
                refresh()
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    func restart() {
        devices = Devices.inputDevices()
        outputDevices = Devices.outputDevices()
        if inputUID.isEmpty {
            // First run: prefer the Audient iD2, else the current system mic. (A saved mic that's
            // unplugged is NOT replaced — Hush goes silent and waits for it, see devicesChanged.)
            let systemDefault = Devices.defaultInput
            let pick = devices.first { $0.name.localizedCaseInsensitiveContains("iD2") }
                ?? devices.first { $0.id == systemDefault } ?? devices.first
            if let pick, pick.uid != inputUID { inputUID = pick.uid; return }   // didSet restarts
        }
        let feed = Devices.device(uid: Devices.feedUID)
        driverInstalled = feed != nil
        guard let feed else {
            pipeline.stop()
            error = "Driver not installed — run scripts/install-driver.sh"
            return
        }
        guard let device = selectedDevice else {
            pipeline.stop()
            error = inputUID.isEmpty ? "No microphone found" : "Microphone disconnected — waiting for it to come back"
            if hadMic { hadMic = false; micLost() }
            return
        }
        do {
            try pipeline.start(input: device.id, channel: min(channel, device.inputChannels - 1), output: feed)
            pipeline.engine?.setWetDry(percent: wetDry)
            pipeline.deepFilter?.setAttenuation(dB: strength.attenuationDB)
            deepFilterAvailable = pipeline.deepFilter != nil
            engineNote = pipeline.engineError.map { "Apple engine unavailable (\($0))" }
                ?? pipeline.deepFilterError.map { "DeepFilterNet unavailable (\($0))" }
            engineInfo = [
                pipeline.engine.map { "Apple: \($0.latencyFrames) frames latency\n\($0.parameterDump)" },
                pipeline.deepFilter.map { "DeepFilterNet 3: \($0.latencyFrames) frames latency" },
            ].compactMap { $0 }.joined(separator: "\n")
            error = nil
            hadMic = true
            micLostTask?.cancel()   // the mic is (back) in use: nothing to fall back from
            claimDefaultInput()
        } catch {
            self.error = "\(error)"
        }
    }

    private func devicesChanged() {
        devices = Devices.inputDevices()
        outputDevices = Devices.outputDevices()
        if listening { applyListening() }   // headphones unplugged or swapped: re-open, or stop cleanly
        // Either something we were waiting for (mic or driver) may be back, or the mic just went away:
        // restart() then stops audio (Hush Mic goes silent, error shown) and calls micLost().
        if error != nil || selectedDevice == nil { restart() }
    }

    /// The mic we were using has gone. With another preset to fall back on, give it 3 seconds to come back (USB blips,
    /// wake from sleep), then switch — one direction only, never back by itself. Otherwise just say so and wait.
    private func micLost() {
        micLostTask?.cancel()
        micLostTask = Task {
            let fallback = { self.autoSwitchPresets ? self.presets.fallback(from: self.activePreset?.id, connected: Set(self.devices.map(\.uid))) : nil }
            if fallback() != nil { try? await Task.sleep(for: .seconds(3)) }
            guard !Task.isCancelled, self.selectedDevice == nil else { return }
            if let next = fallback() {
                var kept = ""
                if self.activePreset == nil {   // Manual: switching would lose these settings, so park them as a preset first
                    let manual = self.snapshot(id: Preset.lastManualID, name: "Last manual settings")
                    self.presets.removeAll { $0.id == manual.id }
                    self.presets.append(manual)
                    kept = " Your manual settings were kept as the preset “\(manual.name)”."
                }
                self.activate(next.id)
                Self.notify("preset-switched", title: "Hush: switched to \(next.name)",
                            body: "The microphone was disconnected. Hush won't switch back by itself." + kept)
            } else {
                Self.notify("mic-lost", title: "Hush: microphone disconnected", body: "Hush Mic is silent until your microphone is plugged back in.")
            }
        }
    }

    private nonisolated static func notify(_ id: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    // MARK: Presets

    func isAvailable(_ preset: Preset) -> Bool { devices.contains { $0.uid == preset.inputUID } }

    /// Uses a preset: copies all of its settings into the live ones at once, replacing whatever was there.
    /// Audio is only interrupted if the mic or channel differs.
    func activate(_ id: Preset.ID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        micLostTask?.cancel()
        let micChanged = preset.inputUID != inputUID || preset.channel != channel
        applyingPreset = true
        lastPresetID = id
        (inputUID, channel) = (preset.inputUID, preset.channel)
        (inputGainDB, outputGainDB) = (preset.inputGainDB, preset.outputGainDB)
        (highPassEnabled, highPassHz) = (preset.highPassEnabled, preset.highPassHz)
        (strength, engine) = (preset.strength, preset.engine)
        applyingPreset = false
        if micChanged {
            hadMic = false   // a preset picked while its mic is away waits for it: that's a choice, not a loss to fall back from
            restart()
        }
    }

    /// New preset from the current settings. Nothing audible changes; it is simply the one in use from now on.
    func addPreset() {
        let new = snapshot(id: UUID(), name: "New Preset")
        presets.append(new)
        lastPresetID = new.id
    }

    /// Overwrites a preset with the current settings — the only way a preset's contents ever change.
    func updatePreset(_ id: Preset.ID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index] = snapshot(id: id, name: presets[index].name)
        lastPresetID = id
    }

    func duplicatePreset(_ id: Preset.ID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        var copy = presets[index]
        (copy.id, copy.name) = (UUID(), copy.name + " copy")
        presets.insert(copy, at: index + 1)
    }

    func renamePreset(_ id: Preset.ID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = name
    }

    /// Deleting the preset in use changes nothing audible: the settings stay, and Hush is in Manual.
    func deletePreset(_ id: Preset.ID) { presets.removeAll { $0.id == id } }

    private func snapshot(id: Preset.ID, name: String) -> Preset {
        Preset(id: id, name: name, inputUID: inputUID, channel: channel, inputGainDB: inputGainDB, highPassEnabled: highPassEnabled,
               highPassHz: highPassHz, outputGainDB: outputGainDB, strength: strength, engine: engine)
    }

    private func savePresets() {
        if Self.isSnapshot { return }
        defaults.set(try? JSONEncoder().encode(presets), forKey: "presets")
        defaults.set(lastPresetID?.uuidString, forKey: "activePresetID")
    }

    func recordTest(seconds: Double = 30) {
        guard !recordingTest else { return }
        recordingTest = true
        testResult = nil
        Task {
            defer { recordingTest = false }
            do {
                let directory = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appending(path: "Hush Tests")
                testFiles = try await pipeline.recordTest(seconds: seconds, directory: directory)
                testResult = "Saved to Music/Hush Tests"
            } catch {
                testResult = "\(error)"
            }
        }
    }

    /// The command layer behind the socket (SPEC §8.1). Returns an error message, or nil on success.
    func handle(command message: [String: Any]) -> String? {
        guard message["type"] as? String == "command", let action = message["action"] as? String else {
            return "Expected a message with type \"command\" and an action"
        }
        let value = message["value"]
        switch action {
        case "toggle": enabled.toggle()
        case "mute": muted.toggle()
        case "setEnabled":
            guard let on = value as? Bool else { return "setEnabled needs a true/false value" }
            enabled = on
        case "setMuted":
            guard let on = value as? Bool else { return "setMuted needs a true/false value" }
            muted = on
        case "setStrength":
            guard let preset = (value as? String).flatMap(Strength.init) else { return "setStrength needs light, medium, or max" }
            strength = preset
        case "cycleStrength": cycleStrength()
        case "setEngine":
            guard let choice = (value as? String).flatMap(EngineID.init) else { return "setEngine needs apple or deepFilter" }
            guard choice == .apple || deepFilterAvailable else { return "DeepFilterNet isn't available" }
            engine = choice
        case "recordTest":   // not in the spec's list: lets tests and tools trigger the test recorder
            recordTest(seconds: value as? Double ?? 30)
        default: return "Unknown action \(action)"
        }
        publishState()
        return nil
    }

    private func publishState() {
        server.publish(topic: "state", [
            "enabled": enabled, "muted": muted, "strength": strength.rawValue, "engine": engine.rawValue,
            "inputConnected": error == nil, "driverInstalled": driverInstalled,
        ], onlyIfChanged: true)
    }

    func cycleStrength() {
        let all = Strength.allCases
        strength = all[(all.firstIndex(of: strength)! + 1) % all.count]
    }

    private func savedShortcut(_ key: String) -> Shortcut? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    private func bindShortcut(_ id: UInt32, _ shortcut: Shortcut?, key: String, action: @escaping () -> Void) {
        defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
        let accepted = hotkeys.bind(id, to: shortcut, action: action)
        shortcutError = accepted ? nil : "macOS wouldn't register \(shortcut?.display ?? "that shortcut") — it may be taken by another app."
    }

    private func applyListening() {
        if Self.isSnapshot { return }
        monitorError = nil
        guard listening else { pipeline.stopMonitor(); return }
        let device = monitorUID.isEmpty ? Devices.defaultOutput : (Devices.device(uid: monitorUID) ?? AudioDeviceID(kAudioObjectUnknown))
        do {
            guard device != kAudioObjectUnknown else { throw CocoaError(.fileNoSuchFile) }
            try pipeline.startMonitor(output: device)
            monitorName = Devices.name(of: device)
        } catch {
            listening = false   // first: turning Listen off re-enters this function, which clears monitorError
            monitorError = "Couldn't play to the Listen output"
        }
    }

    private func applyProcessing() {
        pipeline.setHighPass(enabled: highPassEnabled, hz: Float(highPassHz))
        pipeline.setGains(inputDB: Float(inputGainDB), outputDB: Float(outputGainDB))
    }

    /// Once per launch, and only once audio is actually flowing: make Hush Mic the Mac's default input,
    /// remembering what it replaced.
    private func claimDefaultInput() {
        guard claimDefaultOnLaunch, !claimedDefault, let mic = Devices.device(uid: Devices.micUID) else { return }
        claimedDefault = true
        let current = Devices.defaultInput
        guard current != mic else { return }   // already ours (e.g. after a crash): keep the saved previous mic
        defaults.set(Devices.uid(of: current), forKey: "previousDefaultInputUID")
        Devices.defaultInput = mic
    }

    /// Only restores if Hush Mic is still the default — never stomps a manual change.
    private func restoreDefaultInput() {
        guard restoreDefaultOnQuit, let mic = Devices.device(uid: Devices.micUID), Devices.defaultInput == mic,
              let previous = defaults.string(forKey: "previousDefaultInputUID").flatMap(Devices.device(uid:)) else { return }
        Devices.defaultInput = previous
    }

    func makeHushMicDefault() {
        if let mic = Devices.device(uid: Devices.micUID) { Devices.defaultInput = mic }
    }

    /// Parameter ramp, not a jump: small steps over ~100 ms. (DeepFilterNet smooths its own limit per frame.)
    private func applyStrength() {
        pipeline.deepFilter?.setAttenuation(dB: strength.attenuationDB)
        rampTask?.cancel()
        let target = strength.wetDryPercent
        rampTask = Task {
            while wetDry != target, !Task.isCancelled {
                wetDry += max(-4, min(4, target - wetDry))
                pipeline.engine?.setWetDry(percent: wetDry)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func refresh() {
        (rms, peak) = pipeline.meter
        if peak >= peakHold || Date.now.timeIntervalSince(peakHeldAt) > 1.5 { peakHold = peak; peakHeldAt = .now }
        latencyMs = pipeline.latencyMs
        if let resampler = pipeline.resampler {
            (driftPPM, underruns, overruns) = (resampler.driftPPM, resampler.underruns, resampler.overruns)
        }
        hushMicIsDefault = Devices.device(uid: Devices.micUID).map { $0 == Devices.defaultInput } ?? false

        publishState()   // catches changes made from the UI too, within one refresh tick
        server.publish(topic: "meter", ["rms": (Double(rms) * 10).rounded() / 10, "peak": (Double(peak) * 10).rounded() / 10])
        server.publish(topic: "stats", ["latencyMs": latencyMs.rounded(), "driftPPM": driftPPM.rounded(),
                                        "underruns": underruns, "overruns": overruns], onlyIfChanged: true)
    }
}
