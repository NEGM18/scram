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
  catch_m integer not null default 2,
  safe_min_s integer not null default 240,   -- a safe point opens every safe_min_s..safe_max_s
  safe_max_s integer not null default 420,   -- 0 switches safe points off
  safe_seconds integer not null default 180,
  -- runtime
  final_lat double precision,
  final_lng double precision,
  started_at timestamptz,
  seek_at timestamptz,
  ends_at timestamptz,
  ended_at timestamptz,
  next_ping_at timestamptz,
  next_safe_at timestamptz,                  -- when a safe point next opens or runs out
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
  catch_block_until timestamptz,   -- a "found you" call from too far away locks the caller out briefly
  immune_until timestamptz,        -- getaway time after a safe point ends
  safe_away_since timestamptz,     -- holding a safe point but standing outside it
  last_seen timestamptz not null default now(),
  joined_at timestamptz not null default now()
);
create index players_room_idx on hideseek.players(room_code);

-- The hidden track: one row per player per second while a game runs, and only the last
-- half minute is kept. Nobody is ever shown this; it exists so hs_catch can check that a
-- seeker really was next to the hider they claim to have found.
create table hideseek.fixes (
  player_id uuid not null references hideseek.players(id) on delete cascade,
  at timestamptz not null default now(),
  lat double precision not null,
  lng double precision not null,
  acc real,
  primary key (player_id, at)
);

-- A safe point is a circle, and the first hider to step inside holds it.
create table hideseek.safe_points (
  id bigint generated always as identity primary key,
  room_code text not null references hideseek.rooms(code) on delete cascade,
  lat double precision not null,
  lng double precision not null,
  radius_m integer not null,
  spawned_at timestamptz not null default now(),
  expires_at timestamptz not null,
  claimed_by uuid references hideseek.players(id) on delete set null,
  claimed_at timestamptz,
  ended_at timestamptz
);
-- at most one open safe point per room
create unique index safe_points_live_idx on hideseek.safe_points(room_code) where ended_at is null;

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
alter table hideseek.fixes enable row level security;
alter table hideseek.safe_points enable row level security;

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

-- ---------------------------------------------------------------- catching and safe points

-- The hidden proximity check behind "found you". It compares the two phones' tracks over
-- the last few seconds rather than one reading each, so a hider who bolts while the seeker
-- is still tapping is judged at their closest approach. Phone GPS is only good to a few
-- metres, so each phone's own reported uncertainty (capped at 10 m) is added to the catch
-- distance. A hider whose phone has gone quiet is checked against where it was last seen.
create function hideseek.was_near(p_seeker uuid, t hideseek.players, p_reach integer) returns boolean
language sql stable set search_path = '' as $$
  select exists (
           select 1
             from hideseek.fixes s
             join hideseek.fixes h
               on h.player_id = t.id
              and h.at between s.at - interval '3 seconds' and s.at + interval '3 seconds'
            where s.player_id = p_seeker and s.at > now() - interval '12 seconds'
              and hideseek.dist_m(s.lat, s.lng, h.lat, h.lng)
                  <= p_reach + least(coalesce(s.acc, 0), 10) + least(coalesce(h.acc, 0), 10))
      or ( t.lat is not null
           and not exists (select 1 from hideseek.fixes h
                            where h.player_id = t.id and h.at > now() - interval '15 seconds')
           and exists (
                 select 1 from hideseek.fixes s
                  where s.player_id = p_seeker and s.at > now() - interval '12 seconds'
                    and hideseek.dist_m(s.lat, s.lng, t.lat, t.lng)
                        <= p_reach + least(coalesce(s.acc, 0), 10) + least(coalesce(t.acc, 0), 10)))
$$;

-- A hider cannot be caught while holding a safe point, or during the getaway after it.
create function hideseek.is_safe(p hideseek.players) returns boolean
language sql stable set search_path = '' as $$
  select coalesce(p.immune_until > now(), false)
      or exists (select 1 from hideseek.safe_points s
                  where s.room_code = p.room_code and s.ended_at is null and s.claimed_by = p.id)
$$;

-- How long until the next safe point opens. Null when safe points are switched off.
create function hideseek.safe_delay(r hideseek.rooms) returns interval
language sql volatile set search_path = '' as $$
  select case when r.safe_max_s > 0
              then make_interval(secs => r.safe_min_s + random() * (r.safe_max_s - r.safe_min_s)) end
$$;

