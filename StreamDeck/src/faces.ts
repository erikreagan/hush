// Key faces for the Hush Stream Deck plugin: every face is a 144×144 SVG built from Hush's current state.
export type Strength = "light" | "medium" | "max";
export const STRENGTHS: Strength[] = ["light", "medium", "max"];
export const LABEL = { light: "Light", medium: "Medium", max: "Max" };
export type PresetInfo = { id: string; name: string; available?: boolean };
export type HushState = {
    enabled: boolean; muted: boolean; strength: Strength; engine: "apple" | "deepFilter"; inputConnected: boolean;
    preset?: PresetInfo | null;   // the preset in use; null = Manual (absent on a Hush older than presets)
    presets?: PresetInfo[];
};

// The palette follows the app icon (scripts/make-icon.swift): plum gradient, white disc, dark plum bars.
export const RED = "#FF453A", DIM = "#636366", DARK = "#1C1C1E", WHITE = "#FFFFFF", INK = "#241B30";
export const PLUM = "url(#plum)";   // the gradient below, usable as any face's background

export const svg = (background: string, body: string) =>
    "data:image/svg+xml;charset=utf8," + encodeURIComponent(
        `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">` +
        `<defs><linearGradient id="plum" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5C4675"/><stop offset="1" stop-color="#241B30"/></linearGradient></defs>` +
        `<rect width="144" height="144" fill="${background}"/>${body}</svg>`);

const caption = (text: string, color: string) =>
    `<text x="72" y="128" text-anchor="middle" font-family="-apple-system, Helvetica, Arial" font-size="24" font-weight="600" fill="${color}">${text}</text>`;

/** A slash with a gap cut around it; `gap` is the colour behind it. */
const slash = (d: string, color: string, gap: string) =>
    `<path d="${d}" stroke="${gap}" stroke-width="15" stroke-linecap="round"/><path d="${d}" stroke="${color}" stroke-width="6" stroke-linecap="round"/>`;

/** The Hush glyph: a disc with the app icon's six uneven bars. Sits above a caption by default; pass the centre and radius to fill a face. */
const disc = (color: string, bars: string, look: { outlined?: boolean; slashedOn?: string } = {}, cx = 72, cy = 56, r = 44) => {
    const k = r / 300, width = 40 * k, pitch = 64 * k, a = r * 0.86;   // bar geometry on the app icon's 300-radius disc
    return (look.outlined ? `<circle cx="${cx}" cy="${cy}" r="${r - 2.5}" fill="none" stroke="${color}" stroke-width="5"/>` : `<circle cx="${cx}" cy="${cy}" r="${r}" fill="${color}"/>`) +
        [80, 180, 320, 130, 240, 110].map((height, i) =>
            `<rect x="${cx - (5 * pitch + width) / 2 + i * pitch}" y="${cy - height * k / 2}" width="${width}" height="${height * k}" rx="${width / 2}" fill="${bars}"/>`).join("") +
        (look.slashedOn ? slash(`M${cx - a} ${cy - a}L${cx + a} ${cy + a}`, color, look.slashedOn) : "");
};

const mic = (color: string, slashedOn?: string) =>
    `<rect x="59" y="18" width="26" height="48" rx="13" fill="${color}"/>` +
    `<path d="M47 54a25 25 0 0 0 50 0M72 79v13M57 92h30" fill="none" stroke="${color}" stroke-width="6" stroke-linecap="round"/>` +
    (slashedOn ? slash("M40 22L104 90", color, slashedOn) : "");

const steps = (level: number, lit: string, unlit: string) => [22, 40, 58].map((height, i) =>
    `<rect x="${40 + i * 24}" y="${88 - height}" width="16" height="${height}" rx="5" fill="${i <= level ? lit : unlit}"/>`).join("");

/** Three stacked cards: the front one filled, two peeking out behind. */
const stack = (color: string, behind: string) =>
    `<rect x="46" y="18" width="52" height="14" rx="5" fill="${behind}"/><rect x="38" y="34" width="68" height="14" rx="5" fill="${behind}"/>` +
    `<rect x="30" y="50" width="84" height="42" rx="8" fill="${color}"/>`;

