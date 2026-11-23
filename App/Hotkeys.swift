import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A recorded key combination. `display` is what the user sees ("⌃⌥M").
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon flags (cmdKey, optionKey, controlKey, shiftKey)
    var display: String

    private static let namedKeys: [UInt16: String] = [
        49: "Space", 36: "Return", 48: "Tab", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16",
        64: "F17", 79: "F18", 80: "F19", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// Builds a shortcut from a key press, or nil if it isn't usable as a global shortcut
    /// (a plain letter with no ⌘/⌥/⌃ would hijack normal typing everywhere).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isFunctionKey = Self.namedKeys[event.keyCode]?.hasPrefix("F") ?? false
        guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        guard let key = Self.namedKeys[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
        var carbon: UInt32 = 0, symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        (keyCode, modifiers, display) = (UInt32(event.keyCode), carbon, symbols + key)
    }
}

/// System-wide hotkeys via Carbon's RegisterEventHotKey — works in any app, needs no Accessibility permission.
@MainActor
final class Hotkeys {
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var bindings: [UInt32: Shortcut] = [:]

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = id.id
            MainActor.assumeIsolated { Unmanaged<Hotkeys>.fromOpaque(context!).takeUnretainedValue().actions[number]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Binds (or with nil, clears) hotkey number `id`. Returns false if macOS refused the combination.
    @discardableResult
    func bind(_ id: UInt32, to shortcut: Shortcut?, action: @escaping () -> Void) -> Bool {
        if let old = registered.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        actions[id] = action
        bindings[id] = shortcut
        guard let shortcut else { return true }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x4855_5348 /* 'HUSH' */, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        registered[id] = ref
        return status == noErr
    }

    /// While the user is recording a new shortcut, existing ones must not fire.
    func suspend() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered.removeAll()
    }

    func resume() {
        for (id, shortcut) in bindings { if let action = actions[id] { bind(id, to: shortcut, action: action) } }
    }
}

/// A Settings row control: click, press a key combination, done. Esc cancels; the ✕ clears.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    let hotkeys: Hotkeys
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press keys…" : shortcut?.display ?? "Record Shortcut") { recording ? stop() : start() }
                .foregroundStyle(recording ? Color.accentColor : .primary)
            if shortcut != nil, !recording {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            guard let recorded = Shortcut(event: event) else { NSSound.beep(); return nil }
            stop()
            shortcut = recorded
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hotkeys.resume()
    }
}
