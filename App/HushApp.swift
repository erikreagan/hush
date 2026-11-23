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
            MenuBarIcon(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView(model: model) }
    }
}

struct MenuBarIcon: View {
    let model: AppModel

    var body: some View {
        if model.error != nil {
            Image(systemName: "exclamationmark.triangle")
        } else {
            // All three states are NSImages of one size: mixing in Image(systemName:) made the menu bar item change width on mute.
            Image(nsImage: model.muted ? Self.muted : model.enabled ? Self.on : Self.off)
        }
    }

    static let on = symbol("waveform.circle.fill"), off = symbol("waveform.circle")
    static func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Hush")!
        image.isTemplate = true
        return image
    }

    /// waveform.circle.fill with a slash: SF Symbols has no slashed variant. A template image, so the menu bar tints it.
    static let muted: NSImage = {
        let base = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Hush, muted")!
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let inset = rect.width * 0.04, line = rect.width / 13   // tuned by eye against --snapshot
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
            slash.line(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
            slash.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            slash.lineWidth = line * 2.4; slash.stroke()   // cut a gap out of the disc
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            slash.lineWidth = line; slash.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
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
    var height: CGFloat = 6

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
        .frame(height: height)
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
        let path = arguments[flag + 1]
        func write(_ root: some View, to path: String) {
            let view = NSHostingView(rootView: root)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        // Settings panes: out.png -> out-audio-light.png etc.
        for pane in SettingsPane.allCases {
            for scheme in [ColorScheme.light, .dark] {
                write(SettingsView(model: states[0], pane: pane).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme),
                      to: (path as NSString).deletingPathExtension + "-\(pane.rawValue.lowercased())-\(scheme == .dark ? "dark" : "light").png")
            }
        }
        // Menu bar icons (on, off, muted): out.png -> out-menubar.png
        let icons = { (scheme: ColorScheme) in
            HStack(spacing: 16) { ForEach(0..<3, id: \.self) { MenuBarIcon(model: states[$0]) } }
                .padding(12)
                .foregroundStyle(scheme == .dark ? .white : .black)
                .background(scheme == .dark ? Color(white: 0.15) : Color(white: 0.9))
        }
        write(VStack(spacing: 0) { icons(.light); icons(.dark) }.scaleEffect(4).frame(width: 520, height: 320),
              to: (path as NSString).deletingPathExtension + "-menubar.png")
        write(VStack(spacing: 0) { row(.light); row(.dark) }, to: path)
        exit(0)
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case audio = "Audio", shortcuts = "Shortcuts", general = "General", advanced = "Advanced"
    var id: Self { self }
    var icon: String {
        switch self {
        case .audio: "waveform"
        case .shortcuts: "keyboard"
        case .general: "switch.2"
        case .advanced: "gearshape.2"
        }
    }
}

/// Fixed-size window: a sidebar with a status card pinned at its bottom, and one pane to the right.
/// Plain buttons beside a detail view (not NavigationSplitView or List): a fixed window must not collapse the sidebar, and List's selection can't be snapshotted.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State var pane = SettingsPane.audio   // settable via the memberwise init so Snapshot can pick a pane

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(SettingsPane.allCases) { item in
                        Button { pane = item } label: {
                            Label(item.rawValue, systemImage: item.icon)
                                .foregroundStyle(pane == item ? .white : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 32)
                                .background(pane == item ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7, style: .continuous))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(pane == item ? .isSelected : [])
                    }
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.top, 12)
                StatusCard(model: model).padding(10)
            }
            .frame(width: 210).background(.primary.opacity(0.04))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text(pane.rawValue).font(.title2.bold()); Spacer() }   // room for the preset menu (#2)
                    .padding(.horizontal, 28).padding(.top, 16).frame(minHeight: 44)
                detail
            }
        }
        .frame(width: 760, height: 680)
    }

    @ViewBuilder private var detail: some View {
        Form {
            switch pane {
            case .audio:
                Section {
                    Picker("Microphone", selection: $model.inputUID) {
                        ForEach(model.devices) { Text($0.name).tag($0.uid) }
                        if model.selectedDevice == nil, !model.inputUID.isEmpty { Text("Disconnected microphone").tag(model.inputUID) }
                    }
                    if let device = model.selectedDevice, device.inputChannels > 1 {
                        Picker("Input channel", selection: $model.channel) {
                            ForEach(0..<device.inputChannels, id: \.self) { Text("\($0 + 1)").tag($0) }
                        }
                    }
                    InputMeter(model: model)
                    SliderRow(title: "Input trim", value: $model.inputGainDB, range: -12...12, step: 0.5) { String(format: "%+.1f dB", $0) }
                } header: { Text("Input") } footer: { Text("Speak normally and adjust trim until the level sits in the green.") }
                Section("Processing") {
                    Toggle(isOn: $model.highPassEnabled) {
                        Text("High-pass filter"); Text("Cuts rumble below the voice")
                    }
                    SliderRow(title: "Cutoff", value: $model.highPassHz, range: 60...150, step: 5) { "\(Int($0)) Hz" }
                        .disabled(!model.highPassEnabled)
                    SliderRow(title: "Output trim", caption: "Final volume sent to apps", value: $model.outputGainDB, range: -12...12, step: 0.5) { String(format: "%+.1f dB", $0) }
                }
                Section {
                    Picker("Play to", selection: $model.monitorUID) {
                        Text("Current Mac output").tag("")
                        ForEach(model.outputDevices) { Text($0.name).tag($0.uid) }
                    }
                } header: { Text("Listen") } footer: {
                    Text("Listen plays what apps hear, slightly delayed. Use headphones: through speakers the mic picks it up and it feeds back.")
                }
            case .shortcuts:
                Section {
                    LabeledContent("Noise removal on/off") { ShortcutRecorder(shortcut: $model.toggleShortcut, hotkeys: model.hotkeys) }
                    LabeledContent("Mute") { ShortcutRecorder(shortcut: $model.muteShortcut, hotkeys: model.hotkeys) }
                    LabeledContent("Next strength") { ShortcutRecorder(shortcut: $model.cycleShortcut, hotkeys: model.hotkeys) }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let problem = model.shortcutError { Text(problem).foregroundStyle(.red) }
                        Text("These work in any app. Use at least one of ⌘ ⌥ ⌃, or a function key.")
                    }
                }
            case .general:
                Section {
                    Toggle("Launch Hush at login", isOn: $model.launchAtLogin)
                    Toggle("Make Hush Mic the default input when Hush starts", isOn: $model.claimDefaultOnLaunch)
                    Toggle("Restore the previous default input when Hush quits", isOn: $model.restoreDefaultOnQuit)
                } footer: { if let problem = model.loginItemError { Text(problem).foregroundStyle(.red) } }
            case .advanced:
                Section("Stream Deck") {
                    LabeledContent {
                        TextField("Control port", value: $model.port, format: .number.grouping(.never))
                            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                    } label: { Text("Control port"); Text("Applies after relaunch") }
                    LabeledContent("Connection") {
                        if let problem = model.server.startError { Text("Control socket failed: \(problem)").foregroundStyle(.red) }
                        else { Text("\(model.server.clientCount) client(s) connected").foregroundStyle(.secondary) }
                    }
                }
                Section("Diagnostics") {
                    LabeledContent("Added delay", value: String(format: "%.0f ms", model.latencyMs))
                    LabeledContent("Clock drift correction", value: String(format: "%+.0f ppm", model.driftPPM))
                    LabeledContent("Buffer underruns / overruns", value: "\(model.underruns) / \(model.overruns)")
                    Text(model.engineInfo).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Its own view so meter ticks redraw only this, not the whole settings window.
private struct InputMeter: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            Meter(rms: model.rms, peakHold: model.peakHold, height: 10)
            HStack { Text("−60"); Spacer(); Text("−40"); Spacer(); Text("−20"); Spacer(); Text("0 dB") }
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// A labelled slider with its current value to the right.
private struct SliderRow: View {
    let title: String
    var caption: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step) { Text(title) }.labelsHidden().frame(width: 200)
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
            }
        } label: { Text(title); if let caption { Text(caption) } }
    }
}

/// Pinned at the bottom of the sidebar on every pane.
private struct StatusCard: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                let on = model.error == nil && model.enabled
                Circle().fill(on ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(on ? "Hush is on" : "Hush is off").fontWeight(.semibold)
            }
            Text(model.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Meter(rms: model.rms, peakHold: model.peakHold).accessibilityHidden(true)   // duplicates the Audio pane's meter
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
    }
}
