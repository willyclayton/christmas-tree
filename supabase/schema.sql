-- The Family Tree: database schema for Supabase.
--
-- HOW TO USE
--   1. Paste the whole file into Supabase > SQL Editor and press Run.
--   2. Set your admin secret with the one statement shown at the bottom.
--   It is safe to run more than once.
--
-- SECURITY MODEL (the link is public, so every row is treated as untrusted)
--   * Anyone can READ ornaments.
--   * Nobody can insert, update or delete rows directly.
--   * Hanging goes through hang_ornament(), which validates the ornament and
--     rate-limits it. Removing goes through remove_ornament(), which needs the
--     creator's private token or the admin secret. Thumbs up go through
--     like_ornament(): one per person per ornament.
--   * owner_token holds only a SHA-256 hash of the creator's token, so reading
--     the table never reveals anything that could be used to delete a row.

-- ---------------------------------------------------------------- table

create table if not exists public.ornaments (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  name        text not null default '',
  bauble      int  not null,
  strokes     jsonb not null default '[]'::jsonb,
  photo       text,
  x           real not null,
  y           real not null,
  owner_token text not null,

  constraint ornaments_name_len   check (char_length(name) <= 16),
  constraint ornaments_bauble     check (bauble between 0 and 5),
  constraint ornaments_x_range    check (x between 0 and 300),
  constraint ornaments_y_range    check (y between 0 and 400),
  constraint ornaments_strokes    check (
    case when jsonb_typeof(strokes) = 'array'
         then jsonb_array_length(strokes) <= 60 and length(strokes::text) <= 40000
         else false end),
  -- photos are small JPEGs the page shrinks to 240x240 before sending
  constraint ornaments_photo      check (
    photo is null
    or (length(photo) <= 64000
        and photo ~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$')),
  constraint ornaments_token_hash check (owner_token ~ '^[0-9a-f]{64}$')
);

-- thumbs-up count, kept up to date by like_ornament()
alter table public.ornaments add column if not exists likes int not null default 0;

create index if not exists ornaments_created_at_idx on public.ornaments (created_at);
create index if not exists ornaments_owner_idx on public.ornaments (owner_token, created_at);

-- ---------------------------------------------------------------- row level security

alter table public.ornaments enable row level security;

revoke all on public.ornaments from anon, authenticated;
grant select on public.ornaments to anon, authenticated;

drop policy if exists "anyone can read ornaments" on public.ornaments;
create policy "anyone can read ornaments"
  on public.ornaments for select
  to anon, authenticated
  using (true);
-- No insert / update / delete policies on purpose: those are denied.

-- ---------------------------------------------------------------- admin secret (private)

create schema if not exists private;
revoke all on schema private from anon, authenticated;

create table if not exists private.tree_admin (
  id          boolean primary key default true check (id),
  secret_hash text not null
);
alter table private.tree_admin enable row level security;
revoke all on private.tree_admin from anon, authenticated;

-- ---------------------------------------------------------------- hang an ornament

create or replace function public.hang_ornament(
  p_name    text,
  p_bauble  int,
  p_strokes jsonb,
  p_photo   text,
  p_x       real,
  p_y       real,
  p_token   text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hash   text;
  v_name   text;
  v_points bigint;
  v_bad    bigint;
  v_id     uuid;
  v_at     timestamptz;
begin
  if p_token is null or length(p_token) < 16 or length(p_token) > 128 then
    raise exception 'bad_token';
  end if;
  v_hash := encode(sha256(convert_to(p_token, 'UTF8')), 'hex');

  -- one insert at a time, so the limits below cannot be raced
  perform pg_advisory_xact_lock(hashtext('ornaments_hang'));

  -- limits: 3 ornaments per person (remove one to hang another), plus
  -- safety caps for the whole tree
  if (select count(*) from ornaments where owner_token = v_hash) >= 3 then
    raise exception 'limit_reached';
  end if;
  if (select count(*) from ornaments
       where created_at > now() - interval '1 hour') >= 150 then
    raise exception 'tree_busy';
  end if;
  if (select count(*) from ornaments) >= 400 then
    raise exception 'tree_full';
  end if;

  -- drawing: [{c: pen index, w: width, p: [x,y,x,y,...]}], 0-100 space
  if p_strokes is null or jsonb_typeof(p_strokes) <> 'array'
     or jsonb_array_length(p_strokes) > 60 then
    raise exception 'bad_strokes';
  end if;

  select count(*) filter (where
           jsonb_typeof(s) <> 'object'
           or jsonb_typeof(s->'c') is distinct from 'number'
           or jsonb_typeof(s->'w') is distinct from 'number'
           or jsonb_typeof(s->'p') is distinct from 'array'
           or (s->>'c')::numeric not between 0 and 5
           or (s->>'w')::numeric not between 1 and 20),
         coalesce(sum(case when jsonb_typeof(s->'p') = 'array'
                           then jsonb_array_length(s->'p') else 0 end), 0)
    into v_bad, v_points
    from jsonb_array_elements(p_strokes) as s;

  if v_bad > 0 or v_points > 3200 then          -- 1600 points = 3200 numbers
    raise exception 'bad_strokes';
  end if;

  if exists (
    select 1
      from jsonb_array_elements(p_strokes) as s,
           jsonb_array_elements(s->'p') as n
     where jsonb_typeof(n) <> 'number' or n::text::numeric not between -5 and 105
  ) then
    raise exception 'bad_strokes';
  end if;

  if jsonb_array_length(p_strokes) = 0 and p_photo is null then
    raise exception 'empty_ornament';
  end if;

  v_name := left(btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', '', 'g')), 16);

  -- the table's check constraints validate everything else (ranges, photo format, sizes)
  insert into ornaments (name, bauble, strokes, photo, x, y, owner_token)
  values (v_name, p_bauble, p_strokes, p_photo, p_x, p_y, v_hash)
  returning id, created_at into v_id, v_at;

  return jsonb_build_object('id', v_id, 'created_at', v_at);
end;
$$;

-- ---------------------------------------------------------------- remove an ornament

create or replace function public.remove_ornament(
  p_id    uuid,
  p_token text default null,
  p_admin text default null
) returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_placeholder constant text := encode(sha256(convert_to('CHANGE-ME', 'UTF8')), 'hex');
  v_admin_hash  text;
  v_count       int;
begin
  -- admin: the secret from the ?admin=... link
  if p_admin is not null and length(p_admin) between 8 and 128 then
    select secret_hash into v_admin_hash from private.tree_admin where id;
    if v_admin_hash is not null
       and v_admin_hash <> v_placeholder
       and v_admin_hash = encode(sha256(convert_to(p_admin, 'UTF8')), 'hex') then
      delete from ornaments where id = p_id;
      get diagnostics v_count = row_count;
      return v_count > 0;
    end if;
  end if;

  -- creator: the random token kept in their browser
  if p_token is not null and length(p_token) between 16 and 128 then
    delete from ornaments
     where id = p_id
       and owner_token = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
    get diagnostics v_count = row_count;
    return v_count > 0;
  end if;

  return false;
end;
$$;

-- ---------------------------------------------------------------- thumbs up

-- One row per (ornament, person). Private: only like_ornament() touches it.
create table if not exists public.ornament_likes (
  ornament_id uuid not null references public.ornaments (id) on delete cascade,
  voter       text not null check (voter ~ '^[0-9a-f]{64}$'),
  created_at  timestamptz not null default now(),
  primary key (ornament_id, voter)
);
alter table public.ornament_likes enable row level security;
revoke all on public.ornament_likes from anon, authenticated;

-- Give (p_on = true) or take back (false) a thumbs up. One per person per
-- ornament. Returns the ornament's new like count.
create or replace function public.like_ornament(
  p_id    uuid,
  p_token text,
  p_on    boolean default true
) returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hash  text;
  v_likes int;
begin
  if p_token is null or length(p_token) < 16 or length(p_token) > 128 then
    raise exception 'bad_token';
  end if;
  v_hash := encode(sha256(convert_to(p_token, 'UTF8')), 'hex');

  if not exists (select 1 from ornaments where id = p_id) then
    return 0;
  end if;

  if coalesce(p_on, true) then
    if (select count(*) from ornament_likes where voter = v_hash) >= 500 then
      raise exception 'too_many_likes';
    end if;
    insert into ornament_likes (ornament_id, voter) values (p_id, v_hash)
    on conflict do nothing;
  else
    delete from ornament_likes where ornament_id = p_id and voter = v_hash;
  end if;

  update ornaments
     set likes = (select count(*) from ornament_likes where ornament_id = p_id)
   where id = p_id
  returning likes into v_likes;

  return coalesce(v_likes, 0);
end;
$$;

revoke all on function public.like_ornament(uuid, text, boolean) from public;
grant execute on function public.like_ornament(uuid, text, boolean) to anon, authenticated;

revoke all on function public.hang_ornament(text, int, jsonb, text, real, real, text) from public;
revoke all on function public.remove_ornament(uuid, text, text) from public;
grant execute on function public.hang_ornament(text, int, jsonb, text, real, real, text) to anon, authenticated;
grant execute on function public.remove_ornament(uuid, text, text) to anon, authenticated;

-- ---------------------------------------------------------------- realtime

-- Broadcast inserts and deletes to every open page.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public' and tablename = 'ornaments') then
    alter publication supabase_realtime add table public.ornaments;
  end if;
end;
$$;

-- ---------------------------------------------------------------- YOUR ADMIN SECRET

-- Admin removal stays switched off until you set a secret. Do NOT edit this
-- file to do it. After running this file, run this one statement in the SQL
-- Editor with your own secret (8-128 letters and numbers) in the quotes:
--
--   update private.tree_admin
--   set secret_hash = encode(sha256(convert_to('YOUR-SECRET-HERE', 'UTF8')), 'hex');
--
-- Your admin link is then:  https://<your site>/?admin=<that secret>
-- Re-running this file later keeps the secret you already set.
insert into private.tree_admin (id, secret_hash)
values (true, encode(sha256(convert_to('CHANGE-ME', 'UTF8')), 'hex'))
on conflict (id) do nothing;