-- Closes the open safe point. The caller must already hold the room lock.
create function hideseek.close_safe(p_code text, p_reason text) returns void
language plpgsql set search_path = '' as $$
declare sp hideseek.safe_points; r hideseek.rooms; v_name text;
begin
  select * into sp from hideseek.safe_points where room_code = p_code and ended_at is null for update;
  if not found then return; end if;
  select * into r from hideseek.rooms where code = p_code;
  update hideseek.safe_points set ended_at = now() where id = sp.id;
  if sp.claimed_by is not null then
    -- whoever held it gets a 30 second getaway, so a seeker cannot just camp the edge
    update hideseek.players
       set safe_away_since = null,
           immune_until = case when status = 'active' then now() + interval '30 seconds' end
     where id = sp.claimed_by
     returning name into v_name;
  end if;
  update hideseek.rooms set next_safe_at = now() + hideseek.safe_delay(r) where code = p_code;
  perform hideseek.log(p_code, 'safe_end',
    jsonb_build_object('reason', p_reason, 'id', sp.claimed_by, 'name', v_name));
end $$;

-- Opens a safe point. It is a circle rather than a spot, because GPS cannot tell a doorway
-- from the street outside it. It lands inside where the zone will still be when it runs
-- out, and far from every hider, so nobody is handed it for free.
-- The caller must already hold the room lock.
create function hideseek.spawn_safe(r hideseek.rooms) returns void
language plpgsql set search_path = '' as $$
declare
  c_radius constant integer := 15;   -- metres
  c_open constant integer := 240;    -- seconds it stays open if nobody reaches it
  z record; v_until timestamptz; v_min double precision; v_max double precision := 350;
  a double precision; d double precision; c_lat double precision; c_lng double precision;
  v_near double precision; v_pen double precision;
  b_lat double precision; b_lng double precision; b_pen double precision;
begin
  v_until := least(r.ends_at, now() + make_interval(secs => c_open + r.safe_seconds));
  select * into z from hideseek.zone_at(r, v_until);
  if r.ends_at - now() < interval '90 seconds' or z.radius is null or z.radius < 3 * c_radius then
    update hideseek.rooms set next_safe_at = null where code = r.code;   -- no more this round
    return;
  end if;

  -- aim for 150 to 350 m from the nearest hider (closer when the zone is small)
  v_min := least(150, z.radius * 0.5);
  for i in 1..40 loop
    a := random() * 2 * pi();
    d := sqrt(random()) * (z.radius - c_radius - 5);
    c_lat := z.lat + d * cos(a) / 111320.0;
    c_lng := z.lng + d * sin(a) / (111320.0 * cos(radians(z.lat)));
    select min(hideseek.dist_m(c_lat, c_lng, p.lat, p.lng)) into v_near
      from hideseek.players p
     where p.room_code = r.code and p.role = 'hider' and p.status = 'active' and p.lat is not null;
    v_pen := case when v_near is null then 0
                  when v_near < v_min then v_min - v_near
                  when v_near > v_max then v_near - v_max
                  else 0 end;
    if b_pen is null or v_pen < b_pen then
      b_lat := c_lat; b_lng := c_lng; b_pen := v_pen;
    end if;
    exit when b_pen = 0;
  end loop;

  insert into hideseek.safe_points(room_code, lat, lng, radius_m, expires_at)
  values (r.code, b_lat, b_lng, c_radius, now() + make_interval(secs => c_open));
  update hideseek.rooms set next_safe_at = now() + make_interval(secs => c_open) where code = r.code;
  perform hideseek.log(r.code, 'safe_spawn', '{}'::jsonb);
end $$;

-- Runs each time an active hider reports a position: claims the open safe point if they
-- are the first one inside it, and ends their hold once they have walked off it.
-- p_claim is false for old copies of the site that cannot draw safe points.
create function hideseek.safe_step(r hideseek.rooms, me hideseek.players,
  p_lat double precision, p_lng double precision, p_acc real, p_claim boolean) returns void
