// Key faces for the Hush Stream Deck plugin: every face is a 144×144 SVG built from Hush's current state.
export type Strength = "light" | "medium" | "max";
export const STRENGTHS: Strength[] = ["light", "medium", "max"];
export const LABEL = { light: "Light", medium: "Medium", max: "Max" };
export type HushState = { enabled: boolean; muted: boolean; strength: Strength; engine: "apple" | "deepFilter"; inputConnected: boolean };

export const BLUE = "#0A84FF", RED = "#FF453A", DIM = "#636366", DARK = "#1C1C1E", WHITE = "#FFFFFF";

export const svg = (background: string, body: string) =>
    "data:image/svg+xml;charset=utf8," + encodeURIComponent(
        `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144"><rect width="144" height="144" fill="${background}"/>${body}</svg>`);

const caption = (text: string, color: string) =>
    `<text x="72" y="128" text-anchor="middle" font-family="-apple-system, Helvetica, Arial" font-size="24" font-weight="600" fill="${color}">${text}</text>`;

export const waveform = (color: string, filled: boolean) => [26, 52, 76, 52, 26].map((height, i) =>
    `<rect x="${31 + i * 18}" y="${58 - height / 2}" width="10" height="${height}" rx="5" ${filled ? `fill="${color}"` : `fill="none" stroke="${color}" stroke-width="3"`}/>`).join("");

export const mic = (color: string, slashed: boolean) =>
    `<rect x="59" y="18" width="26" height="48" rx="13" fill="${color}"/>` +
    `<path d="M47 54a25 25 0 0 0 50 0M72 79v13M57 92h30" fill="none" stroke="${color}" stroke-width="6" stroke-linecap="round"/>` +
    (slashed ? `<path d="M40 22L104 90" stroke="${color}" stroke-width="7" stroke-linecap="round"/>` : "");

const steps = (level: number, color: string) => [22, 40, 58].map((height, i) =>
    `<rect x="${40 + i * 24}" y="${88 - height}" width="16" height="${height}" rx="5" fill="${i <= level ? color : "#3A3A3C"}"/>`).join("");

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

export const OFFLINE = svg(DARK, waveform("#48484A", false) + caption("Offline", DIM));

export function noiseFace(state: HushState): string {
    return state.enabled ? svg(BLUE, waveform(WHITE, true) + caption("On", WHITE)) : svg(DARK, waveform(DIM, false) + caption("Off", DIM));
}
export function muteFace(state: HushState): string {
    return state.muted ? svg(RED, mic(WHITE, true) + caption("Muted", WHITE)) : svg(DARK, mic(WHITE, false) + caption("Live", "#AEAEB2"));
}
export function strengthFace(state: HushState, fixed?: Strength): string {
    const shown = fixed ?? state.strength, active = state.enabled && shown === state.strength;
    return svg(DARK, steps(STRENGTHS.indexOf(shown), active ? BLUE : DIM) + caption(LABEL[shown], active ? WHITE : DIM));
}
