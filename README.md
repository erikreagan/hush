# Hush

A Mac menu bar app that removes background noise from your microphone before any app hears it.

Hush listens to your real microphone, removes noise such as fans, typing and clicks, and feeds the
clean audio into a virtual microphone called **Hush Mic**. Zoom, Meet, Slack, browsers and recording
apps pick Hush Mic as their input, or use it automatically because Hush sets it as the Mac's default
input.

- Two noise-removal engines you can switch between: Apple's built-in voice isolation and
  [DeepFilterNet 3](https://github.com/Rikorose/DeepFilterNet)
- Three strength levels, hard mute, hold-to-compare against the raw mic, and a Listen monitor
- Global keyboard shortcuts
- An Elgato Stream Deck plugin (toggle, strength, mute, live level meter)
- `hush-cli`, which runs the same engines over a WAV file for A/B comparisons

Hush was built for one person's desk and is shared as-is. There is no installer or signed release:
you build it yourself.

## Requirements

- An Apple silicon Mac running macOS 15 or later
- Xcode command line tools (`xcode-select --install`)
- [Rust](https://rustup.rs), to build DeepFilterNet
- Node.js, only if you want the Stream Deck plugin

## Build and install

```sh
git clone --recursive https://github.com/erikreagan/hush.git
cd hush

scripts/install-driver.sh      # builds and installs the virtual mic; needs admin, briefly interrupts Mac audio
scripts/make-signing-cert.sh   # optional, one time: keeps the microphone permission across rebuilds
scripts/build-app.sh           # builds build/Hush.app (builds DeepFilterNet on the first run)
open build/Hush.app
```

Hush asks for microphone access on first launch. To remove the virtual microphone, run
`scripts/uninstall-driver.sh`.

### Stream Deck plugin

```sh
cd StreamDeck
npm install
npm run build
npm run link
```

### Command line

```sh
swift run hush-cli process --engine deepFilter --strength max in.wav out.wav
```

## How it works

macOS apps can only read audio from devices, so Hush installs a software-only audio device and
writes the cleaned signal into it. The device is [BlackHole](https://github.com/ExistentialAudio/BlackHole),
built unmodified with a different name. [SPEC.md](SPEC.md) has the full design, the control API the
Stream Deck plugin uses, and test results.

## License

Hush is licensed under the [GNU General Public License v3.0](LICENSE).

It builds on two projects included as git submodules, each under its own license:

- [BlackHole](https://github.com/ExistentialAudio/BlackHole) (GPL-3.0), the virtual audio driver
- [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) (MIT / Apache-2.0), the noise-removal model and runtime
