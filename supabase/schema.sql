-- Lay Low: GPS hide and seek.
-- Every table lives in the private "hideseek" schema, which the browser cannot reach.
-- The site only calls the hs_* functions in "public", and each one checks the
-- caller's player id + secret before doing anything.
-- Run this whole file in the Supabase SQL editor to rebuild the database from scratch.

create schema if not exists hideseek;
revoke all on schema hideseek from public;

create table hideseek.rooms (
  code text primary key,
  host_id uuid,
  status text not null default 'lobby' check (status in ('lobby','playing','ended')),
  round integer not null default 0,
  -- settings (the host edits these in the lobby)
  zone_lat double precision,
  zone_lng double precision,
  zone_radius_m integer not null default 400,
  final_pct integer not null default 15,
  hide_seconds integer not null default 180,
  game_seconds integer not null default 1200,
  ping_min_s integer not null default 120,
  ping_max_s integer not null default 240,
  ping_fuzz_m integer not null default 0,
  reveal_seekers boolean not null default true,
  jammers integer not null default 1,
  -- runtime
  final_lat double precision,
  final_lng double precision,
  started_at timestamptz,
  seek_at timestamptz,
  ends_at timestamptz,
  ended_at timestamptz,
  next_ping_at timestamptz,
  last_ping_at timestamptz,
  ping_seq integer not null default 0,
  winner text,
  created_at timestamptz not null default now()
);

create table hideseek.players (
  id uuid primary key default gen_random_uuid(),
  room_code text not null references hideseek.rooms(code) on delete cascade,
  secret uuid not null,
  name text not null,
  color text not null,
  role text not null default 'hider' check (role in ('hider','seeker')),
  status text not null default 'active' check (status in ('active','caught')),
  tag_code text,
  jammers_left integer not null default 0,
  jam_armed boolean not null default false,
  caught_at timestamptz,
  caught_by uuid,
  lat double precision,
  lng double precision,
  acc real,
  loc_at timestamptz,
  outside_since timestamptz,
  last_seen timestamptz not null default now(),
  joined_at timestamptz not null default now()
);
create index players_room_idx on hideseek.players(room_code);

create table hideseek.pings (
  id bigint generated always as identity primary key,
  room_code text not null references hideseek.rooms(code) on delete cascade,
  seq integer not null,
  player_id uuid not null references hideseek.players(id) on delete cascade,
  role text not null,
  lat double precision,
  lng double precision,
  fuzz_m integer not null default 0,
  stale_s integer,
  jammed boolean not null default false,
  created_at timestamptz not null default now()
);
create index pings_room_idx on hideseek.pings(room_code, seq);
create index pings_player_idx on hideseek.pings(player_id);

