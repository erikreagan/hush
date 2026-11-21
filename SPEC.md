# Hush — Mic Noise Removal for macOS

**Spec version:** 1.1 (revised after the M1 + M2 build) · **Owner:** Erik Reagan · **Audience:** personal use only (not distributed)

> The name "Hush" is final. It appears in the app name, bundle IDs, virtual device name, and Stream Deck plugin ID.

---

## 1. Plain-language overview

Hush is a small Mac menu-bar app that cleans up my XLR mic before any other app hears it.

It does three things:

1. **Listens to the real mic** (an XLR mic plugged into an Audient iD2 interface).
2. **Removes background noise** — A/C hum, fan noise, keyboard typing, mouse clicks, desk thuds — using one of two AI noise-removal engines I can switch between.
3. **Feeds the clean audio into a "virtual microphone"** called **Hush Mic**. Every app (Zoom, Meet, Slack, browsers, recording apps) just picks Hush Mic as its input — or uses it automatically, because Hush sets it as the Mac's default input. No app ever needs to support Apple's "Mic Modes."

I control it from the menu bar and from an Elgato Stream Deck (toggle, strength presets, hard mute, live level meter).

**Non-goals:** cleaning up *incoming* audio (other people on calls), transcription, recording, meeting notes, accent conversion, or anything else Krisp bundles. Mic in, clean mic out. That's it.

---

## 2. Background the builder needs

