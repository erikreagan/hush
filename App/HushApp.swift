import SwiftUI

@main
struct HushApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            Popover(model: model)
        } label: {
            Image(systemName: model.icon)
        }
        .menuBarExtraStyle(.window)
    }
}

struct Popover: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("Retry") { model.restart() }
            }

            Toggle("Noise Removal", isOn: $model.enabled).toggleStyle(.switch).font(.headline)
            HStack {
                Toggle(isOn: $model.muted) { Label("Mute", systemImage: "mic.slash") }
                    .toggleStyle(.button).tint(.red)
                Spacer()
                // Hold to hear the raw mic; release to return to the cleaned signal.
                Text(model.comparing ? "Raw mic" : "Hold to compare")
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(model.comparing ? AnyShapeStyle(.orange) : AnyShapeStyle(.quaternary), in: .capsule)
                    .onLongPressGesture(minimumDuration: 60, perform: {}) { model.comparing = $0 }
                    .disabled(!model.enabled)
                    .accessibilityAddTraits(.isButton)
            }

            Meter(rms: model.rms, peakHold: model.peakHold)

            Picker("Strength", selection: $model.strength) {
                ForEach(Strength.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().disabled(!model.enabled)

            Divider()

            Picker("Microphone", selection: $model.inputUID) {
                ForEach(model.devices) { Text($0.name).tag($0.uid) }
            }
            if let device = model.selectedDevice, device.inputChannels > 1 {
                Picker("Input channel", selection: $model.channel) {
                    ForEach(0..<device.inputChannels, id: \.self) { Text("\($0 + 1)").tag($0) }
                }
            }

            Divider()

            if model.hushMicIsDefault {
                Label("Hush Mic is your default input", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if model.driverInstalled {
                Button("Make Hush Mic the default input") { model.makeHushMicDefault() }
            }
            if let note = model.engineNote { Text(note).font(.caption).foregroundStyle(.orange) }
            Text(String(format: "Added delay ≈ %.0f ms · drift %+.0f ppm · %d dropouts",
                        model.latencyMs, model.driftPPM, model.underruns + model.overruns))
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button(model.recordingTest ? "Recording…" : "Record 30-second test") { model.recordTest() }
                    .disabled(model.recordingTest || model.error != nil)
                if !model.testFiles.isEmpty, !model.recordingTest {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(model.testFiles) }
                }
            }
            if let result = model.testResult { Text(result).font(.caption).foregroundStyle(.secondary) }

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

/// Post-processing level, −60…0 dBFS, with a peak-hold tick.
struct Meter: View {
    let rms: Float
    let peakHold: Float

    private func fraction(_ dB: Float) -> CGFloat { CGFloat(max(0, min(1, (dB + 60) / 60))) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(peakHold > -3 ? .red : .green).frame(width: geo.size.width * fraction(rms))
                Rectangle().fill(.primary).frame(width: 2).offset(x: (geo.size.width - 2) * fraction(peakHold))
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(rms)) decibels")
    }
}
