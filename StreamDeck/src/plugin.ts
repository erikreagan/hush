// Hush Stream Deck plugin (SPEC §9). Talks to the Hush menu bar app over its local WebSocket (SPEC §8).
// Keys and the dial are drawn from the state Hush pushes, never from local presses.
import streamDeck, {
    action, SingletonAction,
    type DialAction, type DialRotateEvent, type KeyAction, type KeyDownEvent, type KeyUpEvent,
    type WillAppearEvent, type DidReceiveSettingsEvent,
} from "@elgato/streamdeck";
import type { JsonObject } from "@elgato/utils";

import { LABEL, OFFLINE, STRENGTHS, dialIcon, fraction, meterFace, muteFace, noiseFace, strengthFace, type HushState, type Strength } from "./faces";

/** One auto-reconnecting connection to Hush. `state` is null while Hush isn't running. */
const hush = {
    state: null as HushState | null,
    meter: { rms: -120, peak: -120 },
    port: 47823,
    socket: undefined as WebSocket | undefined,
    retryMs: 500,
    onState: () => {},
    onMeter: () => {},

    connect() {
        const socket = new WebSocket(`ws://127.0.0.1:${this.port}`);
        this.socket = socket;
        socket.onopen = () => {
            this.retryMs = 500;
            socket.send(JSON.stringify({ type: "subscribe", topics: ["state", "meter"] }));
        };
        socket.onmessage = (event) => {
            const message = JSON.parse(String(event.data));
            if (message.type === "state") { this.state = message; this.onState(); }
            else if (message.type === "meter") { this.meter = message; this.onMeter(); }
            else if (message.type === "error") streamDeck.logger.warn(`Hush: ${message.message}`);
        };
        socket.onclose = () => {
            if (this.socket !== socket) return;   // replaced by a newer connection (port change)
            if (this.state) { this.state = null; this.onState(); }
            setTimeout(() => this.connect(), this.retryMs);
            this.retryMs = Math.min(this.retryMs * 2, 4000);   // back off, but notice a relaunch within seconds
        };
        socket.onerror = () => {};   // onclose follows and handles it
    },

    /** Returns false if Hush is offline, so the caller can flash an alert. */
    send(action: string, value?: boolean | string): boolean {
        if (!this.state || this.socket?.readyState !== WebSocket.OPEN) return false;
        this.socket.send(JSON.stringify({ type: "command", action, ...(value === undefined ? {} : { value }) }));
        return true;
    },

    setPort(port: number) {
        if (!port || port === this.port) return;
        this.port = port;
        this.socket?.close();
        this.socket = undefined;
        if (this.state) { this.state = null; this.onState(); }
        this.connect();
    },
};

// ---- Actions ----

/** Base for key actions: redraws all visible keys when Hush's state changes; alerts when a press can't be delivered. */
abstract class HushKey<Settings extends JsonObject = JsonObject> extends SingletonAction<Settings> {
    protected settings = new Map<string, Settings>();
    protected abstract face(state: HushState, settings: Settings): string;

    refresh() {
        for (const item of this.actions) {
            if (item.isKey()) void item.setImage(hush.state ? this.face(hush.state, this.settings.get(item.id) ?? ({} as Settings)) : OFFLINE);
        }
    }
    override onWillAppear(ev: WillAppearEvent<Settings>) { this.settings.set(ev.action.id, ev.payload.settings); this.refresh(); }
    override onDidReceiveSettings(ev: DidReceiveSettingsEvent<Settings>) { this.settings.set(ev.action.id, ev.payload.settings); this.refresh(); }
    protected command(target: KeyAction<Settings> | DialAction<Settings>, name: string, value?: boolean | string) {
        if (!hush.send(name, value)) void target.showAlert();
    }
}

@action({ UUID: "com.erikreagan.hush.noise-removal" })
class NoiseRemoval extends HushKey {
    protected face(state: HushState) { return noiseFace(state); }
    override onKeyDown(ev: KeyDownEvent) { this.command(ev.action, "toggle"); }
}