- **Why a virtual mic?** macOS apps can only read from audio *devices*. To insert processing between the real mic and every app, we create a software-only audio device (a "HAL plug-in" / AudioServerPlugIn installed at `/Library/Audio/Plug-Ins/HAL/`). Hush writes processed audio into it; apps read from it. This is the same architecture Krisp uses.
- **Virtual driver source:** [BlackHole](https://github.com/ExistentialAudio/BlackHole), unmodified upstream as a git submodule (GPL-3; fine because this is personal and not distributed). BlackHole supports build-time customization of driver name, bundle ID, device name, channel count, sample rates, input/output visibility, and a second "mirror" device via preprocessor definitions — so **no driver C code changes are needed**, just a build script. The driver is a single C file, so the script compiles it directly with `clang` and assembles the `.driver` bundle itself; `xcodebuild` is not used anywhere in this project.
- **Engine A — Apple `AUSoundIsolation`:** A system Audio Unit (`kAudioUnitType_Effect` / `kAudioUnitSubType_AUSoundIsolation`) that performs on-device voice isolation inside our own processing chain, independent of the system Mic Mode setting. Zero dependencies, maintained by Apple, limited tuning. Its parameter tree is enumerated at runtime (don't assume it across macOS versions). On macOS 27 it exposes exactly two parameters: **Wet/Dry Mix** (id 0, range −100…100, default 100) and **Sound to Isolate** (id 1, range 0…1, default 1 = voice; 0 = high-quality voice). It runs at 48 kHz mono and **reports 2705 frames (~56 ms) of latency**.
- **Engine B — DeepFilterNet (v3):** Open-source (MIT/Apache) speech enhancement model with a Rust real-time runtime (`libDF`, inference via `tract`). Operates at **48 kHz mono, 10 ms hop**. Full DFN3 has ~40 ms algorithmic latency (2-frame lookahead); a no-lookahead variant (used by its LADSPA plugin) is ~20 ms. Key tuning knob: **attenuation limit (dB)** — how much noise it's allowed to remove. Expected to be particularly strong on typing/clicks.
- **Do NOT use Apple's Voice Processing I/O unit** (`kAudioUnitSubType_VoiceProcessingIO`) anywhere. It triggers Mic Modes, ducking, and multi-input remapping on interfaces — the exact behavior we're avoiding. Capture with plain AUHAL / AVAudioEngine.
- **Hardware context:** Audient iD2 (3rd gen, 2026) has a hardware high-pass filter and onboard DSP EQ. Hush should still offer its own optional high-pass stage in case the iD2's DSP effects only apply to the monitoring path, not the USB recording path.

---

## 3. Platform & stack

| Area | Choice |
|---|---|
| OS | macOS 15+ (Sequoia), Apple silicon only |
| App | Swift 6, SwiftUI `MenuBarExtra` (`.window` style), no Dock icon (`LSUIElement = YES`) |
| Project format | One Swift package at the repo root (no Xcode project). `scripts/build-app.sh` runs `swift build` and assembles + signs `build/Hush.app`. The package opens in Xcode for editing and debugging. The script also stamps the binary with the real SDK version (`vtool`): SwiftPM labels it as built for macOS 15, which makes macOS draw the app in its legacy look |
| Audio | Core Audio (AUHAL) for capture/render; AudioToolbox for AUSoundIsolation |
| DeepFilterNet | Rust `libDF` built as a static library with a C ABI, linked into the app (see §6.3). Rust is not yet installed on the build Mac |
| Driver | BlackHole (upstream submodule), compiled by script with `clang` and preprocessor definitions |
| Stream Deck plugin | Official `@elgato/streamdeck` Node SDK v2 (TypeScript), Node 24, Stream Deck app 7.1+. Target hardware: Stream Deck + |
| IPC (app ↔ plugin) | Local WebSocket server inside Hush, bound to `127.0.0.1` only |
| Signing | App: self-signed certificate "Hush Dev" in its own dedicated keychain, `~/Library/Keychains/hush-signing.keychain-db` (`scripts/make-signing-cert.sh`, run once; no prompts, login keychain untouched), so the microphone permission survives rebuilds; falls back to ad-hoc if the certificate is missing. Driver: ad-hoc. No notarization, no sandbox |
| Launch at login | `SMAppService.mainApp` |

---

## 4. Signal chain

```
[ XLR mic ] → [ Audient iD2 input N ] → Capture (AUHAL, input device = selected mic)
      → Channel select (mono, from configured input channel)
      → Ring buffer (at the mic's own sample rate)
  ── everything below runs on Hush Feed's audio thread and clock ──
      → Drift-correcting resampler → 48 kHz mono float32
      → Optional High-Pass Filter (biquad, default OFF, 60–150 Hz)   [not built yet — M3]
      → Noise Engine (Apple | DeepFilterNet), crossfaded against the raw signal for bypass
      → Output gain (dB trim) + Mute
      → Level meter tap (post-processing peak/RMS)
      → Render (AUHAL, output device = hidden "Hush Feed")
                                        ↓ (BlackHole mirror)
                          Apps read "Hush Mic" (input-only, visible)
```

The ring buffer sits right after capture, not at the end of the chain. That lets **one resampler do two jobs**: convert the mic's sample rate to 48 kHz, and absorb clock drift between the two devices (§4.2). All processing then happens at exactly 48 kHz on one thread.

### 4.1 Rules

- **Bypass ≠ silence.** When noise removal is toggled OFF, Hush passes the raw mic through. Apps never lose audio because the toggle is off.
- **Mute = silence.** Hard mute writes zeros to Hush Mic regardless of engine state.
- **Mono in, stereo out.** Process mono; duplicate to both channels of the 2-ch virtual device (many apps expect stereo).
- **No feedback loops.** Hush must never offer Hush Mic or Hush Feed as its own capture source.
- **Engine switching is glitch-free:** run the incoming engine in parallel for warm-up, then ~50 ms equal-power crossfade. Toggling bypass uses the same 50 ms crossfade between raw and processed audio; the engine keeps running while bypassed so the toggle is instant (costs some idle CPU — revisit if it matters). Preset changes on the Apple engine ramp the wet/dry parameter over ~100 ms rather than jumping. Mute ramps over 10 ms.
- **Real-time safety:** no allocation, locks, logging, or Swift async on the audio thread. Engine instances, buffers, and filters are created off-thread and swapped atomically. Controls and meter values cross threads through atomics.
- **I/O buffer size:** Hush requests 256 frames (~5 ms) on both the mic and Hush Feed.

### 4.2 Clock drift (known hard part)

The mic and the virtual device run on different clocks, so their sample rates drift slightly. BlackHole **cannot** slave its clock to another device (it only has a manual pitch-adjust control), so Hush's own drift correction is the mechanism, not a safety net. As built:

- A lock-free single-producer/single-consumer ring buffer sits between capture and render.
- Target fill = one capture block + one render block + 3 ms of scheduling slack.
- An adaptive resampler (4-point Hermite interpolation) reads from it. A slow control loop (1 s smoothing, correction capped at ±0.5%) nudges the resampling ratio to hold the fill at target. The same resampler handles a mic that isn't at 48 kHz. If a non-48 kHz mic ever sounds dull, upgrade the interpolation to windowed-sinc.
- Underrun: fade out what's left, output silence, refill to target, fade back in. Overrun (fill > 4× target): jump ahead to target and fade in. Both are counted and shown in the UI.
- Verified by a unit test simulating 60 s of a 44.1 kHz mic running 300 ppm fast into a 48 kHz output: no under/overruns, no discontinuities.

### 4.3 Latency & performance targets

| Metric | Target |
|---|---|
| Added latency, Apple engine | The engine alone reports ~56 ms, so the original ≤ 30 ms target is not achievable. Expect ~75 ms total (engine + buffers); judge by ear on real calls. Shown live in the popover |
| Added latency, DeepFilterNet | ≤ 50 ms with lookahead model; offer no-lookahead model if lower latency is needed |
| CPU | < 5% of one performance core sustained (either engine) |
| Dropouts | Zero over a 2-hour soak test |

---

## 5. Virtual device (driver)

BlackHole is built with these settings (constant names verified against the BlackHole source):

| Constant | Value |
|---|---|
| `kDriver_Name` | `"Hush"` |
| `kPlugIn_BundleID` | `"com.erikreagan.hush.driver"` (matches the bundle's Info.plist) |
| `kManufacturer_Name` | `"Hush"` |
| `kHas_Driver_Name_Format` | `false` (keeps channel counts out of names and UIDs) |
| `kNumber_Of_Channels` | `2` |
| `kSampleRates` | `48000` |
| Device 1 | `kDevice_Name="Hush Feed"`, `kDevice_IsHidden=true`, output only — Hush writes here. UID `Hush_UID` |
| Device 2 | `kDevice2_Name="Hush Mic"`, `kDevice2_IsHidden=false`, input only — apps read here. UID `Hush_2_UID` |
| Can be default input | yes (BlackHole's default) |

The hidden-output + visible-input mirror pair means users never see a confusing "Hush" output device. The app finds the hidden Hush Feed by UID (`kAudioHardwarePropertyTranslateUIDToDevice`), since hidden devices don't appear in the device list. **Not yet confirmed on a live install.** **Fallback** if opening the hidden device fails: a single visible device "Hush Mic" with both directions.

**Scripts:**
- `scripts/build-driver.sh` — compiles `BlackHole.c` with `clang` and the definitions above into `build/driver/Hush.driver`, ad-hoc signed.
- `scripts/install-driver.sh` — copies to `/Library/Audio/Plug-Ins/HAL/`, restarts `coreaudiod` (`sudo killall coreaudiod`). Requires admin; run manually.
- `scripts/uninstall-driver.sh` — reverse.

The app detects whether the driver is installed and shows a clear "Driver not installed — run scripts/install-driver.sh" state if not.

---

## 6. Noise engines

### 6.1 Common protocol

Not extracted yet: with only the Apple engine built, the pipeline uses `AppleEngine` directly. Introduce this protocol in M4, when DeepFilterNet becomes the second implementation.

```swift
protocol NoiseEngine: AnyObject {
    var id: EngineID { get }                 // .apple, .deepFilter
    var latencyFrames: Int { get }           // reported to Diagnostics
    func prepare(sampleRate: Double, maxFrames: Int) throws
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int) // RT-safe
    func apply(strength: Strength)           // RT-safe or ramped
    func reset()
}
enum Strength { case light, medium, max, custom(Float) }  // custom = 0...1
```

Engines must handle arbitrary host buffer sizes (internally re-block to their native frame size, e.g. 480 samples for DFN).

### 6.2 Apple engine (AUSoundIsolation)

- Instantiate via `AudioComponentFindNext` with the subtype above; render via `AudioUnitRender` with a pull callback supplying the input block.
- Format: 48 kHz mono float32 on both sides (accepted by the unit).
- All parameters (IDs, names, ranges) are enumerated when the engine is created and kept as a text dump for Diagnostics (results in §2). The Diagnostics screen that displays it is M3.
- Strength mapping (starting values — tune by ear):
  - Light → wet/dry 60%
  - Medium → 85%
  - Max → 100%
- "Sound to Isolate" is set to voice (1). The high-quality voice option (0) is untested.
- If the unit fails to load or render, the chain fails open: raw mic passes through and the popover says so.
- A unit test confirms it works on the build Mac: white noise is reduced by ~86 dB.

### 6.3 DeepFilterNet engine

- Vendor DeepFilterNet as a git submodule. Build `libDF` as a static lib (`aarch64-apple-darwin`) exposing a C API. The repo is expected to have a C-API feature (functions roughly like create / process-frame / set-attenuation-limit / free) — **verify; if absent, write a thin Rust FFI crate wrapping the real-time `DfTract` runtime.**
- Bundle the DFN3 model archive in app Resources. Optionally bundle the no-lookahead model as a "Low latency" toggle.
- Native format: 48 kHz mono, 480-sample frames.
- Strength mapping (attenuation limit, dB):
  - Light → 12 dB
  - Medium → 24 dB
  - Max → 100 dB (effectively unlimited)
- Expose post-filter beta in Advanced settings (default per upstream).
- Build integrated into Xcode via a Run Script phase (`cargo build --release`) or a prebuilt `.xcframework` produced by `scripts/build-dfn.sh`.

### 6.4 Bypass

Pass-through (with HPF and gain still applied). Not a separate engine in the UI — it's the "noise removal off" state.

---

## 7. Menu bar UI

**Menu bar icon** (SF Symbols), states:
- Active — `waveform.circle.fill` (a custom "hush" glyph could replace it later)
- Bypassed (noise removal off) — `waveform.circle`
- Muted — `mic.slash.fill`
- Error (mic missing / driver missing / app can't open device) — `exclamationmark.triangle`

**Popover as built** (300 pt wide, styled after the system's Control Center panels; top to bottom):
1. Header: "Hush" with a one-line status of what apps are hearing ("Cleaning up <mic>", "Off — raw <mic>", "Muted — apps hear silence"), and the master **Noise Removal** switch on the right.
2. Error banner (red tint, Retry button) — only when something is wrong.
3. Live level meter (post-processing) with peak-hold tick; green through the speaking range, yellow then red near clipping.
4. **Strength:** full-width custom segments **Light · Medium · Max**; the selected one is filled with the accent colour. (Custom because the system segmented control won't stretch to the panel width.)
5. Two tiles: **Mute** (icon circle turns solid red when muted) and **Compare** (press and hold for the raw mic — the A/B control).
6. Warning banners, only when relevant: noise engine unavailable; Hush Mic isn't the default input (with a "Make Default" button). There is no always-on "default input ✓" line.
7. Menu-style rows with hover highlights: Record 30-Second Test (then "Show Last Test in Finder"), Settings… (⌘,), Quit Hush (⌘Q).

Still to add to the popover: the engine switch **Apple · DeepFilterNet** (M4), the **Listen** toggle, and a hotkey hint on Mute. The delay / drift / dropouts readout lives in Settings → Diagnostics, not the popover.

`build/Hush.app/Contents/MacOS/Hush --snapshot out.png` renders the popover in several states, light and dark, to an image without starting audio or touching settings — use it to review UI changes.

**Settings window:**
Built: Input, Processing (high-pass + output trim), System, Stream Deck (port, client count), and Diagnostics (delay, drift, under/overruns, engine parameter dump). Not built: Shortcuts, the DFN options, per-engine custom strength, CPU %, and the test-record button (it's in the popover instead).

- *Input:* device picker (default: Audient iD2), channel picker (default: 1), input gain trim
- *Processing:* HPF on/off + frequency slider; per-engine custom strength; DFN low-latency model toggle; DFN post-filter beta
- *System:* Launch at login (default ON); Set Hush Mic as default input on launch (default ON); restore previous default input on quit (default ON)
- *Shortcuts:* global hotkeys for Toggle, Mute, Cycle preset (user-assignable)
- *Stream Deck:* WebSocket port (default `47823`), show connection status
- *Diagnostics:* measured latency per engine, CPU %, buffer underruns/overruns, drift ppm, AUSoundIsolation parameter dump, "Record 30-second test" (writes raw + processed WAVs side by side to `~/Music/Hush Tests/` for A/B listening)

**Persistence:** all settings in `UserDefaults`; state restored on launch.

**Device hot-plug:** if the iD2 disappears, Hush Mic outputs silence, icon shows error, and a notification fires. When it reappears, capture resumes automatically. Listen for `kAudioHardwarePropertyDevices` changes.

---

## 8. Control surface API (local WebSocket)

Hush runs a WebSocket server on `ws://127.0.0.1:47823` (configurable). Localhost-only binding is sufficient for personal use; no auth token required (optional nice-to-have).

### 8.1 Messages (JSON)

**Client → Hush**
```json
{ "type": "command", "action": "toggle" }
{ "type": "command", "action": "setEnabled", "value": true }
{ "type": "command", "action": "mute" }          // toggles
{ "type": "command", "action": "setMuted", "value": true }
{ "type": "command", "action": "setStrength", "value": "light" | "medium" | "max" }
{ "type": "command", "action": "cycleStrength" }
{ "type": "command", "action": "setEngine", "value": "apple" | "deepFilter" }
{ "type": "subscribe", "topics": ["state", "meter"] }
```

**Hush → Client**
```json
{ "type": "state", "enabled": true, "muted": false, "strength": "medium",
  "engine": "apple", "inputConnected": true, "driverInstalled": true }
{ "type": "meter", "rms": -32.1, "peak": -18.4 }   // dBFS, ~15 Hz while subscribed
{ "type": "error", "message": "..." }
```

State is pushed on every change and immediately on subscribe. The same command layer backs the menu bar UI, global hotkeys, and the socket — one source of truth.

**Nice-to-have:** a `hush://` URL scheme (`hush://toggle`, `hush://mute`) and App Intents for Shortcuts, reusing the same command layer.

---

## 9. Stream Deck plugin

- Plugin UUID: `com.erikreagan.hush`
- Built with `@elgato/streamdeck` v2 + Stream Deck CLI (`streamdeck create`), TypeScript.
- Maintains one WebSocket connection to Hush; auto-reconnects with backoff. When Hush isn't running, all keys show a dimmed "Hush offline" image.

### 9.1 Actions

| Action | Controller | Behavior | Display |
|---|---|---|---|
| **Noise Removal** | Key | Press = toggle | Two states: On (filled icon) / Off (outline). Reflects state pushed from app, not just local presses |
| **Strength** | Key | Press = cycle Light→Medium→Max. Property Inspector option: "Set specific preset" instead of cycle | Title shows current preset |
| **Mute** | Key | Press = toggle mute. PI option: push-to-talk mode (mute released while held) | Red when muted |
| **Level Meter** | Key | Press = toggle noise removal (optional, configurable) | Live vertical meter rendered as SVG data URL via `setImage`, ~10 updates/sec max |
| **Hush Dial** | Dial (Stream Deck +) | Rotate = cycle strength; press = toggle noise removal; touch = mute | Touch strip layout with level bar + engine/preset text |

- Use `showAlert()` when a command fails (e.g., app offline).
- Throttle meter image updates to ≤ 10/sec per key to avoid flooding the Stream Deck app; only send meter updates while a meter action is visible (`willAppear`/`willDisappear`).
- Property Inspector: port override (default 47823).

---

## 10. Repository layout

```
hush/
├── SPEC.md
├── Package.swift             # One Swift package: targets Hush (app), HushAudio, HushAudioTests
├── App/                      # Menu bar app sources (SwiftUI) + Info.plist
├── Packages/HushAudio/       # Audio library: devices, pipeline, ring buffer + resampler, Apple engine
├── Tests/                    # Unit tests (ring buffer, drift resampler, Apple engine)
├── Driver/blackhole/         # BlackHole upstream (submodule, unmodified)
├── scripts/                  # build-driver, install-driver, uninstall-driver, build-app, make-signing-cert
├── build/                    # Build output (git-ignored): Hush.app, driver/Hush.driver
│
│   Planned, not created yet:
├── Engines/deepfilter/       # DeepFilterNet submodule + FFI crate + build script (M4)
├── StreamDeck/com.erikreagan.hush.sdPlugin/  # TS plugin (M6)
└── Tools/hush-cli/           # Offline WAV processor for engine A/B testing (M4)
```

**`hush-cli`:** `hush-cli process --engine apple|deepFilter --strength medium in.wav out.wav`. Uses the exact same engine code as the app. Used to compare engines on recorded samples and for automated regression tests.

---

## 11. Milestones & acceptance criteria

Build in this order. Each milestone should be demoable before moving on.

**Status (2026-11-20, end of day):** Driver installed; app running against a Lewitt CONNECT 2 (44.1 kHz) — the Audient iD2 arrives 2026-11-22. M1, M2, and M5 are built. Erik's first 30-second listening test confirmed the noise removal is clearly audible ("great starting point"); a detailed listening pass (voice naturalness, typing suppression, how the delay feels on calls) is still open. Measured: ~76 ms added delay, room noise floor −56 → −72 dBFS on Medium, test recordings free of gaps and clicks. The 30-minute soak (`node scripts/test-control.mjs 1800`) passed on the CONNECT 2 with the Apple engine on Medium: zero underruns and overruns, delay steady at 76 ms, ~1% CPU, 38 MB memory (quiet room, no speech). It needs repeating on the Audient iD2. M3 is mostly built (see below). M4, M6, M7 not started.

**M1 — Passthrough plumbing** *(built; acceptance pending)*
- Driver builds and installs; "Hush Mic" appears in System Settings → Sound → Input.
- App captures the selected mic channel and renders to the virtual device; Zoom/QuickTime hear the raw mic via Hush Mic (noise removal off).
- ✅ 30-minute recording with no clicks, dropouts, or drift-related glitches. Latency measured and displayed.

**M2 — Apple engine** *(built; acceptance pending)*
- AUSoundIsolation in the chain; toggle and Light/Medium/Max work with smooth transitions.
- Parameter tree captured (see §2).
- ✅ Fan noise and A/C hum are clearly reduced in a test recording; toggling makes no click.

**M3 — Menu bar app complete** *(mostly built)*
- Built and verified remotely: default-input management (claim on launch once audio is flowing; restore the previous input on quit or SIGTERM, only if Hush Mic is still the default), launch at login (registered; default ON), Settings window, high-pass filter (measured −3 dB at the cutoff, flat above), input/output gain trims, 30-second test recorder.
- Built but untested (need someone at the Mac): hot-plug handling (silence + error + notification on unplug, auto-resume; never falls back to another mic), rebuild on wake, A/B hold-to-compare, the Settings window's appearance.
- Not built: global hotkeys, Listen (self-monitoring), CPU % in Diagnostics, per-engine custom strength, handling a mid-session sample-rate change on the mic.
- ✅ Unplug and replug the mic mid-call → audio resumes on its own, with a notification on unplug.

**M4 — DeepFilterNet engine**
- libDF builds and links; engine selectable; crossfade on switch.
- `hush-cli` processes WAVs with both engines.
- ✅ Typing and mouse clicks are audibly reduced versus the Apple engine on the same test clip; CPU and latency within targets.

**M5 — Control surface API** *(built and verified)*
- `node scripts/test-control.mjs [watchSeconds]` exercises every command against the running app, restores state, and optionally watches meter + stats (this doubles as the soak test).
- Two additions beyond §8.1: a `stats` topic (`latencyMs`, `driftPPM`, `underruns`, `overruns`) and a `recordTest` command (value = seconds). `setEngine` accepts only `apple` until M4. The port is read from the `port` user default; there is no UI for it yet.
- WebSocket server per §8, shared command layer.
- ✅ `websocat ws://127.0.0.1:47823` can toggle, mute, change preset/engine, and receives state + meter streams.

**M6 — Stream Deck plugin**
- All actions in §9.1.
- ✅ Changing state from the menu bar updates Stream Deck keys within 100 ms; quitting Hush shows "offline" on keys within 2 s; relaunching reconnects automatically.

**M7 — Soak & polish**
- 2-hour soak with zero dropouts; memory stable.
- README with install steps, driver install/uninstall, and troubleshooting.

---

## 12. Testing

- **Unit:** ring buffer (fill targeting, drift correction, under/overrun recovery), strength mapping, command layer, message encoding. Run with `swift test`. Existing so far: ring buffer round-trip and overflow, 60-second drift simulation, Apple engine noise reduction.
- **Engine regression:** fixed WAV corpus (silence; voice only; voice + fan; voice + typing; voice + desk thuds; voice + A/C hum). `hush-cli` output compared against stored references via RMS-difference thresholds, so engine or build changes don't silently degrade quality.
- **Manual QA checklist:** Zoom, Google Meet in Chrome and Safari, Slack huddle, QuickTime recording, Riverside/browser recorder; confirm Hush Mic works in each **without touching any Mic Mode setting**.

---

## 13. Edge cases

- Hush not running → Hush Mic is silent. Mitigations: launch at login on by default; icon makes state obvious; Stream Deck shows "offline." (Optional: a tiny LaunchAgent watchdog that relaunches Hush if it crashes.)
- Interface sample rate ≠ 48 kHz → handled by the drift-correcting resampler (§4.2); never force-change the mic's sample rate. A mid-session sample-rate change on the mic is not handled yet (M3, with hot-plug).
- Another app takes exclusive ("hog mode") access to the iD2 → show error state; recover when released.
- Mac sleep/wake → rebuild audio units on wake if needed; no stuck silence.
- Default-input restore on quit should only restore if Hush Mic is still the default (don't stomp a manual change).

---

## 14. Open questions (decide during build)

Resolved: the app name is Hush; the Stream Deck hardware is a Stream Deck +, so the dial action stays.

1. App icon / custom menu bar glyph.
2. After M4 listening tests: does one engine win outright? If so, consider making it the default and keeping the other as fallback.
3. Whether the iD2's onboard HPF/EQ applies to the USB recording path (check with the 30-second test recorder). If yes, leave Hush's HPF off by default.
4. Is ~75 ms of added delay with the Apple engine acceptable on calls? If not, DeepFilterNet's no-lookahead model (~20 ms) becomes the likely default.
5. Does the hidden Hush Feed device open correctly by UID on a live install (§5)? If not, switch to the single-visible-device fallback.
