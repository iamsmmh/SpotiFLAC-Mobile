-- SpotiFLAC self-hosted sync server — reference PostgreSQL schema.
--
-- Implements the contract in docs/API_CONTRACTS.md for the
-- `SelfHostedSyncAdapter` (and, with Supabase's PostgREST layer, for
-- `SupabaseSyncAdapter`). Apply with:
--
--     psql "$DATABASE_URL" -f server/schema.sql
--
-- Row Level Security assumes Supabase-style `auth.uid()`; on a plain Postgres
-- deployment replace it with your own session variable.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Migration bookkeeping (mirrors docs/MIGRATIONS.md)
-- ---------------------------------------------------------------------------
create table if not exists schema_migrations (
  version    integer primary key,
  applied_at timestamptz not null default now(),
  description text
);

insert into schema_migrations (version, description)
values (1, 'initial sync schema')
on conflict (version) do nothing;

-- ---------------------------------------------------------------------------
-- Sync records — one row per (user, scope, record)
-- ---------------------------------------------------------------------------
create table if not exists sync_records (
  user_id    uuid not null,
  scope      text not null check (scope in (
               'favorites', 'playlists', 'settings', 'history',
               'queueState', 'downloadPreferences', 'podcasts', 'social')),
  record_id  text not null,
  revision   bigint not null default 1,
  updated_at timestamptz not null default now(),
  deleted    boolean not null default false,
  payload    jsonb not null default '{}'::jsonb,
  primary key (user_id, scope, record_id)
);

create index if not exists sync_records_revision_idx
  on sync_records (user_id, scope, revision);

-- Optimistic concurrency: a push only lands when it is at least as new as what
-- the server already holds. The client's conflict resolution is the authority,
-- this is a safety net against a replayed outbox entry.
create or replace function sync_records_bump_revision() returns trigger
language plpgsql as $$
begin
  if new.revision <= old.revision then
    new.revision := old.revision + 1;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists sync_records_bump on sync_records;
create trigger sync_records_bump before update on sync_records
  for each row execute function sync_records_bump_revision();

-- ---------------------------------------------------------------------------
-- Podcast subscriptions (Feature Group 9) — server-side mirror
-- ---------------------------------------------------------------------------
create table if not exists podcast_subscriptions (
  user_id       uuid not null,
  feed_url      text not null,
  title         text not null,
  author        text not null default '',
  image_url     text,
  auto_download boolean not null default false,
  keep_episodes integer not null default 3,
  notify_new    boolean not null default true,
  added_at      timestamptz not null default now(),
  last_checked_at timestamptz,
  primary key (user_id, feed_url)
);

create table if not exists podcast_episode_progress (
  user_id        uuid not null,
  feed_url       text not null,
  episode_guid   text not null,
  played_seconds integer not null default 0,
  is_played      boolean not null default false,
  updated_at     timestamptz not null default now(),
  primary key (user_id, feed_url, episode_guid)
);

-- ---------------------------------------------------------------------------
-- Optional social layer (Feature Group 11)
-- ---------------------------------------------------------------------------
create table if not exists social_profiles (
  user_id     uuid primary key,
  handle      text unique not null,
  display_name text,
  avatar_url  text,
  is_public   boolean not null default false,
  updated_at  timestamptz not null default now()
);

create table if not exists social_follows (
  follower_id uuid not null,
  followee_id uuid not null,
  created_at  timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

create table if not exists shared_playlists (
  share_id     uuid primary key default gen_random_uuid(),
  owner_id     uuid not null,
  playlist_id  text not null,
  title        text not null,
  description  text not null default '',
  track_keys   jsonb not null default '[]'::jsonb,
  is_public    boolean not null default false,
  published_at timestamptz not null default now()
);

create index if not exists shared_playlists_owner_idx
  on shared_playlists (owner_id, published_at desc);

-- ---------------------------------------------------------------------------
-- Row Level Security (Supabase / Postgres with auth.uid())
-- ---------------------------------------------------------------------------
alter table sync_records              enable row level security;
alter table podcast_subscriptions     enable row level security;
alter table podcast_episode_progress  enable row level security;
alter table social_follows            enable row level security;
alter table shared_playlists          enable row level security;

-- Replace `auth.uid()` with your own session accessor when self-hosting outside
-- Supabase (e.g. `current_setting('request.jwt.claim.sub', true)::uuid`).
do $$
declare
  tbl text;
begin
  foreach tbl in array array[
    'sync_records', 'podcast_subscriptions', 'podcast_episode_progress'
  ]
  loop
    execute format('drop policy if exists own_rows on %I', tbl);
    execute format(
      'create policy own_rows on %I for all using (user_id = auth.uid()) with check (user_id = auth.uid())',
      tbl);
  end loop;
end;
$$;

drop policy if exists public_profiles on social_profiles;
create policy public_profiles on social_profiles
  for select using (is_public or user_id = auth.uid());

drop policy if exists own_follows on social_follows;
create policy own_follows on social_follows
  for all using (follower_id = auth.uid()) with check (follower_id = auth.uid());

drop policy if exists readable_playlists on shared_playlists;
create policy readable_playlists on shared_playlists
  for select using (is_public or owner_id = auth.uid());

drop policy if exists own_playlists on shared_playlists;
create policy own_playlists on shared_playlists
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
