import AVFoundation
import AppKit
import CoreAudio
import HushAudio
import Observation
import ServiceManagement
import UserNotifications

enum Strength: String, CaseIterable, Identifiable {
    case light, medium, max
    var id: Self { self }
    var label: String { rawValue.capitalized }
    /// AUSoundIsolation wet/dry mix. Starting values from the spec — tune by ear.
    var wetDryPercent: Float { [.light: 60, .medium: 85, .max: 100][self]! }
}

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
    var inputUID: String { didSet { defaults.set(inputUID, forKey: "inputUID"); if inputUID != oldValue { channel = 0; restart() } } }
    var channel: Int { didSet { defaults.set(channel, forKey: "channel"); if channel != oldValue { restart() } } }
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

    var recordingTest = false
    var testResult: String?
    var testFiles: [URL] = []
    var muted = false { didSet { pipeline.muted = muted } }
    var strength: Strength { didSet { defaults.set(strength.rawValue, forKey: "strength"); rampWetDry() } }

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

    var icon: String {
        if error != nil { return "exclamationmark.triangle" }
        if muted { return "mic.slash.fill" }
        return enabled ? "waveform.circle.fill" : "waveform.circle"
    }

    init() {
        inputUID = defaults.string(forKey: "inputUID") ?? ""
        channel = defaults.integer(forKey: "channel")
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        strength = Strength(rawValue: defaults.string(forKey: "strength") ?? "") ?? .medium
        highPassEnabled = defaults.bool(forKey: "highPassEnabled")
        highPassHz = defaults.object(forKey: "highPassHz") as? Double ?? 80
        inputGainDB = defaults.double(forKey: "inputGainDB")
        outputGainDB = defaults.double(forKey: "outputGainDB")
        claimDefaultOnLaunch = defaults.object(forKey: "claimDefaultOnLaunch") as? Bool ?? true
        restoreDefaultOnQuit = defaults.object(forKey: "restoreDefaultOnQuit") as? Bool ?? true
        port = defaults.object(forKey: "port") as? Int ?? 47823
        launchAtLogin = SMAppService.mainApp.status == .enabled
        pipeline.enabled = enabled
        wetDry = strength.wetDryPercent
        applyProcessing()

        if Self.isSnapshot { return }

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
            return
        }
        do {
            try pipeline.start(input: device.id, channel: min(channel, device.inputChannels - 1), output: feed)
            pipeline.engine?.setWetDry(percent: wetDry)
            engineNote = pipeline.engineError.map { "Noise engine unavailable (\($0)) — passing raw mic through" }
            engineInfo = pipeline.engine.map { "Reported latency: \($0.latencyFrames) frames\n\($0.parameterDump)" } ?? ""
            error = nil
            claimDefaultInput()
        } catch {
            self.error = "\(error)"
        }
    }

    private func devicesChanged() {
        devices = Devices.inputDevices()
        if error != nil {
            restart()   // something we were waiting for (mic or driver) may be back
        } else if selectedDevice == nil {
            restart()   // stops audio → Hush Mic goes silent, error state shown
            Self.notifyMicLost()
        }
    }

    private nonisolated static func notifyMicLost() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in
            let content = UNMutableNotificationContent()
            content.title = "Hush: microphone disconnected"
            content.body = "Hush Mic is silent until your microphone is plugged back in."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "mic-lost", content: content, trigger: nil))
        }
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
        case "cycleStrength":
            let all = Strength.allCases
            strength = all[(all.firstIndex(of: strength)! + 1) % all.count]
        case "setEngine":
            guard value as? String == "apple" else { return "Only the apple engine is available so far" }
        case "recordTest":   // not in the spec's list: lets tests and tools trigger the test recorder
            recordTest(seconds: value as? Double ?? 30)
        default: return "Unknown action \(action)"
        }
        publishState()
        return nil
    }

    private func publishState() {
        server.publish(topic: "state", [
            "enabled": enabled, "muted": muted, "strength": strength.rawValue, "engine": "apple",
            "inputConnected": error == nil, "driverInstalled": driverInstalled,
        ], onlyIfChanged: true)
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

    /// Parameter ramp, not a jump: 10 small steps over ~100 ms.
    private func rampWetDry() {
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
