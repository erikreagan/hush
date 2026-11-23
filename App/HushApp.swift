import HushAudio
import SwiftUI

@main
struct HushApp: App {
    @State private var model = AppModel()

    init() { Snapshot.runIfRequested() }

    var body: some Scene {
        MenuBarExtra {
            Popover(model: model)
        } label: {
            Image(systemName: model.icon)
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(model: model) }
    }
}

/// Laid out like a system Control Center module: title + master switch, live level, a few large
/// controls, then menu-style rows for the rare actions.
struct Popover: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hush").font(.headline)
                    Text(model.statusLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("Noise Removal", isOn: $model.enabled).toggleStyle(.switch).labelsHidden()
            }

            if let error = model.error {
                Notice(icon: "exclamationmark.triangle.fill", tint: .red, message: error, action: "Retry") { model.restart() }
            }

            HStack(spacing: 8) {
                Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 14)
                Meter(rms: model.rms, peakHold: model.peakHold)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Strength").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Segments(title: "Strength", options: Strength.allCases, label: \.label, selection: $model.strength)
            }
            .opacity(model.enabled ? 1 : 0.4).disabled(!model.enabled)

            if model.deepFilterAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Engine").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Segments(title: "Engine", options: EngineID.allCases, label: \.label, selection: $model.engine)
                }
                .opacity(model.enabled ? 1 : 0.4).disabled(!model.enabled)
            }

            HStack(spacing: 8) {
                Button { model.muted.toggle() } label: {
                    Tile(icon: model.muted ? "mic.slash.fill" : "mic.fill", title: "Mute",
                         subtitle: (model.muted ? "Muted" : "Mic is live") + (model.muteShortcut.map { "  \($0.display)" } ?? ""),
                         active: model.muted, tint: .red)
                }
                .buttonStyle(.plain)

                // Press and hold to hear the raw mic; release to return to the cleaned signal.
                Tile(icon: "ear.fill", title: "Compare",
                     subtitle: model.comparing ? "Raw mic" : "Hold for raw", active: model.comparing, tint: .orange)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !model.comparing { model.comparing = true } }
                        .onEnded { _ in model.comparing = false })
                    .opacity(model.enabled ? 1 : 0.4)
                    .allowsHitTesting(model.enabled)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Hold to hear the unprocessed microphone")
            }

            Button { model.listening.toggle() } label: {
                Tile(icon: "headphones", title: "Listen",
                     subtitle: model.listening ? "Playing to \(model.monitorName) — use headphones" : "Hear what apps hear",
                     active: model.listening, tint: .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(model.error != nil)
            if let problem = model.monitorError {
                Notice(icon: "exclamationmark.circle.fill", tint: .orange, message: problem)
            }

            if let note = model.engineNote {
                Notice(icon: "exclamationmark.circle.fill", tint: .orange, message: note)
            }
            if model.driverInstalled, !model.hushMicIsDefault {
                Notice(icon: "exclamationmark.circle.fill", tint: .orange,
                       message: "Apps aren't using Hush Mic by default", action: "Make Default") { model.makeHushMicDefault() }
            }

            Divider()

            VStack(spacing: 1) {
                Button { model.recordTest() } label: {
                    HStack {
                        Text(model.recordingTest ? "Recording Test…" : "Record 30-Second Test")
                        Spacer()
                        if model.recordingTest { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(model.recordingTest || model.error != nil)
                if !model.testFiles.isEmpty, !model.recordingTest {
                    Button("Show Last Test in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.testFiles) }
                }
                if let result = model.testResult, model.testFiles.isEmpty {
                    Text(result).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                }
                SettingsLink { HStack { Text("Settings…"); Spacer(); Text("⌘,").foregroundStyle(.tertiary) } }
                    .keyboardShortcut(",")
                    .simultaneousGesture(TapGesture().onEnded { NSApplication.shared.activate() })   // menu bar apps open windows behind otherwise
                Button { NSApplication.shared.terminate(nil) } label: {
                    HStack { Text("Quit Hush"); Spacer(); Text("⌘Q").foregroundStyle(.tertiary) }
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(MenuRowStyle())
            .padding(.horizontal, -8)   // row highlights run closer to the edges, like system menus
        }
        .padding(16)
        .frame(width: 300)
    }
}

extension Strength { var label: String { rawValue.capitalized } }
extension EngineID { var label: String { self == .apple ? "Apple" : "DeepFilterNet" } }

/// Full-width segmented choice. Custom because the system segmented control won't stretch to the panel
/// width; the selected segment is filled with the accent colour.
struct Segments<Option: Hashable & Identifiable>: View {
    let title: String
    let options: [Option]
    let label: KeyPath<Option, String>
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = selection == option
                Button { selection = option } label: {
                    Text(option[keyPath: label])
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .white : .primary)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A Control Center–style tile: icon in a circle that fills with colour when active.
struct Tile: View {
    let icon: String
    let title: String
    let subtitle: String
    let active: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? .white : .primary)
                .frame(width: 30, height: 30)
                .background(active ? AnyShapeStyle(tint) : AnyShapeStyle(.primary.opacity(0.1)), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect(cornerRadius: 12))
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

/// An inline warning or error with an optional action.
struct Notice: View {
    let icon: String
    let tint: Color
    let message: String
    var action: String?
    var perform: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action { Button(action, action: perform).controlSize(.small) }
        }
        .padding(10)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

/// Full-width rows that highlight on hover, like the items at the bottom of system menu bar panels.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.primary.opacity(!isEnabled || !hovering ? 0 : configuration.isPressed ? 0.16 : 0.09),
                            in: .rect(cornerRadius: 7, style: .continuous))
                .contentShape(.rect)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// Post-processing level, −60…0 dBFS: green through the speaking range, yellow then red near clipping,
/// with a peak-hold tick.
struct Meter: View {
    let rms: Float
    let peakHold: Float

    private func fraction(_ dB: Float) -> CGFloat { CGFloat(max(0, min(1, (dB + 60) / 60))) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.7),
                                                 .init(color: .yellow, location: 0.85), .init(color: .red, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * fraction(rms)) }
                Capsule().fill(.primary.opacity(0.7)).frame(width: 2)
                    .offset(x: (geo.size.width - 2) * fraction(peakHold))
                    .opacity(peakHold > -59 ? 1 : 0)
            }
            .animation(.linear(duration: 0.07), value: rms)
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(rms)) decibels")
    }
}

/// Developer aid: renders the popover in several states, light and dark, to a PNG. See AppModel.isSnapshot.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count else { return }
        func state(_ configure: (AppModel) -> Void) -> AppModel {
            let model = AppModel()
            (model.enabled, model.driverInstalled, model.hushMicIsDefault) = (true, true, true)
            (model.rms, model.peakHold) = (-22, -9)
            configure(model)
            return model
        }
        let states = [
            state { _ in },
            state { $0.muted = true; $0.rms = -120; $0.peakHold = -120 },
            state { $0.enabled = false; $0.hushMicIsDefault = false; $0.rms = -6; $0.peakHold = -1 },
            state { $0.listening = true; $0.monitorName = "iD2"; $0.engine = .deepFilter },
            state { $0.error = "Driver not installed — run scripts/install-driver.sh"; $0.rms = -120; $0.peakHold = -120 },
        ]
        let row = { (scheme: ColorScheme) in
            HStack(alignment: .top, spacing: 24) {
                ForEach(states.indices, id: \.self) { index in
                    Popover(model: states[index])
                        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(24)
            .background(scheme == .dark ? Color(white: 0.25) : Color(white: 0.8))
            .environment(\.colorScheme, scheme)
        }
        let view = NSHostingView(rootView: VStack(spacing: 0) { row(.light); row(.dark) })
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[flag + 1]))
        exit(0)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Input") {
                Picker("Microphone", selection: $model.inputUID) {
                    ForEach(model.devices) { Text($0.name).tag($0.uid) }
                    if model.selectedDevice == nil, !model.inputUID.isEmpty { Text("Disconnected microphone").tag(model.inputUID) }
                }
                if let device = model.selectedDevice, device.inputChannels > 1 {
                    Picker("Input channel", selection: $model.channel) {
                        ForEach(0..<device.inputChannels, id: \.self) { Text("\($0 + 1)").tag($0) }
                    }
                }
                Slider(value: $model.inputGainDB, in: -12...12, step: 0.5) { Text(String(format: "Input trim  %+.1f dB", model.inputGainDB)) }
            }
            Section("Listen") {
                Picker("Play to", selection: $model.monitorUID) {
                    Text("Current Mac output").tag("")
                    ForEach(model.outputDevices) { Text($0.name).tag($0.uid) }
                }
                Text("Listen plays what apps hear, slightly delayed. Use headphones: through speakers the mic picks it up and it feeds back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Processing") {
                Toggle("High-pass filter (cuts rumble below the voice)", isOn: $model.highPassEnabled)
                Slider(value: $model.highPassHz, in: 60...150, step: 5) { Text("Cutoff  \(Int(model.highPassHz)) Hz") }
                    .disabled(!model.highPassEnabled)
                Slider(value: $model.outputGainDB, in: -12...12, step: 0.5) { Text(String(format: "Output trim  %+.1f dB", model.outputGainDB)) }
            }
            Section("System") {
                Toggle("Launch Hush at login", isOn: $model.launchAtLogin)
                if let problem = model.loginItemError { Text(problem).font(.caption).foregroundStyle(.red) }
                Toggle("Make Hush Mic the default input when Hush starts", isOn: $model.claimDefaultOnLaunch)
                Toggle("Restore the previous default input when Hush quits", isOn: $model.restoreDefaultOnQuit)
            }
            Section("Shortcuts") {
                LabeledContent("Noise removal on/off") { ShortcutRecorder(shortcut: $model.toggleShortcut, hotkeys: model.hotkeys) }
                LabeledContent("Mute") { ShortcutRecorder(shortcut: $model.muteShortcut, hotkeys: model.hotkeys) }
                LabeledContent("Next strength") { ShortcutRecorder(shortcut: $model.cycleShortcut, hotkeys: model.hotkeys) }
                if let problem = model.shortcutError { Text(problem).font(.caption).foregroundStyle(.red) }
                Text("These work in any app. Use at least one of ⌘ ⌥ ⌃, or a function key.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Stream Deck") {
                TextField("Control port (applies after relaunch)", value: $model.port, format: .number.grouping(.never))
                if let problem = model.server.startError { Text("Control socket failed: \(problem)").foregroundStyle(.red) }
                else { Text("\(model.server.clientCount) client(s) connected").foregroundStyle(.secondary) }
            }
            Section("Diagnostics") {
                LabeledContent("Added delay", value: String(format: "%.0f ms", model.latencyMs))
                LabeledContent("Clock drift correction", value: String(format: "%+.0f ppm", model.driftPPM))
                LabeledContent("Buffer underruns / overruns", value: "\(model.underruns) / \(model.overruns)")
                Text(model.engineInfo).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
    }
}
