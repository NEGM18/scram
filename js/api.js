import { SUPABASE_URL, SUPABASE_KEY } from './config.js';

// Calls one of the hs_* game functions. Game-rule failures come back with a
// short code (ROOM_NOT_FOUND, WRONG_CODE, ...) in error.code.
export async function rpc(fn, args = {}) {
  let res;
  try {
    res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
    });
  } catch {
    const e = new Error('Network error');
    e.code = 'NETWORK';
    throw e;
  }
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  if (!res.ok) {
    const msg = data?.message || res.statusText || 'Request failed';
    const e = new Error(msg);
    e.code = /^[A-Z_]+$/.test(msg) ? msg : 'SERVER';
    throw e;
  }
  return data;
}

const MESSAGES = {
  NETWORK: 'No connection. Check your signal and try again.',
  SERVER: 'The game server had a problem. Try again in a moment.',
  NAME_REQUIRED: 'Enter a name so your friends know who you are.',
  ROOM_NOT_FOUND: 'No room has that code. Check it with whoever made the room.',
  ROOM_FULL: 'That room is full (24 players).',
  NOT_IN_ROOM: 'You are no longer in this room.',
  HOST_ONLY: 'Only the host can do that.',
  NOT_IN_LOBBY: 'That can only be changed in the lobby.',
  NO_ZONE: 'Tap the map to place the zone first.',
  NEED_PLAYERS: 'You need at least 2 players to start.',
  NEED_HIDER: 'Someone has to hide. Switch at least one player to hider.',
  NOT_SEEKING: 'Tagging opens when the head start ends.',
  SEEKERS_ONLY: 'Only seekers can tag.',
  WRONG_CODE: 'No hider has that code. Ask them to show it again.',
  NOT_HIDING: 'You are not hiding right now.',
  NO_JAMMERS: 'You have no jammers left.',
};

export const friendly = (e) => MESSAGES[e?.code] || MESSAGES.SERVER;