language plpgsql set search_path = '' as $$
declare sp hideseek.safe_points; d double precision;
begin
  select * into sp from hideseek.safe_points where room_code = r.code and ended_at is null;
  if not found then return; end if;
  d := hideseek.dist_m(p_lat, p_lng, sp.lat, sp.lng);

  if sp.claimed_by is null then
    if not p_claim or d > sp.radius_m or now() >= sp.expires_at then return; end if;
    -- the room lock decides who was first when two hiders arrive together
    perform 1 from hideseek.rooms where code = r.code and status = 'playing' for update;
    if not found then return; end if;
    if not exists (select 1 from hideseek.players where id = me.id and status = 'active') then return; end if;
    update hideseek.safe_points
       set claimed_by = me.id, claimed_at = now(), expires_at = now() + make_interval(secs => r.safe_seconds)
     where id = sp.id and claimed_by is null and ended_at is null;
    if not found then return; end if;
    update hideseek.players
       set jammers_left = jammers_left + 1, safe_away_since = null, immune_until = null
     where id = me.id;
    update hideseek.rooms set next_safe_at = now() + make_interval(secs => r.safe_seconds) where code = r.code;
    perform hideseek.log(r.code, 'safe_claim', jsonb_build_object('id', me.id, 'name', me.name));

  elsif sp.claimed_by = me.id then
    -- GPS wobbles, so leaving only counts after 6 seconds clearly outside the circle
    if d > sp.radius_m + least(coalesce(p_acc, 0), 10) + 3 then
      if me.safe_away_since is null then
        update hideseek.players set safe_away_since = now() where id = me.id;
      elsif me.safe_away_since < now() - interval '6 seconds' then
        perform 1 from hideseek.rooms where code = r.code for update;
        perform hideseek.close_safe(r.code, 'left');
      end if;
    elsif me.safe_away_since is not null then
      update hideseek.players set safe_away_since = null where id = me.id;
    end if;
  end if;
end $$;

-- Advances the game clock: fires a ping when one is due, opens and closes safe points,
-- and ends the game on time. There is no server timer; this runs whenever any player checks in.
create function hideseek.tick(p_code text) returns void
language plpgsql set search_path = '' as $$
declare
  r hideseek.rooms; p hideseek.players; sp hideseek.safe_points;
  v_seq int; a double precision; d double precision; v_jam int := 0; v_n int := 0;
begin
  select * into r from hideseek.rooms where code = p_code;
  if not found or r.status <> 'playing'
     or now() < least(r.ends_at, r.next_ping_at, coalesce(r.next_safe_at, 'infinity')) then return; end if;

  select * into r from hideseek.rooms where code = p_code for update;
  if r.status <> 'playing' then return; end if;

  if now() >= r.ends_at then
    update hideseek.rooms set status = 'ended', winner = 'hiders', ended_at = r.ends_at where code = p_code;
    perform hideseek.log(p_code, 'end', jsonb_build_object('winner', 'hiders'));
    return;
  end if;

  if r.next_safe_at is not null and now() >= r.next_safe_at then
    select * into sp from hideseek.safe_points where room_code = p_code and ended_at is null;
    if not found then
      perform hideseek.spawn_safe(r);
    elsif now() >= sp.expires_at then
      perform hideseek.close_safe(p_code, case when sp.claimed_by is null then 'expired' else 'timeup' end);
    else
      update hideseek.rooms set next_safe_at = sp.expires_at where code = p_code;
    end if;
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
     set status = 'caught', caught_at = now(), caught_by = p_by, jam_armed = false, outside_since = null,
         immune_until = null, safe_away_since = null
   where id = p_target and room_code = p_code and status = 'active' and role = 'hider'
   returning * into t;
  if not found then return null; end if;
  select name into v_by from hideseek.players where id = p_by;
  perform hideseek.log(p_code, 'caught', jsonb_build_object('id', t.id, 'name', t.name, 'by', v_by));
  -- giving up while holding the safe point closes it
  if exists (select 1 from hideseek.safe_points
              where room_code = p_code and ended_at is null and claimed_by = t.id) then
    perform hideseek.close_safe(p_code, 'gone');
  end if;
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
  if exists (select 1 from hideseek.safe_points
              where room_code = p_code and ended_at is null and claimed_by = p_target) then
    perform hideseek.close_safe(p_code, 'gone');
  end if;
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
    jammers       = least(3, greatest(0, coalesce((s->>'jammers')::int, jammers))),
    catch_m       = least(50, greatest(1, coalesce((s->>'catch_m')::int, catch_m))),
    safe_min_s    = least(3600, greatest(0, coalesce((s->>'safe_min_s')::int, safe_min_s))),
    safe_max_s    = least(3600, greatest(0, coalesce((s->>'safe_max_s')::int, safe_max_s))),
    safe_seconds  = least(900, greatest(30, coalesce((s->>'safe_seconds')::int, safe_seconds)))
  where code = v_code;
  -- keep the ranges the right way round; a safe point range ending at 0 means "off"
  update hideseek.rooms set
    ping_max_s = greatest(ping_max_s, ping_min_s),
    safe_min_s = case when safe_max_s > 0 then greatest(30, safe_min_s) else 0 end,
    safe_max_s = case when safe_max_s > 0 then greatest(30, safe_min_s, safe_max_s) else 0 end
  where code = v_code;
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
  delete from hideseek.safe_points where room_code = v_code;
  delete from hideseek.fixes where player_id in (select id from hideseek.players where room_code = v_code);
  update hideseek.players
     set status = 'active', caught_at = null, caught_by = null, jam_armed = false, outside_since = null,
         catch_block_until = null, immune_until = null, safe_away_since = null,
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
    next_safe_at = now() + make_interval(secs => r.hide_seconds) + hideseek.safe_delay(r),
    final_lat = r.zone_lat + d * cos(a) / 111320.0,
    final_lng = r.zone_lng + d * sin(a) / (111320.0 * cos(radians(r.zone_lat)))
  where code = v_code;
  perform hideseek.log(v_code, 'start', '{}'::jsonb);
