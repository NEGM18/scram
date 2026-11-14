import { rpc, friendly } from './api.js';
import { sound, vibrate } from './sound.js';

/* global L */

// ---------------------------------------------------------------- basics

const $ = (id) => document.getElementById(id);
const qs = new URLSearchParams(location.search);

// ?p=2 keeps a separate identity per tab (for testing several players on one device).
// ?fake lets you long-press the map to place yourself instead of using real GPS.
const NS = 'laylow' + (qs.get('p') ? ':' + qs.get('p') : '');
const FAKE = qs.has('fake');

const store = {
  get(k) { try { return localStorage.getItem(`${NS}.${k}`); } catch { return null; } },
  set(k, v) {
    try { v == null ? localStorage.removeItem(`${NS}.${k}`) : localStorage.setItem(`${NS}.${k}`, v); } catch { /* private mode */ }
  },
};

let secret = store.get('secret');
if (!secret) { secret = crypto.randomUUID(); store.set('secret', secret); }

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const setText = (el, t) => { if (el.textContent !== t) el.textContent = t; };
const setHTML = (el, h) => { if (el._h !== h) { el._h = h; el.innerHTML = h; } };

const mmss = (ms) => {
  const s = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
};
const meters = (m) => (m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${Math.round(m)} m`);
const dur = (s) => (s < 60 ? `${s} s` : `${+(s / 60).toFixed(1)} min`);

function dist(a, b) {
  const R = 6371000, rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad, dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

// ---------------------------------------------------------------- state

const fresh = () => ({
  code: null, pid: null, st: null, offset: 0, lastEvent: 0,
  view: null, phase: null, failures: 0,
  editAt: 0, pending: null, saveT: null,
  fitted: false, centered: false, autoZoned: false, pinSig: null, lastTick: null,
});
let S = fresh();
const G = { pos: null, err: null, watch: null };   // GPS outlives a room

const now = () => Date.now() + S.offset;
const isHunter = (st) => st.me.role === 'seeker' || st.me.status === 'caught';

function phaseOf(st, t) {
  if (st.room.status !== 'playing') return st.room.status;   // 'lobby' | 'ended'
  return t < st.room.seek_at ? 'hide' : 'seek';
}
function viewOf(st) {
  if (st.room.status === 'lobby') return 'lobby';
  if (st.room.status === 'ended') return 'ended';
  return isHunter(st) ? 'hunter' : 'hider';
}

// ---------------------------------------------------------------- toasts, flash, confirm

function toast(msg, kind = '') {
  const box = $('room').hidden ? null : $('toasts');
  if (!box) { homeError(msg); return; }
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = msg;
  box.append(el);
  while (box.children.length > 3) box.firstChild.remove();
  setTimeout(() => el.remove(), 4200);
}

let flashT = null;
function flash(big, small, quiet = false) {
  const f = $('flash');
  $('flash-big').textContent = big;
  $('flash-small').textContent = small;
  f.className = quiet ? 'flash quiet' : 'flash';
  f.hidden = false;
  f.style.animation = 'none';
  void f.offsetWidth;            // restart the animation
  f.style.animation = '';
  clearTimeout(flashT);
  flashT = setTimeout(() => { f.hidden = true; }, quiet ? 1800 : 2600);
}
$('flash').addEventListener('click', () => { $('flash').hidden = true; });

// First tap arms the button, second tap within 3 seconds runs it.
function confirmTap(btn, label, fn) {
  if (btn.dataset.armed) {
    clearTimeout(btn._t);
    delete btn.dataset.armed;
    btn.textContent = btn._label;
    fn();
    return;
  }
  btn.dataset.armed = '1';
  btn._label = btn.textContent;
  btn.textContent = label;
  btn._t = setTimeout(() => { delete btn.dataset.armed; btn.textContent = btn._label; }, 3000);
}

// ---------------------------------------------------------------- home

const nameEl = $('name'), codeEl = $('join-code');
nameEl.value = store.get('name') || '';
if (qs.get('room')) codeEl.value = qs.get('room').toUpperCase().slice(0, 4);

function homeError(msg) {
  const el = $('home-error');
  el.textContent = msg || '';
  el.hidden = !msg;
}

async function go(kind) {
  const name = nameEl.value.trim();
  const code = codeEl.value.trim().toUpperCase();
  homeError('');
  if (!name) { homeError('Enter a name so your friends know who you are.'); nameEl.focus(); return; }
  if (kind === 'join' && code.length !== 4) { homeError('Room codes are 4 letters.'); codeEl.focus(); return; }
  sound.unlock();
  store.set('name', name);
  $('btn-create').disabled = $('btn-join').disabled = true;
  try {
    const r = kind === 'create'
      ? await rpc('hs_create_room', { p_name: name, p_secret: secret })
      : await rpc('hs_join_room', { p_code: code, p_name: name, p_secret: secret });
    enterRoom(r.code, r.player_id);
  } catch (e) {
    homeError(friendly(e));
  } finally {
    $('btn-create').disabled = $('btn-join').disabled = false;
  }
}

$('btn-create').addEventListener('click', () => go('create'));
$('home-form').addEventListener('submit', (e) => { e.preventDefault(); go(codeEl.value.trim() ? 'join' : 'create'); });
codeEl.addEventListener('input', () => { codeEl.value = codeEl.value.toUpperCase().replace(/[^A-Z]/g, ''); });

function setUrlRoom(code) {
  const u = new URL(location.href);
  code ? u.searchParams.set('room', code) : u.searchParams.delete('room');
  history.replaceState(null, '', u);
}

// ---------------------------------------------------------------- entering and leaving a room

function enterRoom(code, pid) {
  S = Object.assign(fresh(), { code, pid });
  store.set('session', JSON.stringify({ code, pid }));
  $('home').hidden = true;
  $('room').hidden = false;
  for (const v of ['lobby', 'hider', 'hunter', 'ended']) $(`view-${v}`).hidden = true;
  $('sheet').classList.remove('collapsed');
  setUrlRoom(code);
  initMap();
  resetMap();
  requestAnimationFrame(() => map.invalidateSize());
  startGps();
  wakeLock();
  poll();
}

function leaveLocal(msg) {
  clearTimeout(pollT);
  clearTimeout(S.saveT);
  S = fresh();
  store.set('session', null);
  $('room').hidden = true;
  $('home').hidden = false;
  $('blindfold').hidden = true;
  $('flash').hidden = true;
  delete document.body.dataset.mode;
  setUrlRoom(null);
  wake?.release?.().catch(() => {});
  wake = null;
  homeError(msg || '');
}

let wake = null;
async function wakeLock() {
  try { if (navigator.wakeLock && !$('room').hidden) wake = await navigator.wakeLock.request('screen'); } catch { /* denied or unsupported */ }
}
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && S.code) { wakeLock(); poll(); }
});

// ---------------------------------------------------------------- talking to the server

let pollT = null, inFlight = false, again = false;

async function poll() {
  clearTimeout(pollT);
  if (!S.code) return;
  if (inFlight) { again = true; return; }
  inFlight = true;
  const code = S.code;
  try {
    const st = await rpc('hs_state', {
      p_code: code, p_pid: S.pid, p_secret: secret,
      p_lat: G.pos?.lat ?? null, p_lng: G.pos?.lng ?? null, p_acc: G.pos?.acc ?? null,
      p_after_event: S.lastEvent,
    });
    if (S.code === code) { S.failures = 0; apply(st); }
  } catch (e) {
    if (S.code === code) {
      if (e.code === 'NOT_IN_ROOM') { inFlight = false; leaveLocal('You are no longer in that room.'); return; }
      S.failures++;
      renderBanner();
    }
  }
  inFlight = false;
  if (!S.code) return;
  if (again) { again = false; poll(); return; }
  pollT = setTimeout(poll, S.st?.room.status === 'playing' ? 2000 : 2500);
}

// Runs a game action for this player, then refreshes straight away.
async function act(fn, args = {}) {
  try {
    const r = await rpc(fn, { p_code: S.code, p_pid: S.pid, p_secret: secret, ...args });
    poll();
    return r ?? true;
  } catch (e) {
    toast(friendly(e), 'bad');
    return null;
  }
}

function apply(st) {
  const prev = S.st;
  // don't let a slightly stale answer undo what the host is dragging right now
  if (prev && st.room.status === 'lobby' && Date.now() - S.editAt < 2500) {
    st.room.settings = prev.room.settings;
    st.room.zone = prev.room.zone;
  }
  S.offset = st.now - Date.now();
  S.st = st;

  for (const e of st.events) {
    if (e.id > S.lastEvent) {
      S.lastEvent = e.id;
      if (prev) onEvent(e, st);
    }
  }
  if (prev && !prev.me.outside && st.me.outside) { sound.warn(); vibrate([300, 100, 300]); }

  render();
  tick();

  if (prev && st.room.status === 'playing' && prev.room.round === st.room.round && st.room.ping_seq > prev.room.ping_seq) {
    onPing(st);
  }
  maybeAutoZone();
}

function onEvent(e, st) {
  const d = e.data || {};
  if (e.kind === 'caught') {
    sound.caught();
    if (d.id === st.me.id) {
      vibrate([500]);
      toast('You are caught. You hunt with the seeker now.');
    } else {
      toast(d.by ? `${d.name} was caught by ${d.by}.` : `${d.name} gave up.`);
    }
  } else if (e.kind === 'join') {
    toast(`${d.name} joined.`);
  } else if (e.kind === 'left') {
    toast(`${d.name} left.`);
  }
}

function onPing(st) {
  const latest = st.pings.filter((g) => g.seq === st.room.ping_seq);
  const by = playersById(st);
  if (S.view === 'hunter') {
    const shown = latest.filter((g) => g.role === 'hider' && g.lat != null && by[g.id]?.status === 'active').length;
    const jammed = latest.filter((g) => g.jammed).length;
    sound.siren();
    vibrate([400, 120, 400, 120, 600]);
    flash('Ping', `${shown} hider${shown === 1 ? '' : 's'} on your map` + (jammed ? `, ${jammed} jammed` : ''));
    fitPings(latest.filter((g) => g.role === 'hider' && g.lat != null));
  } else if (S.view === 'hider') {
    const mine = latest.find((g) => g.id === st.me.id);
    sound.blip();
    vibrate([200, 100, 200]);
    flash('Ping', mine?.jammed ? 'Jammed. The seeker got nothing on you.' : 'The seeker just saw where you are.', true);
  }
}

function onPhase(prev, next) {
  const st = S.st;
  S.pinSig = null;
  if (next === 'hide') {
    sound.start();
    toast(isHunter(st) ? 'Game on. Eyes shut while they hide.' : 'Game on. Go hide.');
    fitZone();
  } else if (next === 'seek' && prev === 'hide') {
    if (isHunter(st)) { sound.horn(); vibrate([600]); toast('Go. Find them.'); }
    else { sound.blip(); vibrate([200, 100, 200]); toast('The seeker is loose.'); }
  } else if (next === 'ended') {
    sound.end();
    $('sheet').classList.remove('collapsed');
  } else if (next === 'lobby') {
    toast('Back in the lobby.');
  }
}

// ---------------------------------------------------------------- GPS

function setPos(lat, lng, acc) {
  G.pos = { lat, lng, acc };
  G.err = null;
  updateMe();
  if (map && !S.fitted && !S.centered && S.code) { S.centered = true; map.setView([lat, lng], 16); }
  maybeAutoZone();
  renderBanner();
}

function startGps() {
  if (FAKE) {
    const m = (qs.get('fake') || '').split(',').map(Number);
    if (m.length === 2 && m.every(Number.isFinite) && !G.pos) setPos(m[0], m[1], 5);
    return;
  }
  if (G.watch != null) return;
  if (!navigator.geolocation) { G.err = 'unsupported'; return; }
  G.watch = navigator.geolocation.watchPosition(
    (p) => setPos(p.coords.latitude, p.coords.longitude, p.coords.accuracy),
    (err) => { G.err = err.code === 1 ? 'denied' : 'unavailable'; renderBanner(); },
    { enableHighAccuracy: true, maximumAge: 5000, timeout: 20000 },
  );
}

// The first time the host gets a fix, drop the zone on them so there's something to adjust.
function maybeAutoZone() {
  const st = S.st;
  if (!st || S.autoZoned || !G.pos) return;
  if (st.room.status !== 'lobby' || !st.me.host || st.room.settings.zone_lat != null) return;
  S.autoZoned = true;
  editSettings({ zone_lat: G.pos.lat, zone_lng: G.pos.lng });
}

// ---------------------------------------------------------------- map

let map = null, tiles = null;
const layer = {};
// OpenStreetMap's own tiles need no API key. Night mode recolours them with a CSS filter.
const TILE_URL = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const WORLD = [[-89, -360], [-89, 360], [89, 360], [89, -360]];
const courseColor = () => getComputedStyle(document.body).getPropertyValue('--course').trim() || '#c2188b';

function initMap() {
  if (map) return;
  map = L.map('map', { zoomControl: false, zoomSnap: 0.25 }).setView([20, 0], 2);
  tiles = L.tileLayer(TILE_URL, {
    maxZoom: 20, maxNativeZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
  }).addTo(map);
  map.attributionControl.setPrefix(false);

  layer.mask = L.polygon([], { stroke: false, fillColor: '#12141f', fillOpacity: 0.3, interactive: false });
  layer.zone0 = L.circle([0, 0], { radius: 1, weight: 1.5, dashArray: '4 7', fill: false, interactive: false });
  layer.zone = L.circle([0, 0], { radius: 1, weight: 4, fill: false, interactive: false });
  layer.acc = L.circle([0, 0], { radius: 1, weight: 0, fillOpacity: 0.12, interactive: false });
  layer.pins = L.layerGroup().addTo(map);
  layer.live = L.layerGroup().addTo(map);
  layer.me = L.marker([0, 0], { interactive: false, zIndexOffset: 1000 });

  map.on('click', (e) => {
    const st = S.st;
    if (st && st.room.status === 'lobby' && st.me.host) editSettings({ zone_lat: e.latlng.lat, zone_lng: e.latlng.lng });
  });
  map.on('contextmenu', (e) => { if (FAKE) { setPos(e.latlng.lat, e.latlng.lng, 5); poll(); } });

  new ResizeObserver(() => {
    $('room').style.setProperty('--sheet-h', `${$('sheet').offsetHeight}px`);
  }).observe($('sheet'));
}

function resetMap() {
  for (const k of ['mask', 'zone0', 'zone', 'acc', 'me']) layer[k].remove();
  layer.pins.clearLayers();
  layer.live.clearLayers();
  updateMe();
}

function pinIcon(kind, color, label) {
  return L.divIcon({
    className: 'pin-wrap', iconSize: [0, 0],
    html: `<div class="pin ${kind}" style="--c:${color}"><i class="g"></i>${label ? `<b>${esc(label)}</b>` : ''}</div>`,
  });
}

function updateMe() {
  if (!map || !G.pos) return;
  const ll = [G.pos.lat, G.pos.lng];
  const color = S.st?.me.color || '#2b7fd9';
  if (layer.me._color !== color) { layer.me._color = color; layer.me.setIcon(pinIcon('dot me', color, '')); }
  layer.me.setLatLng(ll).addTo(map);
  layer.acc.setLatLng(ll).setRadius(Math.min(G.pos.acc || 1, 500)).setStyle({ fillColor: color }).addTo(map);
}

function ring(z) {
  const pts = [], dLat = z.r / 111320, dLng = z.r / (111320 * Math.cos(z.lat * Math.PI / 180));
  for (let i = 0; i < 72; i++) {
    const a = (i / 72) * 2 * Math.PI;
    pts.push([z.lat + dLat * Math.cos(a), z.lng + dLng * Math.sin(a)]);
  }
  return pts;
}

function fitPad() {
  const wide = window.innerWidth >= 760;
  return wide
    ? { paddingTopLeft: [440, 30], paddingBottomRight: [80, 30] }
    : { paddingTopLeft: [20, $('strip').offsetHeight + 30], paddingBottomRight: [20, $('sheet').offsetHeight + 20] };
}
function fitZone() {
  const z = S.st?.room.zone;
  if (map && z) map.fitBounds(L.latLng(z.lat, z.lng).toBounds(z.r * 2), fitPad());
}
function fitPings(pings) {
  if (!map || !pings.length) return;
  const pts = pings.map((g) => [g.lat, g.lng]);
  if (G.pos) pts.push([G.pos.lat, G.pos.lng]);
  map.fitBounds(L.latLngBounds(pts).pad(0.25), { ...fitPad(), maxZoom: 18 });
}

const playersById = (st) => Object.fromEntries(st.players.map((p) => [p.id, p]));

function renderMap(st) {
  const z = st.room.zone, s = st.room.settings, color = courseColor();
  if (z) {
    layer.zone.setLatLng([z.lat, z.lng]).setRadius(z.r).setStyle({ color }).addTo(map);
    layer.mask.setLatLngs([WORLD, ring(z)]).addTo(map);
    if (st.room.status !== 'lobby' && s.zone_lat != null) {
      layer.zone0.setLatLng([s.zone_lat, s.zone_lng]).setRadius(s.zone_radius_m).setStyle({ color }).addTo(map);
    } else layer.zone0.remove();
    if (!S.fitted) { S.fitted = true; fitZone(); }
  } else {
    layer.zone.remove(); layer.zone0.remove(); layer.mask.remove();
  }
  updateMe();
  renderPins(st);
  renderLive(st);
}

// Ping snapshots. Hunters see hiders' flags (the last three pings, linked as a trail);
// hiders see where the seeker stood, and the spot the seeker saw them at.
function renderPins(st) {
  const view = S.view, latest = st.room.ping_seq;
  const sig = `${view}|${st.room.round}|${latest}|${st.pings.length}|${st.players.map((p) => p.status).join('')}`;
  if (sig === S.pinSig) return;
  S.pinSig = sig;
  layer.pins.clearLayers();
  if (view !== 'hunter' && view !== 'hider') return;

  const by = playersById(st), trails = {};
  for (const g of st.pings) {
    const p = by[g.id];
    if (!p || g.lat == null) continue;
    const mine = g.id === st.me.id, isNew = g.seq === latest, ll = [g.lat, g.lng];

    if (view === 'hider' && mine) {
      if (isNew) L.marker(ll, { icon: pinIcon('seen', p.color, 'Seen here'), interactive: false }).addTo(layer.pins);
      continue;
    }
    if (view === 'hunter' && (g.role !== 'hider' || p.status !== 'active')) continue;
    if (view === 'hider' && g.role !== 'seeker') continue;

    (trails[g.id] ||= []).push(ll);
    if (isNew && g.fuzz > 0) {
      L.circle(ll, { radius: g.fuzz, color: p.color, weight: 2, dashArray: '3 6', fillColor: p.color, fillOpacity: 0.22, interactive: false }).addTo(layer.pins);
    }
    const kind = (g.role === 'seeker' ? 'tri' : 'flag') + (isNew ? '' : ' old');
    L.marker(ll, { icon: pinIcon(kind, p.color, isNew ? p.name : ''), interactive: false, zIndexOffset: isNew ? 500 : 0 }).addTo(layer.pins);
  }
  for (const [id, pts] of Object.entries(trails)) {
    if (pts.length > 1) L.polyline(pts, { color: by[id].color, weight: 2.5, dashArray: '2 7', opacity: 0.8, interactive: false }).addTo(layer.pins);
  }
}

// Live positions: fellow hunters, hiders exposed outside the zone, and everyone once it's over.
function renderLive(st) {
  layer.live.clearLayers();
  const by = playersById(st);
  for (const q of st.positions) {
    const p = by[q.id];
    if (!p) continue;
    const icon = q.exposed ? pinIcon('flag live', p.color, `${p.name} · live`) : pinIcon('dot', p.color, p.name);
    L.marker([q.lat, q.lng], { icon, interactive: false, zIndexOffset: q.exposed ? 800 : 200 }).addTo(layer.live);
  }
}

// ---------------------------------------------------------------- lobby settings

const RULES = [
  ['hide_seconds', 'Head start', [[30, '30 s'], [60, '1 min'], [120, '2 min'], [180, '3 min'], [300, '5 min'], [600, '10 min']]],
  ['game_seconds', 'Game length', [[300, '5 min'], [600, '10 min'], [900, '15 min'], [1200, '20 min'], [1800, '30 min'], [2700, '45 min'], [3600, '60 min']]],
  ['ping', 'Ping every', [['30-60', '30–60 s'], ['60-120', '1–2 min'], ['120-240', '2–4 min'], ['180-360', '3–6 min'], ['300-480', '5–8 min']]],
  ['ping_fuzz_m', 'Ping shows', [[0, 'Exact spot'], [50, 'Within 50 m'], [100, 'Within 100 m'], [200, 'Within 200 m']]],
  ['final_pct', 'Zone shrinks to', [[10, '10% of its size'], [15, '15% of its size'], [25, '25% of its size'], [40, '40% of its size']]],
  ['jammers', 'Jammers per hider', [[0, 'None'], [1, '1'], [2, '2']]],
  ['reveal_seekers', 'Pings show hiders the seeker', [['true', 'Yes'], ['false', 'No']]],
];
const rulesEl = $('rules'), radiusEl = $('radius');
rulesEl.innerHTML = RULES.map(([key, label, opts]) => `
  <label class="field"><span>${label}</span>
    <select data-key="${key}">${opts.map(([v, t]) => `<option value="${v}">${t}</option>`).join('')}</select>
  </label>`).join('');

function editSettings(patch) {
  const r = S.st.room;
  S.editAt = Date.now();
  Object.assign(r.settings, patch);
  if (r.settings.zone_lat != null) r.zone = { lat: r.settings.zone_lat, lng: r.settings.zone_lng, r: r.settings.zone_radius_m };
  S.pending = Object.assign(S.pending || {}, patch);
  clearTimeout(S.saveT);
  S.saveT = setTimeout(flushSettings, 350);
  render();
}

async function flushSettings() {
  clearTimeout(S.saveT);
  const p = S.pending;
  S.pending = null;
  if (!p || !S.code) return;
  S.editAt = Date.now();
  try {
    await rpc('hs_update_settings', { p_code: S.code, p_pid: S.pid, p_secret: secret, p_settings: p });
  } catch (e) {
    toast(friendly(e), 'bad');
  }
}

rulesEl.addEventListener('change', (e) => {
  const sel = e.target.closest('select');
  if (!sel || !S.st) return;
  const key = sel.dataset.key, v = sel.value;
  if (key === 'ping') { const [a, b] = v.split('-').map(Number); editSettings({ ping_min_s: a, ping_max_s: b }); }
  else if (key === 'reveal_seekers') editSettings({ reveal_seekers: v === 'true' });
  else editSettings({ [key]: Number(v) });
});
radiusEl.addEventListener('input', () => { if (S.st) editSettings({ zone_radius_m: Number(radiusEl.value) }); });
radiusEl.addEventListener('change', fitZone);
$('btn-zone-me').addEventListener('click', () => {
  if (!G.pos) { toast('No GPS fix yet. Give it a few seconds outdoors.'); return; }
  editSettings({ zone_lat: G.pos.lat, zone_lng: G.pos.lng });
  fitZone();
});

function syncControls(s) {
  const vals = { ...s, ping: `${s.ping_min_s}-${s.ping_max_s}`, reveal_seekers: String(s.reveal_seekers) };
  for (const sel of rulesEl.querySelectorAll('select')) {
    const v = String(vals[sel.dataset.key]);
    if (![...sel.options].some((o) => o.value === v)) sel.add(new Option(v.replace('-', '–') + (sel.dataset.key === 'ping' ? ' s' : ''), v));
    if (sel.value !== v && document.activeElement !== sel) sel.value = v;
  }
  if (document.activeElement !== radiusEl) radiusEl.value = s.zone_radius_m;
  setText($('radius-out'), meters(s.zone_radius_m));
}

function summary(s) {
  return [
    `Head start: ${dur(s.hide_seconds)}`,
    `Game length: ${dur(s.game_seconds)}`,
    `A ping every ${dur(s.ping_min_s)} to ${dur(s.ping_max_s)}, showing ${s.ping_fuzz_m ? `hiders within ${s.ping_fuzz_m} m` : 'the exact spot'}`,
    `Zone: ${meters(s.zone_radius_m)} radius, shrinking to ${s.final_pct}%`,
    s.jammers ? `Jammers: ${s.jammers} per hider` : 'No jammers',
    s.reveal_seekers ? 'Each ping also shows hiders where the seeker is' : 'Hiders never see the seeker',
  ].map((t) => `<li>${esc(t)}</li>`).join('');
}

// ---------------------------------------------------------------- rendering

function render() {
  const st = S.st;
  if (!st) return;
  const view = viewOf(st);
  if (view !== S.view) {
    S.view = view;
    for (const v of ['lobby', 'hider', 'hunter', 'ended']) $(`view-${v}`).hidden = v !== view;
    S.pinSig = null;
  }
  document.body.dataset.mode = view === 'hunter' ? 'seek' : view === 'hider' ? 'hide' : 'idle';
  for (const b of document.querySelectorAll('.host-only')) b.hidden = !st.me.host;

  if (view === 'lobby') renderLobby(st);
  else if (view === 'hider') renderHider(st);
  else if (view === 'hunter') renderHunter(st);
  else renderEnded(st);

  renderMap(st);
  renderBanner();
}

function renderLobby(st) {
  const host = st.me.host, s = st.room.settings;
  setText($('room-code'), st.room.code);
  setText($('player-count'), `(${st.players.length})`);
  $('host-controls').hidden = !host;
  $('guest-info').hidden = host;

  setHTML($('players'), st.players.map((p) => `
    <li class="player ${p.online ? '' : 'off'}">
      <i class="dot" style="--c:${p.color}"></i>
      <span class="pname">${esc(p.name)}${p.id === st.me.id ? ' <em>you</em>' : ''}${p.host ? ' <em>host</em>' : ''}</span>
      <span class="gps ${p.gps ? 'ok' : ''}">${p.gps ? 'GPS ready' : p.online ? 'No GPS yet' : 'Away'}</span>
      ${host
        ? `<button class="role ${p.role}" type="button" data-act="role" data-id="${p.id}" data-role="${p.role === 'seeker' ? 'hider' : 'seeker'}" aria-label="${esc(p.name)} is a ${p.role}. Tap to switch.">${p.role}</button>`
        : `<span class="role ${p.role}">${p.role}</span>`}
      ${host && p.id !== st.me.id ? `<button class="kick" type="button" data-act="kick" data-id="${p.id}" aria-label="Remove ${esc(p.name)}">&times;</button>` : '<span></span>'}
    </li>`).join(''));

  if (host) {
    if (Date.now() - S.editAt > 2500 || !S.editAt) syncControls(s);
    else setText($('radius-out'), meters(s.zone_radius_m));
    const seekers = st.players.filter((p) => p.role === 'seeker').length;
    const hiders = st.players.length - seekers;
    let hint = `${hiders} hiding, ${seekers} seeking.`, ok = true;
    if (s.zone_lat == null) { hint = 'Place the zone first: tap the map, or wait for your GPS fix.'; ok = false; }
    else if (st.players.length < 2) { hint = 'Share the room code. You need at least 2 players.'; ok = false; }
    else if (!hiders) { hint = 'Everyone is a seeker. Switch at least one player to hider.'; ok = false; }
    else if (!seekers) hint = 'No seeker picked, so one player gets chosen at random.';
    $('btn-start').disabled = !ok;
    setText($('start-hint'), hint);
  } else {
    setHTML($('rules-summary'), summary(s));
    const hostName = st.players.find((p) => p.host)?.name || 'the host';
    setText($('guest-wait'), s.zone_lat == null
      ? `${hostName} is still placing the zone.`
      : `Waiting for ${hostName} to start. You are a ${st.me.role}.`);
  }
}

function renderHider(st) {
  setText($('tag-code'), st.me.tag_code || '----');
  const jam = $('btn-jam'), s = st.room.settings;
  jam.hidden = !s.jammers;
  if (st.me.jam_armed) { jam.disabled = true; setText(jam, 'Jammer armed for the next ping'); }
  else if (st.me.jammers_left > 0) { jam.disabled = false; setText(jam, `Jam the next ping (${st.me.jammers_left} left)`); }
  else { jam.disabled = true; setText(jam, 'No jammers left'); }
}

function renderHunter(st) {
  setHTML($('hider-chips'), st.players.filter((p) => p.role === 'hider').map((p) =>
    `<li class="${p.status}"><i class="dot" style="--c:${p.color}"></i>${esc(p.name)}</li>`).join(''));
}

function renderEnded(st) {
  const r = st.room, hiders = st.players.filter((p) => p.role === 'hider');
  const survivors = hiders.filter((p) => p.status === 'active');
  const title = { seekers: 'Seekers win', hiders: 'Hiders win' }[r.winner] || 'Game stopped';
  let sub = 'The host ended this round early.';
  if (r.winner === 'seekers') sub = `Everyone was found with ${mmss(r.ends_at - r.ended_at)} left on the clock.`;
  if (r.winner === 'hiders') sub = `${survivors.length} of ${hiders.length} stayed hidden until time ran out.`;
  setText($('end-title'), title);
  setText($('end-sub'), sub);

  const ranked = [...hiders].sort((a, b) => (b.caught_at ?? Infinity) - (a.caught_at ?? Infinity));
  setHTML($('results'), ranked.map((p) => {
    const at = p.caught_at ? mmss(Math.max(0, p.caught_at - r.seek_at)) : null;
    const how = !p.caught_at ? '<span class="r win">Never found</span>'
      : `<span class="r">${p.caught_by ? `Caught by ${esc(p.caught_by)}` : 'Gave up'} at ${at}</span>`;
    return `<li><i class="dot" style="--c:${p.color}"></i><span>${esc(p.name)}</span>${how}</li>`;
  }).join(''));

  $('btn-again').hidden = !st.me.host;
  $('end-wait').hidden = st.me.host;
}

function renderBanner() {
  const el = $('banner'), st = S.st;
  let msg = '', bad = false;
  if (S.failures >= 2) msg = 'Connection lost. Trying again…';
  else if (st && S.view === 'hider' && st.me.exposed) { msg = 'You are outside the zone. The seeker sees you live.'; bad = true; }
  else if (G.err === 'denied') msg = 'Location is blocked. Allow location for this site in your browser, then reload.';
  else if (G.err === 'unsupported') msg = 'This browser cannot share location, so the game will not work here.';
  else if (!G.pos && FAKE) msg = 'Test mode: long-press (or right-click) the map to place yourself.';
  else if (!G.pos) msg = 'Looking for your location…';
  el.hidden = !msg;
  el.className = bad ? 'banner bad' : 'banner';
  setText(el, msg);
}

// Everything that changes with the clock rather than with a server answer.
function tick() {
  const st = S.st;
  if (!st) return;
  const r = st.room, t = now(), phase = phaseOf(st, t);
  if (phase !== S.phase) {
    const prev = S.phase;
    S.phase = phase;
    if (prev) onPhase(prev, phase);
  }

  // status strip
  const hiders = st.players.filter((p) => p.role === 'hider');
  const left = hiders.filter((p) => p.status === 'active').length;
  const zone = r.zone ? meters(r.zone.r) : '—';
  let cells;
  if (phase === 'lobby') {
    cells = [['Room', r.code], ['Players', String(st.players.length)], ['Zone', zone],
      ['Your GPS', G.pos ? `±${Math.round(G.pos.acc)} m` : G.err ? 'Off' : '…']];
  } else if (phase === 'ended') {
    cells = [['Room', r.code], ['Winner', { seekers: 'Seekers', hiders: 'Hiders' }[r.winner] || 'Nobody'],
      ['Caught', `${hiders.length - left}/${hiders.length}`], ['Zone', zone]];
  } else {
    const you = st.me.role === 'seeker' ? 'Seeker' : st.me.status === 'caught' ? 'Caught' : 'Hider';
    cells = [['You are', you],
      phase === 'hide' ? ['Head start', mmss(r.seek_at - t)] : ['Time left', mmss(r.ends_at - t)],
      ['Still hiding', `${left}/${hiders.length}`], ['Zone', zone]];
  }
  cells.forEach(([k, v], i) => { setText($(`c${i + 1}k`), k); setText($(`c${i + 1}v`), v); });

  // seeker's blindfold, with a countdown beep for the last five seconds
  const blind = phase === 'hide' && S.view === 'hunter';
  $('blindfold').hidden = !blind;
  if (blind) {
    const ms = r.seek_at - t, s = Math.ceil(ms / 1000);
    setText($('blind-time'), mmss(ms));
    if (s <= 5 && s > 0 && s !== S.lastTick) { S.lastTick = s; sound.tick(); }
  }

  if (S.view === 'hider') {
    const me = st.me, el = $('hider-status');
    let cls = 'ok', msg;
    if (me.exposed) { cls = 'bad'; msg = 'Exposed. The seeker sees you live until you are back inside the zone.'; }
    else if (me.outside) {
      cls = 'warn';
      msg = phase === 'seek'
        ? `Outside the zone. The seeker sees you live in ${Math.max(0, 20 - (me.outside_s || 0))} s.`
        : 'Outside the zone. Get inside before the head start ends.';
    } else if (!G.pos) { cls = 'warn'; msg = 'No GPS fix. Pings will show your last known spot.'; }
    else if (r.zone) msg = `Inside the zone. The edge is ${meters(Math.max(0, r.zone.r - dist(G.pos, r.zone)))} away.`;
    else msg = 'Inside the zone.';
    el.className = `status ${cls}`;
    setText(el, msg);

    const mine = st.pings.filter((g) => g.id === me.id && g.role === 'hider').at(-1);
    let line;
    if (!mine) line = phase === 'hide' ? 'Pings start after the head start, at random moments.' : 'No ping yet. One can land at any moment.';
    else if (mine.jammed) line = `Last ping ${mmss(t - mine.at)} ago: jammed. The seeker got nothing.`;
    else line = `Last ping ${mmss(t - mine.at)} ago. The seeker saw ${mine.fuzz ? 'roughly' : 'exactly'} where you were.`;
    setText($('hider-ping'), line);
  }

  if (S.view === 'hunter') {
    const s = r.settings;
    let msg;
    if (phase === 'hide') msg = 'Head start. Pings begin after it ends.';
    else if (!r.last_ping_at) msg = `No ping yet. The first one lands within ${dur(s.ping_max_s)} of the head start ending.`;
    else {
      const since = t - r.last_ping_at, wait = s.ping_min_s * 1000 - since;
      const jammed = st.pings.filter((g) => g.seq === r.ping_seq && g.jammed).length;
      msg = `Last ping ${mmss(since)} ago` + (jammed ? `, ${jammed} jammed. ` : '. ')
        + (wait > 0 ? `Next one in ${mmss(wait)} at the earliest.` : 'The next one can land at any moment.');
    }
    if (st.me.status === 'caught') msg = `You were caught, so you hunt now. ${msg}`;
    const el = $('hunter-status');
    el.className = 'status seek';
    setText(el, msg);
  }
}
setInterval(tick, 250);

// ---------------------------------------------------------------- buttons

$('grip').addEventListener('click', () => {
  const collapsed = $('sheet').classList.toggle('collapsed');
  $('grip').setAttribute('aria-expanded', String(!collapsed));
});

$('btn-invite').addEventListener('click', async () => {
  const u = new URL(location.href);
  u.search = `?room=${S.code}`;
  const text = `Join my Lay Low room: ${S.code}`;
  try {
    if (navigator.share) await navigator.share({ title: 'Lay Low', text, url: u.href });
    else { await navigator.clipboard.writeText(u.href); toast('Invite link copied.'); }
  } catch { /* share sheet dismissed */ }
});

$('btn-start').addEventListener('click', async () => {
  sound.unlock();
  $('btn-start').disabled = true;
  await flushSettings();
  await act('hs_start');
});

$('players').addEventListener('click', (e) => {
  const b = e.target.closest('[data-act]');
  if (!b) return;
  if (b.dataset.act === 'role') act('hs_set_role', { p_target: b.dataset.id, p_role: b.dataset.role });
  if (b.dataset.act === 'kick') confirmTap(b, '?', () => act('hs_kick', { p_target: b.dataset.id }));
});

$('btn-jam').addEventListener('click', async () => {
  if (await act('hs_jam')) toast('Jammer armed. The next ping will miss you.');
});
$('btn-caught').addEventListener('click', (e) => confirmTap(e.currentTarget, 'Tap again to confirm', () => act('hs_give_up')));

$('tag-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const input = $('tag-input'), err = $('tag-error');
  const code = input.value.trim();
  err.hidden = true;
  if (code.length !== 4) { err.textContent = 'Tag codes are 4 digits.'; err.hidden = false; return; }
  try {
    const r = await rpc('hs_tag', { p_code: S.code, p_pid: S.pid, p_secret: secret, p_tag: code });
    input.value = '';
    toast(`Tagged ${r?.name || 'them'}.`);
    poll();
  } catch (ex) {
    err.textContent = friendly(ex);
    err.hidden = false;
  }
});
$('tag-input').addEventListener('input', (e) => { e.target.value = e.target.value.replace(/\D/g, ''); $('tag-error').hidden = true; });

$('btn-again').addEventListener('click', () => act('hs_reset'));

$('sheet').addEventListener('click', (e) => {
  const b = e.target.closest('.foot [data-act]');
  if (!b) return;
  if (b.dataset.act === 'leave') {
    confirmTap(b, 'Tap again to leave', async () => {
      const { code, pid } = S;
      leaveLocal('');
      try { await rpc('hs_leave', { p_code: code, p_pid: pid, p_secret: secret }); } catch { /* already gone */ }
    });
  }
  if (b.dataset.act === 'end') confirmTap(b, 'Tap again to end it', () => act('hs_end_game'));
});

// map tools
$('tool-me').addEventListener('click', () => {
  if (!G.pos) { toast('No GPS fix yet.'); return; }
  map.setView([G.pos.lat, G.pos.lng], Math.max(map.getZoom(), 17));
});
$('tool-zone').addEventListener('click', () => { if (S.st?.room.zone) fitZone(); else toast('No zone has been placed yet.'); });

function setNight(on) {
  document.body.toggleAttribute('data-night', on);
  $('tool-night').setAttribute('aria-pressed', String(on));
  document.querySelector('meta[name="theme-color"]').content = on ? '#151827' : '#ffffff';
  store.set('night', on ? '1' : null);
  if (S.st) renderMap(S.st);
}
$('tool-night').addEventListener('click', () => setNight(!document.body.hasAttribute('data-night')));

function setMuted(m) {
  sound.setMuted(m);
  $('tool-sound').setAttribute('aria-pressed', String(!m));
  store.set('mute', m ? '1' : null);
}
$('tool-sound').addEventListener('click', () => { setMuted(!sound.muted); if (!sound.muted) { sound.unlock(); sound.blip(); } });

// Sound needs one tap after a reload before the browser lets it play.
document.addEventListener('pointerdown', () => sound.unlock(), { once: true });

// ---------------------------------------------------------------- start up

setNight(store.get('night') === '1');
setMuted(store.get('mute') === '1');

try {
  const saved = JSON.parse(store.get('session') || 'null');
  const wanted = qs.get('room')?.toUpperCase();
  if (saved?.code && saved?.pid && (!wanted || wanted === saved.code)) enterRoom(saved.code, saved.pid);
} catch { store.set('session', null); }