type StrengthSettings = { mode?: "cycle" | Strength };
@action({ UUID: "com.erikreagan.hush.strength" })
class StrengthKey extends HushKey<StrengthSettings> {
    protected face(state: HushState, settings: StrengthSettings) {
        return strengthFace(state, settings.mode && settings.mode !== "cycle" ? settings.mode : undefined);
    }
    override onKeyDown(ev: KeyDownEvent<StrengthSettings>) {
        const mode = ev.payload.settings.mode ?? "cycle";
        if (mode === "cycle") this.command(ev.action, "cycleStrength");
        else this.command(ev.action, "setStrength", mode);
    }
}

type MuteSettings = { pushToTalk?: boolean };
@action({ UUID: "com.erikreagan.hush.mute" })
class Mute extends HushKey<MuteSettings> {
    protected face(state: HushState) { return muteFace(state); }
    override onKeyDown(ev: KeyDownEvent<MuteSettings>) {
        if (ev.payload.settings.pushToTalk) this.command(ev.action, "setMuted", false);   // talk while held
        else this.command(ev.action, "mute");
    }
    override onKeyUp(ev: KeyUpEvent<MuteSettings>) {
        if (ev.payload.settings.pushToTalk) this.command(ev.action, "setMuted", true);
    }
}

type MeterSettings = { pressToggles?: boolean };
@action({ UUID: "com.erikreagan.hush.meter" })
class Meter extends HushKey<MeterSettings> {
    protected face(state: HushState) { return meterFace(hush.meter.rms, hush.meter.peak, !state.muted); }
    override onKeyDown(ev: KeyDownEvent<MeterSettings>) {
        if (ev.payload.settings.pressToggles ?? true) this.command(ev.action, "toggle");
    }
}

/** Stream Deck + dial: rotate = strength, press = noise removal on/off, touch = mute. Uses the built-in bar layout. */
@action({ UUID: "com.erikreagan.hush.dial" })
class HushDial extends SingletonAction {
    refresh() {
        const state = hush.state;
        for (const item of this.actions) {
            if (!item.isDial()) continue;
            void item.setFeedback(state
                ? {
                    title: state.muted ? "Hush · Muted" : state.enabled ? "Hush" : "Hush · Off",
                    value: `${LABEL[state.strength]} · ${state.engine === "apple" ? "Apple" : "DeepFilterNet"}`,
                    indicator: { value: Math.round(100 * fraction(hush.meter.rms)), opacity: state.muted ? 0.3 : 1 },
                    icon: dialIcon(state),
                }
                : { title: "Hush", value: "Offline", indicator: { value: 0 }, icon: OFFLINE });
        }
    }
    override onWillAppear() { this.refresh(); }
    override onDialRotate(ev: DialRotateEvent) {
        const state = hush.state;
        if (!state) return void ev.action.showAlert();
        const index = Math.max(0, Math.min(2, STRENGTHS.indexOf(state.strength) + Math.sign(ev.payload.ticks)));
        if (STRENGTHS[index] !== state.strength) hush.send("setStrength", STRENGTHS[index]);
    }
    override onDialDown(ev: { action: DialAction }) { if (!hush.send("toggle")) void ev.action.showAlert(); }
    override onTouchTap(ev: { action: DialAction }) { if (!hush.send("mute")) void ev.action.showAlert(); }
}

const keys = [new NoiseRemoval(), new StrengthKey(), new Mute()];
const meter = new Meter(), dial = new HushDial();
for (const item of [...keys, meter, dial]) streamDeck.actions.registerAction(item);

hush.onState = () => { for (const item of [...keys, meter, dial]) item.refresh(); };

// Meter frames arrive ~15×/s; redraw at most 10×/s, and only what's on screen (`actions` is the visible set).
let lastMeterDraw = 0;
hush.onMeter = () => {
    const now = Date.now();
    if (now - lastMeterDraw < 100) return;
    lastMeterDraw = now;
    meter.refresh();
    dial.refresh();
};

streamDeck.settings.onDidReceiveGlobalSettings<{ port?: string | number }>((ev) => hush.setPort(Number(ev.settings.port) || 47823));

await streamDeck.connect();
const globals = await streamDeck.settings.getGlobalSettings<{ port?: string | number }>();
hush.port = Number(globals.port) || 47823;
hush.connect();
