// End-to-end check of the control socket against a running Hush. Usage: node scripts/test-control.mjs [watchSeconds]
// Exercises every command, restores the original state, then optionally watches meter + stats.
import assert from "node:assert/strict";
const ws = new WebSocket("ws://127.0.0.1:47823");
const inbox = [];
let state, stats, meters = [];
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "state") state = m;
  if (m.type === "stats") stats = m;
  if (m.type === "meter") meters.push(m);
  inbox.push(m);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const send = async (m) => { ws.send(JSON.stringify(m)); await sleep(150); };
const command = (action, value) => send({ type: "command", action, ...(value === undefined ? {} : { value }) });

await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = () => reject(new Error("Hush is not running")); });
await send({ type: "subscribe", topics: ["state", "meter", "stats"] });
assert.ok(state, "state is pushed immediately on subscribe");
const original = { ...state };
console.log("state:", JSON.stringify(original));

await command("setEnabled", false); assert.equal(state.enabled, false);
await command("toggle");            assert.equal(state.enabled, true);
await command("setMuted", true);    assert.equal(state.muted, true);
await command("mute");              assert.equal(state.muted, false);
await command("setStrength", "light"); assert.equal(state.strength, "light");
await command("cycleStrength");     assert.equal(state.strength, "medium");
await command("cycleStrength");     assert.equal(state.strength, "max");
await command("setEngine", "apple");
inbox.length = 0;
await command("setStrength", "loud"); assert.equal(inbox.find((m) => m.type === "error")?.type, "error");
await command("nonsense");
ws.send("not json"); await sleep(150);
assert.equal(inbox.filter((m) => m.type === "error").length, 3, "bad input gets error replies");
assert.ok(meters.length > 10, "meter stream flows at ~15 Hz");

// Presets. Using one replaces the live settings, so only switch if a preset is in use to come back to:
// from Manual there would be no way to restore what was there.
assert.ok(Array.isArray(state.presets) && "preset" in state, "state lists the presets and the one in use");
await command("setStrength", original.strength);
await command("setEngine", original.engine);
inbox.length = 0;
await command("setPreset", "no such preset \u0000");
await command("setPreset");
assert.equal(inbox.filter((m) => m.type === "error").length, 2, "setPreset refuses an unknown or missing name");
if (original.preset) {
  const others = state.presets.filter((p) => p.available && p.id !== original.preset.id);
  await command("cyclePreset"); await sleep(300);
  if (others.length) assert.notEqual(state.preset?.id, original.preset.id, "cyclePreset moves to another preset");
  await command("setPreset", original.preset.id); await sleep(300);
  assert.equal(state.preset?.id, original.preset.id, "setPreset by id comes back");
  await command("setPreset", original.preset.name.toUpperCase()); await sleep(300);
  assert.equal(state.preset?.name, original.preset.name, "setPreset by name ignores case");
} else {
  console.log("in Manual: skipping preset switching (it would replace the live settings)");
}

await command("setEnabled", original.enabled);
await command("setMuted", original.muted);
await command("setStrength", original.strength);
await command("setEngine", original.engine);
assert.deepEqual(state, original);
console.log("commands OK; meter messages:", meters.length);

const watch = Number(process.argv[2] ?? 0);
if (watch) {
  meters = [];
  await sleep(watch * 1000);
  const rms = meters.map((m) => m.rms), peak = meters.map((m) => m.peak);
  console.log(`watched ${watch}s: rms ${Math.min(...rms)}…${Math.max(...rms)} dBFS, max peak ${Math.max(...peak)} dBFS`);
}
console.log("stats:", JSON.stringify(stats));
ws.close();
