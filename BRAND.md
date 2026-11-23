# Hush brand foundation

A small brand system for Hush: enough to keep the site, the app icon and anything made later
consistent. Decided with Erik on 2026-11-23. Items marked *(proposed)* were filled in to complete the
system and have not been explicitly approved; everything else was chosen directly.

## 1. What Hush is

Hush is a Mac menu bar app that removes background noise from your microphone before any app hears
it.

- **Audience:** anyone who spends time on calls. Not only people who build software or own audio
  gear. Write and design for someone who has never heard the words "virtual microphone".
- **Personality:** calm and quiet. The brand behaves like the product: it takes things away.
- **Tagline:** Quieter calls. Every app.

### Principles

1. **Remove before adding.** If a page works without an element, leave it out. Space is the main
   design material.
2. **Say the least that is still clear.** Short headlines, plain sentences. The page explains; the
   headline doesn't have to.
3. **Low contrast in mood, high contrast in legibility.** Colours are subdued, but text always meets
   readable contrast.
4. **The app stays a Mac app.** Inside Hush, use standard macOS controls and colours. The brand shows
   up in the icon and on the web, not as a custom skin.

## 2. Voice

- **The product's voice.** No "I" or "we". "Hush removes…", "Pick Hush Mic…".
- **Sentence case everywhere**, including headlines: "Quieter calls. Every app."
- **Plain words first.** Say "fans, typing and clicks", not "stationary and transient noise". Technical
  terms (virtual microphone, DeepFilterNet, latency) are welcome further down the page, after the
  plain version.
- **Honest about what it is.** Hush has no installer or signed release today; you build it yourself.
  Say so plainly where it matters. Don't imply a download that doesn't exist.
- **No hype.** No "revolutionary", "AI-powered", "crystal clear", exclamation marks, or promises about
  numbers the spec hasn't confirmed.

| Instead of | Write |
|---|---|
| AI-powered noise cancellation! | Removes fans, typing and clicks from your mic. |
| We built Hush to… | Hush was built to… |
| Seamlessly integrates with all your apps | Works in any app that uses a microphone. |

## 3. Colour: Dusk

Soft plum and lilac haze. Neutrals carry a slight plum tint; there are no pure greys.

| Token | Light | Dark | Use |
|---|---|---|---|
| `bg` | `#F4F1F5` | `#17121D` | Page background |
| `ink` | `#221A2B` | `#ECE7F0` | Text |
| `muted` | `#6A6074` | `#9A90A5` | Secondary text |
| `brand` | `#46345A` | `#ECE7F0` | The mark, large brand shapes |
| `accent` | `#7A56A0` | `#C3A5E0` | Buttons, links, the clean signal in waveforms |
| `line` | `#E0DAE4` | `#2B2334` | Hairlines and borders |

- **App icon tile gradient:** `#5C4675` (top) to `#241B30` (bottom), white disc, bars in `#241B30`.
- Light and dark are both first-class. Follow the visitor's system setting.
- One accent only. Don't introduce a second brand colour. Status colours (red for mute or errors,
  orange for warnings) belong to the app and follow macOS.

## 4. Type

| Role | Face | Notes |
|---|---|---|
| Display | **Newsreader** (serif), weight about 350 | Headlines and the name "Hush". Light, never bold. Tight line height (about 1.1), slightly negative letter spacing. |
| Text | **Instrument Sans**, 400 and 500 | Everything else: body, buttons, labels. |
| Code | System monospace (`ui-monospace`, SF Mono, Menlo) | Terminal commands only. |

Fallbacks: Georgia for display, the system sans-serif for text. Both faces are free on Google Fonts
(SIL Open Font License). Keep body text near 65 characters per line.

## 5. The mark

A solid disc with six waveform bars cut out of it. On the site and everywhere outside the Mac app
icon, the disc stands alone with no tile behind it.

```svg
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
  <circle cx="50" cy="50" r="50" fill="#46345A"/>
  <g transform="translate(50 50)" fill="#F4F1F5">
    <rect x="-28" y="-5"  width="6" height="10" rx="3"/>
    <rect x="-18" y="-12" width="6" height="24" rx="3"/>
    <rect x="-8"  y="-22" width="6" height="44" rx="3"/>
    <rect x="2"   y="-11" width="6" height="22" rx="3"/>
    <rect x="12"  y="-17" width="6" height="34" rx="3"/>
    <rect x="22"  y="-6"  width="6" height="12" rx="3"/>
  </g>
</svg>
```

- **Colours:** disc in `brand`, bars in the background colour behind it (so they read as cut out).
  On dark pages that is a light disc with dark bars.
- **Lockup:** disc, then "Hush" in the display face, vertically centred, with a gap of about a
  quarter of the disc's width.
- **Clear space** *(proposed)*: keep at least half the disc's width empty around it.
- **Smallest size** *(proposed)*: 16 px. Below that the bars close up.
- **The tile** (rounded square with a gradient, white disc) is the Mac app icon only.
- Don't recolour the disc outside the palette, add effects, rotate it, or redraw the bars at other
  heights.

**Open task:** the app icon, menu bar icons and Stream Deck icons are still navy
(`#2B4686` to `#0F1B3D`, set in `scripts/make-icon.swift`). Erik chose to recolour them to the Dusk
tile gradient above. That is app work, separate from the site.

## 6. Shape

Circles and pills, echoing the disc.

- Buttons and tags are fully rounded (pill shaped).
- Panels, images and code blocks get generous soft corners *(proposed: 16 to 24 px)*.
- Hairlines in `line`, 1 px. No drop shadows *(proposed)*; separate things with space and tint.

## 7. Waveform

The waveform is the brand's graphic device and can be used freely: as illustration, divider,
background texture or accent.

- Build it from the same vocabulary as the mark: vertical bars with fully rounded ends, even spacing.
- The signature use is the comparison: a **raw mic** trace in `muted` with a visible noise floor
  between words, beside a **Hush Mic** trace in `accent` that falls to silence between words.
- Keep it calm. Bars, not jagged lines or glowing spectrums. Used large, it should be faint.
- Traces are illustrations unless they come from a real recording. Don't present a drawn trace as a
  measurement.

## 8. Motion *(proposed)*

Little and slow. A waveform may settle or breathe; nothing bounces, flashes or loops for attention.
Respect the visitor's reduced-motion setting, and make every page complete without animation.