create table hideseek.events (
  id bigint generated always as identity primary key,
  room_code text not null references hideseek.rooms(code) on delete cascade,
  kind text not null,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index events_room_idx on hideseek.events(room_code, id);

alter table hideseek.rooms enable row level security;
alter table hideseek.players enable row level security;
alter table hideseek.pings enable row level security;
alter table hideseek.events enable row level security;

-- ---------------------------------------------------------------- helpers

create function hideseek.ms(t timestamptz) returns bigint
language sql immutable set search_path = '' as $$
  select (extract(epoch from t) * 1000)::bigint
$$;

create function hideseek.dist_m(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision language sql immutable set search_path = '' as $$
  select 2 * 6371000 * asin(sqrt(least(1,
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))))
$$;

create function hideseek.log(p_code text, p_kind text, p_data jsonb) returns void
language sql set search_path = '' as $$
  insert into hideseek.events(room_code, kind, data) values (p_code, p_kind, coalesce(p_data, '{}'::jsonb))
$$;

create function hideseek.clean_name(p_name text) returns text
language plpgsql immutable set search_path = '' as $$
declare n text := left(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')), 16);
begin
  if n = '' then raise exception 'NAME_REQUIRED'; end if;
  return n;
end $$;

create function hideseek.pick_color(p_code text) returns text
language plpgsql set search_path = '' as $$
declare
  pal constant text[] := array['#E4572E','#2B7FD9','#2F9E63','#7A5CD6','#F29F05','#0B8C86','#D1495B','#5568C9',
                               '#8D6E63','#00A3C4','#6B8E23','#B5651D','#3D4A6B','#E07BB0','#4CAF93','#A0522D'];
  v text;
begin
  select c into v from unnest(pal) with ordinality as t(c, i)
   where c not in (select color from hideseek.players where room_code = p_code)
   order by i limit 1;
  return coalesce(v, pal[1 + floor(random() * array_length(pal, 1))::int]);
end $$;

create function hideseek.auth(p_code text, p_pid uuid, p_secret uuid) returns hideseek.players
language plpgsql set search_path = '' as $$
declare me hideseek.players;
begin
  select * into me from hideseek.players where id = p_pid and room_code = p_code and secret = p_secret;
  if not found then raise exception 'NOT_IN_ROOM'; end if;
  return me;
end $$;

-- Checks the caller is the host and returns the room, locked for the rest of the transaction.
create function hideseek.host(p_code text, p_pid uuid, p_secret uuid) returns hideseek.rooms
language plpgsql set search_path = '' as $$
declare me hideseek.players; r hideseek.rooms;
begin
  me := hideseek.auth(p_code, p_pid, p_secret);
  select * into r from hideseek.rooms where code = p_code for update;
  if r.host_id is distinct from me.id then raise exception 'HOST_ONLY'; end if;
  return r;
end $$;

-- Where the zone is at time t. It drifts from the starting circle to a smaller final
-- circle, finishing the shrink when 85% of the seeking time has passed.
create function hideseek.zone_at(r hideseek.rooms, t timestamptz,
  out lat double precision, out lng double precision, out radius double precision)
language plpgsql stable set search_path = '' as $$
declare p double precision := 0; rf double precision; tt timestamptz := t;
begin
  if r.zone_lat is null then return; end if;
  rf := greatest(20, r.zone_radius_m * r.final_pct / 100.0);
  if r.status <> 'lobby' and r.seek_at is not null then
    if r.ended_at is not null then tt := least(t, r.ended_at); end if;
    p := greatest(0, least(1, extract(epoch from (tt - r.seek_at)) / (0.85 * r.game_seconds)));
  end if;
  lat := r.zone_lat + (coalesce(r.final_lat, r.zone_lat) - r.zone_lat) * p;
  lng := r.zone_lng + (coalesce(r.final_lng, r.zone_lng) - r.zone_lng) * p;
  radius := r.zone_radius_m + (rf - r.zone_radius_m) * p;
end $$;

-- Advances the game clock: fires a ping when one is due and ends the game on time.
-- There is no server timer; this runs whenever any player checks in.
create function hideseek.tick(p_code text) returns void
language plpgsql set search_path = '' as $$
declare
  r hideseek.rooms; p hideseek.players;
  v_seq int; a double precision; d double precision; v_jam int := 0; v_n int := 0;
begin
  select * into r from hideseek.rooms where code = p_code;
  if not found or r.status <> 'playing' or now() < least(r.ends_at, r.next_ping_at) then return; end if;

  select * into r from hideseek.rooms where code = p_code for update;
  if r.status <> 'playing' then return; end if;

  if now() >= r.ends_at then
    update hideseek.rooms set status = 'ended', winner = 'hiders', ended_at = r.ends_at where code = p_code;
    perform hideseek.log(p_code, 'end', jsonb_build_object('winner', 'hiders'));
    return;
  end if;
  if now() < r.next_ping_at then return; end if;

  v_seq := r.ping_seq + 1;
  for p in select * from hideseek.players where room_code = p_code loop
    if p.role = 'hider' and p.status = 'active' then
      v_n := v_n + 1;
      if p.jam_armed then
        v_jam := v_jam + 1;
        insert into hideseek.pings(room_code, seq, player_id, role, jammed) values (p_code, v_seq, p.id, 'hider', true);
        update hideseek.players set jam_armed = false where id = p.id;
      elsif p.lat is null then
        insert into hideseek.pings(room_code, seq, player_id, role) values (p_code, v_seq, p.id, 'hider');
      else
        a := random() * 2 * pi();
        d := sqrt(random()) * r.ping_fuzz_m;
        insert into hideseek.pings(room_code, seq, player_id, role, lat, lng, fuzz_m, stale_s)
        values (p_code, v_seq, p.id, 'hider',
                p.lat + d * cos(a) / 111320.0,
                p.lng + d * sin(a) / (111320.0 * cos(radians(p.lat))),
                r.ping_fuzz_m, extract(epoch from now() - p.loc_at)::int);
      end if;
    elsif p.lat is not null then
      insert into hideseek.pings(room_code, seq, player_id, role, lat, lng, stale_s)
      values (p_code, v_seq, p.id, 'seeker', p.lat, p.lng, extract(epoch from now() - p.loc_at)::int);
    end if;
  end loop;

  update hideseek.rooms
     set ping_seq = v_seq, last_ping_at = now(),
         next_ping_at = now() + make_interval(secs => r.ping_min_s + random() * (r.ping_max_s - r.ping_min_s))
   where code = p_code;
  perform hideseek.log(p_code, 'ping', jsonb_build_object('seq', v_seq, 'hiders', v_n, 'jammed', v_jam));
end $$;

create function hideseek.mark_caught(p_code text, p_target uuid, p_by uuid) returns text
language plpgsql set search_path = '' as $$
declare r hideseek.rooms; t hideseek.players; v_by text;
begin
  select * into r from hideseek.rooms where code = p_code for update;
  if r.status <> 'playing' then return null; end if;
  update hideseek.players
     set status = 'caught', caught_at = now(), caught_by = p_by, jam_armed = false, outside_since = null
   where id = p_target and room_code = p_code and status = 'active' and role = 'hider'
   returning * into t;
  if not found then return null; end if;
  select name into v_by from hideseek.players where id = p_by;
  perform hideseek.log(p_code, 'caught', jsonb_build_object('id', t.id, 'name', t.name, 'by', v_by));
  if not exists (select 1 from hideseek.players where room_code = p_code and role = 'hider' and status = 'active') then
    update hideseek.rooms set status = 'ended', winner = 'seekers', ended_at = now() where code = p_code;
    perform hideseek.log(p_code, 'end', jsonb_build_object('winner', 'seekers'));
  end if;
  return t.name;
end $$;

create function hideseek.remove_player(p_code text, p_target uuid) returns void
language plpgsql set search_path = '' as $$
declare r hideseek.rooms; v_name text;
begin
  select * into r from hideseek.rooms where code = p_code for update;
  delete from hideseek.players where id = p_target and room_code = p_code returning name into v_name;
  if not found then return; end if;
  if not exists (select 1 from hideseek.players where room_code = p_code) then
    delete from hideseek.rooms where code = p_code;
    return;
  end if;
  perform hideseek.log(p_code, 'left', jsonb_build_object('name', v_name));
  if r.host_id = p_target then
    update hideseek.rooms
       set host_id = (select id from hideseek.players where room_code = p_code order by joined_at limit 1)
     where code = p_code;
  end if;
  if r.status = 'playing' and not exists
     (select 1 from hideseek.players where room_code = p_code and role = 'hider' and status = 'active') then
    update hideseek.rooms set status = 'ended', winner = 'seekers', ended_at = now() where code = p_code;
    perform hideseek.log(p_code, 'end', jsonb_build_object('winner', 'seekers'));
  end if;
end $$;

-- ---------------------------------------------------------------- public API

create function public.hs_create_room(p_name text, p_secret uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  abc constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  v_code text; v_pid uuid; v_name text := hideseek.clean_name(p_name);
begin
  if p_secret is null then raise exception 'NOT_IN_ROOM'; end if;
  -- tidy up rooms nobody has touched for half a day
  delete from hideseek.rooms r
   where r.created_at < now() - interval '12 hours'
     and not exists (select 1 from hideseek.players p
                      where p.room_code = r.code and p.last_seen > now() - interval '12 hours');
  loop
    v_code := '';
    for i in 1..4 loop
      v_code := v_code || substr(abc, 1 + floor(random() * 24)::int, 1);
    end loop;
    exit when not exists (select 1 from hideseek.rooms where code = v_code);
  end loop;
  insert into hideseek.rooms(code) values (v_code);
  insert into hideseek.players(room_code, secret, name, color)
  values (v_code, p_secret, v_name, hideseek.pick_color(v_code)) returning id into v_pid;
  update hideseek.rooms set host_id = v_pid where code = v_code;
  return jsonb_build_object('code', v_code, 'player_id', v_pid);
end $$;

create function public.hs_join_room(p_code text, p_name text, p_secret uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_code text := upper(btrim(coalesce(p_code, '')));
  r hideseek.rooms; v_pid uuid; v_name text := hideseek.clean_name(p_name); v_role text := 'hider';
begin
  if p_secret is null then raise exception 'NOT_IN_ROOM'; end if;
  select * into r from hideseek.rooms where code = v_code for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  select id into v_pid from hideseek.players where room_code = v_code and secret = p_secret;
  if found then
    update hideseek.players set name = v_name, last_seen = now() where id = v_pid;
  else
    if (select count(*) from hideseek.players where room_code = v_code) >= 24 then
      raise exception 'ROOM_FULL';
    end if;
    -- arriving mid-game: you join the hunt
    if r.status = 'playing' then v_role := 'seeker'; end if;
    insert into hideseek.players(room_code, secret, name, color, role)
    values (v_code, p_secret, v_name, hideseek.pick_color(v_code), v_role) returning id into v_pid;
    perform hideseek.log(v_code, 'join', jsonb_build_object('name', v_name));
  end if;
  return jsonb_build_object('code', v_code, 'player_id', v_pid);
end $$;

create function public.hs_update_settings(p_code text, p_pid uuid, p_secret uuid, p_settings jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(p_code); r hideseek.rooms; s jsonb := coalesce(p_settings, '{}'::jsonb);
begin
  r := hideseek.host(v_code, p_pid, p_secret);
  if r.status <> 'lobby' then raise exception 'NOT_IN_LOBBY'; end if;
  update hideseek.rooms set
    zone_lat      = least(90, greatest(-90, coalesce((s->>'zone_lat')::double precision, zone_lat))),
    zone_lng      = least(180, greatest(-180, coalesce((s->>'zone_lng')::double precision, zone_lng))),
    zone_radius_m = least(5000, greatest(50, coalesce((s->>'zone_radius_m')::int, zone_radius_m))),
    final_pct     = least(60, greatest(5, coalesce((s->>'final_pct')::int, final_pct))),
    hide_seconds  = least(1800, greatest(10, coalesce((s->>'hide_seconds')::int, hide_seconds))),
    game_seconds  = least(10800, greatest(60, coalesce((s->>'game_seconds')::int, game_seconds))),
    ping_min_s    = least(1800, greatest(10, coalesce((s->>'ping_min_s')::int, ping_min_s))),
    ping_max_s    = least(3600, greatest(10, coalesce((s->>'ping_max_s')::int, ping_max_s))),
    ping_fuzz_m   = least(500, greatest(0, coalesce((s->>'ping_fuzz_m')::int, ping_fuzz_m))),
    reveal_seekers = coalesce((s->>'reveal_seekers')::boolean, reveal_seekers),
    jammers       = least(3, greatest(0, coalesce((s->>'jammers')::int, jammers)))
  where code = v_code;
  update hideseek.rooms set ping_max_s = greatest(ping_max_s, ping_min_s) where code = v_code;
end $$;

create function public.hs_set_role(p_code text, p_pid uuid, p_secret uuid, p_target uuid, p_role text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(p_code); r hideseek.rooms;
begin
  r := hideseek.host(v_code, p_pid, p_secret);
  if r.status <> 'lobby' then raise exception 'NOT_IN_LOBBY'; end if;
  if p_role not in ('hider', 'seeker') then raise exception 'BAD_ROLE'; end if;
  update hideseek.players set role = p_role where id = p_target and room_code = v_code;
end $$;

create function public.hs_start(p_code text, p_pid uuid, p_secret uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_code text := upper(p_code); r hideseek.rooms; p hideseek.players;
  v_rf double precision; a double precision; d double precision; v_tag text;
begin
  r := hideseek.host(v_code, p_pid, p_secret);
  if r.status <> 'lobby' then raise exception 'NOT_IN_LOBBY'; end if;
  if r.zone_lat is null then raise exception 'NO_ZONE'; end if;
  if (select count(*) from hideseek.players where room_code = v_code) < 2 then raise exception 'NEED_PLAYERS'; end if;
  if not exists (select 1 from hideseek.players where room_code = v_code and role = 'seeker') then
    update hideseek.players set role = 'seeker'
     where id = (select id from hideseek.players where room_code = v_code order by random() limit 1);
  end if;
  if not exists (select 1 from hideseek.players where room_code = v_code and role = 'hider') then
    raise exception 'NEED_HIDER';
  end if;

  -- the final circle sits somewhere inside the starting one; nobody is told where
  v_rf := greatest(20, r.zone_radius_m * r.final_pct / 100.0);
  a := random() * 2 * pi();
  d := sqrt(random()) * greatest(0, r.zone_radius_m - v_rf) * 0.8;

  delete from hideseek.pings where room_code = v_code;
  delete from hideseek.events where room_code = v_code;
  update hideseek.players
     set status = 'active', caught_at = null, caught_by = null, jam_armed = false, outside_since = null,
         tag_code = null, jammers_left = case when role = 'hider' then r.jammers else 0 end
   where room_code = v_code;
  for p in select * from hideseek.players where room_code = v_code and role = 'hider' loop
    loop
      v_tag := lpad(floor(random() * 10000)::int::text, 4, '0');
      exit when not exists (select 1 from hideseek.players where room_code = v_code and tag_code = v_tag);
    end loop;
    update hideseek.players set tag_code = v_tag where id = p.id;
  end loop;

  update hideseek.rooms set
    status = 'playing', round = round + 1, winner = null, ended_at = null, ping_seq = 0, last_ping_at = null,
    started_at = now(),
    seek_at = now() + make_interval(secs => r.hide_seconds),
    ends_at = now() + make_interval(secs => r.hide_seconds + r.game_seconds),
    next_ping_at = now() + make_interval(secs => r.hide_seconds + r.ping_min_s + random() * (r.ping_max_s - r.ping_min_s)),
    final_lat = r.zone_lat + d * cos(a) / 111320.0,
    final_lng = r.zone_lng + d * sin(a) / (111320.0 * cos(radians(r.zone_lat)))
  where code = v_code;
  perform hideseek.log(v_code, 'start', '{}'::jsonb);
end $$;

create function public.hs_tag(p_code text, p_pid uuid, p_secret uuid, p_tag text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(p_code); me hideseek.players; r hideseek.rooms; v_target uuid; v_name text;
begin
  me := hideseek.auth(v_code, p_pid, p_secret);
  select * into r from hideseek.rooms where code = v_code;
  if r.status <> 'playing' or now() < r.seek_at then raise exception 'NOT_SEEKING'; end if;
  if not (me.role = 'seeker' or me.status = 'caught') then raise exception 'SEEKERS_ONLY'; end if;
  select id into v_target from hideseek.players
   where room_code = v_code and role = 'hider' and status = 'active' and tag_code = btrim(coalesce(p_tag, ''));
  if not found then raise exception 'WRONG_CODE'; end if;
  v_name := hideseek.mark_caught(v_code, v_target, me.id);
  return jsonb_build_object('name', v_name);
end $$;

create function public.hs_give_up(p_code text, p_pid uuid, p_secret uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(p_code); me hideseek.players;
begin
  me := hideseek.auth(v_code, p_pid, p_secret);
  if me.role <> 'hider' or me.status <> 'active' then raise exception 'NOT_HIDING'; end if;
  perform hideseek.mark_caught(v_code, me.id, null);
end $$;

create function public.hs_jam(p_code text, p_pid uuid, p_secret uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(p_code); me hideseek.players; r hideseek.rooms;
begin
  me := hideseek.auth(v_code, p_pid, p_secret);
  select * into r from hideseek.rooms where code = v_code;
  if r.status <> 'playing' or me.role <> 'hider' or me.status <> 'active' then raise exception 'NOT_HIDING'; end if;
  if me.jam_armed then return; end if;
  if me.jammers_left < 1 then raise exception 'NO_JAMMERS'; end if;
  update hideseek.players set jam_armed = true, jammers_left = jammers_left - 1 where id = me.id;
end $$;

create function public.hs_end_game(p_code text, p_pid uuid, p_secret uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(p_code); r hideseek.rooms;
begin
  r := hideseek.host(v_code, p_pid, p_secret);
  if r.status <> 'playing' then return; end if;
  update hideseek.rooms set status = 'ended', winner = 'nobody', ended_at = now() where code = v_code;
  perform hideseek.log(v_code, 'end', jsonb_build_object('winner', 'nobody'));
end $$;

create function public.hs_reset(p_code text, p_pid uuid, p_secret uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(p_code); r hideseek.rooms;
begin
  r := hideseek.host(v_code, p_pid, p_secret);
  update hideseek.rooms
     set status = 'lobby', winner = null, started_at = null, seek_at = null, ends_at = null, ended_at = null,
         next_ping_at = null, last_ping_at = null, ping_seq = 0, final_lat = null, final_lng = null
   where code = v_code;
  update hideseek.players
     set status = 'active', caught_at = null, caught_by = null, jam_armed = false, jammers_left = 0,
         outside_since = null, tag_code = null
   where room_code = v_code;
  delete from hideseek.pings where room_code = v_code;
end $$;

create function public.hs_leave(p_code text, p_pid uuid, p_secret uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(p_code); me hideseek.players;
begin
  me := hideseek.auth(v_code, p_pid, p_secret);
  perform hideseek.remove_player(v_code, me.id);
end $$;

create function public.hs_kick(p_code text, p_pid uuid, p_secret uuid, p_target uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(p_code); r hideseek.rooms;
begin
  r := hideseek.host(v_code, p_pid, p_secret);
  if p_target = p_pid then raise exception 'BAD_TARGET'; end if;
  perform hideseek.remove_player(v_code, p_target);
end $$;

-- The heartbeat. Each phone calls this every couple of seconds: it reports its own
-- position and gets back exactly what that player is allowed to see.
create function public.hs_state(p_code text, p_pid uuid, p_secret uuid,
  p_lat double precision default null, p_lng double precision default null, p_acc real default null,
  p_after_event bigint default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := upper(p_code);
  me hideseek.players; r hideseek.rooms; z record;
  v_hunter boolean; v_seeking boolean; v_out timestamptz;
  j_players jsonb; j_pos jsonb; j_pings jsonb; j_events jsonb;
begin
  me := hideseek.auth(v_code, p_pid, p_secret);
  perform hideseek.tick(v_code);
  select * into r from hideseek.rooms where code = v_code;
  select * into z from hideseek.zone_at(r, now());
  select * into me from hideseek.players where id = p_pid;

  if p_lat is not null and p_lng is not null then
    v_out := null;
    if r.status = 'playing' and me.role = 'hider' and me.status = 'active' and z.radius is not null
       and hideseek.dist_m(p_lat, p_lng, z.lat, z.lng) > z.radius + least(coalesce(p_acc, 0), 20) then
      v_out := coalesce(me.outside_since, now());
    end if;
    update hideseek.players
       set lat = p_lat, lng = p_lng, acc = p_acc, loc_at = now(), last_seen = now(), outside_since = v_out
     where id = me.id returning * into me;
  else
    update hideseek.players set last_seen = now() where id = me.id;
  end if;

  v_hunter := me.role = 'seeker' or me.status = 'caught';
  v_seeking := r.status = 'playing' and now() >= r.seek_at;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'name', p.name, 'color', p.color, 'role', p.role, 'status', p.status,
           'host', p.id = r.host_id,
           'online', p.last_seen > now() - interval '20 seconds',
           'gps', p.loc_at is not null and p.loc_at > now() - interval '45 seconds',
           'caught_at', hideseek.ms(p.caught_at),
           'caught_by', (select c.name from hideseek.players c where c.id = p.caught_by)
         ) order by p.joined_at), '[]'::jsonb)
    into j_players from hideseek.players p where p.room_code = v_code;

  -- live positions: hunters see each other, plus any hider who has been outside the zone for 20s
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'lat', p.lat, 'lng', p.lng, 'acc', p.acc,
           'age', extract(epoch from now() - p.loc_at)::int,
           'exposed', r.status = 'playing' and p.role = 'hider' and p.status = 'active')), '[]'::jsonb)
    into j_pos from hideseek.players p
   where p.room_code = v_code and p.id <> me.id and p.lat is not null
     and ( r.status = 'ended'
        or ( r.status = 'playing' and v_hunter and (
               p.role = 'seeker' or p.status = 'caught'
               or (v_seeking and p.outside_since is not null and p.outside_since < now() - interval '20 seconds'))));

  select coalesce(jsonb_agg(jsonb_build_object(
           'seq', g.seq, 'id', g.player_id, 'role', g.role, 'lat', g.lat, 'lng', g.lng,
           'fuzz', g.fuzz_m, 'stale', g.stale_s, 'jammed', g.jammed, 'at', hideseek.ms(g.created_at)
         ) order by g.seq, g.id), '[]'::jsonb)
    into j_pings from hideseek.pings g
   where g.room_code = v_code and g.seq > r.ping_seq - 3
     and ( r.status = 'ended'
        or g.player_id = me.id
        or (v_hunter and g.role = 'hider')
        or (not v_hunter and g.role = 'seeker' and r.reveal_seekers));

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id, 'kind', e.kind, 'data', e.data, 'at', hideseek.ms(e.created_at)) order by e.id), '[]'::jsonb)
    into j_events
    from (select * from hideseek.events where room_code = v_code and id > coalesce(p_after_event, 0)
           order by id desc limit 30) e;

  return jsonb_build_object(
    'now', hideseek.ms(clock_timestamp()),
    'room', jsonb_build_object(
      'code', r.code, 'status', r.status, 'host_id', r.host_id, 'round', r.round,
      'started_at', hideseek.ms(r.started_at), 'seek_at', hideseek.ms(r.seek_at),
      'ends_at', hideseek.ms(r.ends_at), 'ended_at', hideseek.ms(r.ended_at),
      'ping_seq', r.ping_seq, 'last_ping_at', hideseek.ms(r.last_ping_at), 'winner', r.winner,
      'zone', case when z.lat is null then null
                   else jsonb_build_object('lat', z.lat, 'lng', z.lng, 'r', z.radius) end,
      'settings', jsonb_build_object(
        'zone_lat', r.zone_lat, 'zone_lng', r.zone_lng, 'zone_radius_m', r.zone_radius_m,
        'final_pct', r.final_pct, 'hide_seconds', r.hide_seconds, 'game_seconds', r.game_seconds,
        'ping_min_s', r.ping_min_s, 'ping_max_s', r.ping_max_s, 'ping_fuzz_m', r.ping_fuzz_m,
        'reveal_seekers', r.reveal_seekers, 'jammers', r.jammers)),
    'me', jsonb_build_object(
      'id', me.id, 'name', me.name, 'color', me.color, 'role', me.role, 'status', me.status,
      'host', me.id = r.host_id, 'tag_code', me.tag_code,
      'jammers_left', me.jammers_left, 'jam_armed', me.jam_armed,
      'outside', me.outside_since is not null,
      'outside_s', extract(epoch from now() - me.outside_since)::int,
      'exposed', v_seeking and me.outside_since is not null and me.outside_since < now() - interval '20 seconds'),
    'players', j_players, 'positions', j_pos, 'pings', j_pings, 'events', j_events);
end $$;

-- ---------------------------------------------------------------- permissions
-- Only the hs_* functions are callable from the browser (the "anon" role).
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'hs\_%' loop
    execute format('revoke execute on function %s from public, authenticated', f.sig);
    execute format('grant execute on function %s to anon', f.sig);
  end loop;
end $$;