end $$;

-- "Found you": the seeker picks a hider by name and the server decides, from the hidden
-- track, whether the two phones really were within reach of each other. The distance is
-- never sent back, and a call from too far away locks the caller out for 20 seconds, so
-- the button cannot be mashed as a hot-or-cold radar.
create function public.hs_catch(p_code text, p_pid uuid, p_secret uuid, p_target uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_code text := upper(p_code); me hideseek.players; r hideseek.rooms; t hideseek.players;
  v_name text; v_until timestamptz;
begin
  me := hideseek.auth(v_code, p_pid, p_secret);
  select * into r from hideseek.rooms where code = v_code;
  if r.status <> 'playing' or now() < r.seek_at then raise exception 'NOT_SEEKING'; end if;
  if not (me.role = 'seeker' or me.status = 'caught') then raise exception 'SEEKERS_ONLY'; end if;
  if me.catch_block_until > now() then raise exception 'CATCH_WAIT'; end if;
  select * into t from hideseek.players
   where id = p_target and room_code = v_code and role = 'hider' and status = 'active';
  if not found then raise exception 'NOT_A_TARGET'; end if;
  if hideseek.is_safe(t) then raise exception 'TARGET_SAFE'; end if;
  if not exists (select 1 from hideseek.fixes
                  where player_id = me.id and at > now() - interval '12 seconds') then
    raise exception 'NO_FIX';
  end if;
  if t.lat is null then raise exception 'TARGET_NO_GPS'; end if;

  if hideseek.was_near(me.id, t, r.catch_m) then
    v_name := hideseek.mark_caught(v_code, t.id, me.id);
    if v_name is null then raise exception 'NOT_A_TARGET'; end if;   -- someone else got there first
    return jsonb_build_object('caught', true, 'name', v_name);
  end if;

  v_until := now() + interval '20 seconds';
  update hideseek.players set catch_block_until = v_until where id = me.id;
  return jsonb_build_object('caught', false, 'wait_until', hideseek.ms(v_until));
end $$;

-- The backup for when GPS lets a real catch down: the hider shows their tag code.
create function public.hs_tag(p_code text, p_pid uuid, p_secret uuid, p_tag text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(p_code); me hideseek.players; r hideseek.rooms; t hideseek.players; v_name text;
begin
  me := hideseek.auth(v_code, p_pid, p_secret);
  select * into r from hideseek.rooms where code = v_code;
  if r.status <> 'playing' or now() < r.seek_at then raise exception 'NOT_SEEKING'; end if;
  if not (me.role = 'seeker' or me.status = 'caught') then raise exception 'SEEKERS_ONLY'; end if;
  select * into t from hideseek.players
   where room_code = v_code and role = 'hider' and status = 'active' and tag_code = btrim(coalesce(p_tag, ''));
  if not found then raise exception 'WRONG_CODE'; end if;
  if hideseek.is_safe(t) then raise exception 'TARGET_SAFE'; end if;
  v_name := hideseek.mark_caught(v_code, t.id, me.id);
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
         next_ping_at = null, last_ping_at = null, ping_seq = 0, final_lat = null, final_lng = null,
         next_safe_at = null
   where code = v_code;
  update hideseek.players
     set status = 'active', caught_at = null, caught_by = null, jam_armed = false, jammers_left = 0,
         outside_since = null, tag_code = null,
         catch_block_until = null, immune_until = null, safe_away_since = null
   where room_code = v_code;
  delete from hideseek.pings where room_code = v_code;
  delete from hideseek.safe_points where room_code = v_code;
  delete from hideseek.fixes where player_id in (select id from hideseek.players where room_code = v_code);
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

-- The heartbeat. Each phone calls this every second during a game: it reports its own
-- position and gets back exactly what that player is allowed to see.
-- p_v is the site's version. Copies older than 2 cannot draw safe points, so they never claim one.
create function public.hs_state(p_code text, p_pid uuid, p_secret uuid,
  p_lat double precision default null, p_lng double precision default null, p_acc real default null,
  p_after_event bigint default 0, p_v integer default 1)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := upper(p_code);
  me hideseek.players; r hideseek.rooms; z record; sp hideseek.safe_points;
  v_hunter boolean; v_seeking boolean; v_out timestamptz; v_holder uuid;
  j_players jsonb; j_pos jsonb; j_pings jsonb; j_events jsonb; j_safe jsonb;
begin
  me := hideseek.auth(v_code, p_pid, p_secret);
  perform hideseek.tick(v_code);
  select * into r from hideseek.rooms where code = v_code;
  select * into z from hideseek.zone_at(r, now());
  select * into me from hideseek.players where id = p_pid;

  if p_lat is not null and p_lng is not null then
    if r.status = 'playing' then
      -- safe_step can take the room lock, so it runs before this call touches its own rows
      if me.role = 'hider' and me.status = 'active' then
        perform hideseek.safe_step(r, me, p_lat, p_lng, p_acc, coalesce(p_v, 1) >= 2);
      end if;
      insert into hideseek.fixes(player_id, at, lat, lng, acc)
      values (me.id, now(), p_lat, p_lng, p_acc) on conflict do nothing;
      delete from hideseek.fixes where player_id = me.id and at < now() - interval '30 seconds';
    end if;
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

  -- hiders see a safe point from the moment it opens; hunters only once somebody holds it
  if r.status = 'playing' then
    select * into sp from hideseek.safe_points where room_code = v_code and ended_at is null;
    if found then
      v_holder := sp.claimed_by;
      if v_holder is not null or not v_hunter then
        j_safe := jsonb_build_object(
          'id', sp.id, 'lat', sp.lat, 'lng', sp.lng, 'r', sp.radius_m,
          'expires_at', hideseek.ms(sp.expires_at), 'claimed_by', v_holder);
      end if;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'name', p.name, 'color', p.color, 'role', p.role, 'status', p.status,
           'host', p.id = r.host_id,
           'online', p.last_seen > now() - interval '20 seconds',
           'gps', p.loc_at is not null and p.loc_at > now() - interval '45 seconds',
           'caught_at', hideseek.ms(p.caught_at),
           'caught_by', (select c.name from hideseek.players c where c.id = p.caught_by),
           'safe', coalesce(p.id = v_holder, false),
           'immune_until', case when p.immune_until > now() then hideseek.ms(p.immune_until) end
         ) order by p.joined_at), '[]'::jsonb)
    into j_players from hideseek.players p where p.room_code = v_code;

  -- live positions: hunters see each other, any hider who has been outside the zone for 20s,
  -- and whoever holds the safe point. In return the holder sees every hunter.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'lat', p.lat, 'lng', p.lng, 'acc', p.acc,
           'age', extract(epoch from now() - p.loc_at)::int,
           'exposed', r.status = 'playing' and p.role = 'hider' and p.status = 'active',
           'safe', coalesce(p.id = v_holder, false))), '[]'::jsonb)
    into j_pos from hideseek.players p
   where p.room_code = v_code and p.id <> me.id and p.lat is not null
     and ( r.status = 'ended'
        or ( r.status = 'playing' and v_hunter and (
               p.role = 'seeker' or p.status = 'caught'
               or p.id = v_holder
               or (v_seeking and p.outside_since is not null and p.outside_since < now() - interval '20 seconds')))
        or ( r.status = 'playing' and me.id = v_holder and (p.role = 'seeker' or p.status = 'caught')));

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
        'reveal_seekers', r.reveal_seekers, 'jammers', r.jammers, 'catch_m', r.catch_m,
        'safe_min_s', r.safe_min_s, 'safe_max_s', r.safe_max_s, 'safe_seconds', r.safe_seconds)),
    'me', jsonb_build_object(
      'id', me.id, 'name', me.name, 'color', me.color, 'role', me.role, 'status', me.status,
      'host', me.id = r.host_id, 'tag_code', me.tag_code,
      'jammers_left', me.jammers_left, 'jam_armed', me.jam_armed,
      'outside', me.outside_since is not null,
      'outside_s', extract(epoch from now() - me.outside_since)::int,
      'exposed', v_seeking and me.outside_since is not null and me.outside_since < now() - interval '20 seconds',
      'on_safe', coalesce(me.id = v_holder, false),
      'safe_away', me.safe_away_since is not null,
      'immune_until', case when me.immune_until > now() then hideseek.ms(me.immune_until) end,
      'catch_wait_until', case when me.catch_block_until > now() then hideseek.ms(me.catch_block_until) end),
    'safe', j_safe,
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
