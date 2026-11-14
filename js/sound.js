// All game sounds are synthesised with Web Audio, so there are no audio files to load.
// Browsers only allow sound after a tap, so unlock() is called from the first button press.

let ctx = null;
let out = null;
let muted = false;

function ready() {
  if (muted) return false;
  if (!ctx) {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return false;
    ctx = new AC();
    const comp = ctx.createDynamicsCompressor();
    comp.connect(ctx.destination);
    out = comp;
  }
  if (ctx.state === 'suspended') ctx.resume();
  return true;
}

// One note: frequency can glide from f0 to f1 over its length.
function tone({ type = 'sine', f0, f1 = f0, at = 0, len = 0.2, vol = 0.3 }) {
  const t = ctx.currentTime + at;
  const osc = ctx.createOscillator();
  const gain = ctx.createGain();
  osc.type = type;
  osc.frequency.setValueAtTime(f0, t);
  if (f1 !== f0) osc.frequency.exponentialRampToValueAtTime(f1, t + len);
  gain.gain.setValueAtTime(0.0001, t);
  gain.gain.exponentialRampToValueAtTime(vol, t + 0.015);
  gain.gain.setValueAtTime(vol, t + Math.max(0.02, len - 0.04));
  gain.gain.exponentialRampToValueAtTime(0.0001, t + len);
  osc.connect(gain).connect(out);
  osc.start(t);
  osc.stop(t + len + 0.02);
}

export const sound = {
  unlock() { ready(); },
  get muted() { return muted; },
  setMuted(v) { muted = !!v; },

  // The seeker's ping alarm: a loud two-tone siren, about 2.4 seconds.
  siren() {
    if (!ready()) return;
    for (let i = 0; i < 6; i++) {
      tone({ type: 'sawtooth', f0: 760, f1: 1480, at: i * 0.4, len: 0.2, vol: 0.55 });
      tone({ type: 'square', f0: 1480, f1: 760, at: i * 0.4 + 0.2, len: 0.2, vol: 0.4 });
    }
  },
  // The hider's ping cue: short and quiet, so it doesn't give them away.
  blip() {
    if (!ready()) return;
    tone({ f0: 880, len: 0.09, vol: 0.12 });
    tone({ f0: 660, at: 0.13, len: 0.12, vol: 0.12 });
  },
  tick() {
    if (!ready()) return;
    tone({ type: 'square', f0: 1000, len: 0.06, vol: 0.2 });
  },
  // Head start is over.
  horn() {
    if (!ready()) return;
    tone({ type: 'sawtooth', f0: 220, f1: 233, len: 0.9, vol: 0.5 });
    tone({ type: 'sawtooth', f0: 330, f1: 349, len: 0.9, vol: 0.35 });
  },
  start() {
    if (!ready()) return;
    [523, 659, 784].forEach((f, i) => tone({ type: 'triangle', f0: f, at: i * 0.12, len: 0.16, vol: 0.3 }));
  },
  caught() {
    if (!ready()) return;
    tone({ type: 'triangle', f0: 700, f1: 240, len: 0.45, vol: 0.35 });
  },
  end() {
    if (!ready()) return;
    [392, 523, 659, 784, 1047].forEach((f, i) => tone({ type: 'triangle', f0: f, at: i * 0.14, len: 0.22, vol: 0.3 }));
  },
  warn() {
    if (!ready()) return;
    tone({ type: 'square', f0: 420, len: 0.12, vol: 0.18 });
    tone({ type: 'square', f0: 420, at: 0.2, len: 0.12, vol: 0.18 });
  },
};

export function vibrate(pattern) {
  try { navigator.vibrate?.(pattern); } catch { /* not supported */ }
}