/** Preset names are the user's text: escape them for SVG and keep them to what fits under the glyph. */
const label = (text: string) => (text.length > 9 ? text.slice(0, 8) + "…" : text).replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`);

export const fraction = (dB: number) => Math.max(0, Math.min(1, (dB + 60) / 60));

export function meterFace(rms: number, peak: number, live: boolean): string {
    const height = Math.round(116 * fraction(rms)), tick = 130 - 116 * fraction(peak);
    return svg(DARK,
        `<defs><linearGradient id="g" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#30D158"/><stop offset="0.7" stop-color="#30D158"/><stop offset="0.85" stop-color="#FFD60A"/><stop offset="1" stop-color="${RED}"/></linearGradient>` +
        `<clipPath id="c"><rect x="52" y="${130 - height}" width="40" height="${height}"/></clipPath></defs>` +
        `<rect x="52" y="14" width="40" height="116" rx="12" fill="#2C2C2E"/>` +
        `<rect x="52" y="14" width="40" height="116" rx="12" fill="url(#g)" clip-path="url(#c)" opacity="${live ? 1 : 0.35}"/>` +
        (peak > -59 ? `<rect x="52" y="${tick - 2}" width="40" height="3" fill="${WHITE}" opacity="0.8"/>` : ""));
}

export const OFFLINE = svg(DARK, disc("#48484A", "#48484A", { outlined: true }) + caption("Offline", DIM));

export function noiseFace(state: HushState): string {
    return state.enabled ? svg(PLUM, disc(WHITE, INK) + caption("On", WHITE)) : svg(DARK, disc(DIM, DIM, { outlined: true }) + caption("Off", DIM));
}
export function muteFace(state: HushState): string {
    return state.muted ? svg(RED, mic(WHITE, RED) + caption("Muted", WHITE)) : svg(DARK, mic(WHITE) + caption("Live", "#AEAEB2"));
}
export function strengthFace(state: HushState, fixed?: Strength): string {
    const shown = fixed ?? state.strength, active = state.enabled && shown === state.strength;
    return active ? svg(PLUM, steps(STRENGTHS.indexOf(shown), WHITE, "#FFFFFF40") + caption(LABEL[shown], WHITE))
        : svg(DARK, steps(STRENGTHS.indexOf(shown), DIM, "#3A3A3C") + caption(LABEL[shown], DIM));
}
/** `fixed` is the preset name typed into the key's settings; without it the key shows whichever preset is in use ("Manual" if none). */
export function presetFace(state: HushState, fixed?: string): string {
    const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
    const known = fixed ? state.presets?.find((p) => same(p.name, fixed)) : undefined;
    const lit = fixed ? !!state.preset && same(state.preset.name, fixed) : !!state.preset;
    const missing = fixed ? !known || known.available === false : false;   // no such preset, or its mic is unplugged
    const text = label(fixed ?? state.preset?.name ?? "Manual");
    return lit ? svg(PLUM, stack(WHITE, "#FFFFFF60") + caption(text, WHITE))
        : svg(DARK, stack(missing ? "#3A3A3C" : DIM, "#3A3A3C") + caption(text, DIM));
}
/** The dial's touch-strip icon: no caption and no background square, so a filled disc carries the colour: plum on, grey off, red muted. */
export function dialIcon(state: HushState): string {
    const r = 62, gap = r * 0.58, reach = r * 0.86;   // the gap stays inside the disc; the slash pokes out past it
    if (state.muted) return svg("none", disc(RED, WHITE, {}, 72, 72, r) +
        `<path d="M${72 - gap} ${72 - gap}L${72 + gap} ${72 + gap}" stroke="${RED}" stroke-width="17" stroke-linecap="round"/>` +
        `<path d="M${72 - reach} ${72 - reach}L${72 + reach} ${72 + reach}" stroke="${WHITE}" stroke-width="7" stroke-linecap="round"/>`);
    return svg("none", state.enabled ? disc(PLUM, WHITE, {}, 72, 72, r) : disc(DIM, DARK, {}, 72, 72, r));
}
