# Ecosystem database schema

`ecosystem.db` — a dedicated SQLite file opened with the shared helper
`services/sqlite_helpers.dart` (WAL, `synchronous=NORMAL`, 5 s busy timeout),
version **4**.

It is deliberately separate from the four pre-existing stores:

| File | Owned by | Untouched by the ecosystem |
|---|---|---|
| `app_state.db` | download queue, recents, playback session | ✅ |
| `library.db` | local library ledger | ✅ |
| `collections.db` | wishlist/loved/playlists/favorite artists+albums | ✅ (read-only projection) |
| `history.db` | download history | ✅ |
| **`ecosystem.db`** | **all new ecosystem tables** | — |

Conventions: timestamps are ISO-8601 UTC strings, booleans are `0/1` integers,
all tables are created with `IF NOT EXISTS` so an interrupted migration resumes.

> Android API 24 ships SQLite 3.9, so **no `ON CONFLICT … DO UPDATE`** is used
> anywhere: aggregates are maintained with an explicit read-modify-write inside
> a transaction.

## Tables

```sql
CREATE TABLE IF NOT EXISTS ec_listening_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  track_key TEXT NOT NULL,
  title TEXT NOT NULL,
  artist TEXT NOT NULL DEFAULT '',
  album TEXT NOT NULL DEFAULT '',
  cover_url TEXT,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  played_ms INTEGER NOT NULL DEFAULT 0,
  completed INTEGER NOT NULL DEFAULT 0,
  skipped INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'unknown',
  started_at TEXT NOT NULL,
  ended_at TEXT
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_track_history (
  track_key TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  artist TEXT NOT NULL DEFAULT '',
  album TEXT NOT NULL DEFAULT '',
  cover_url TEXT,
  play_count INTEGER NOT NULL DEFAULT 0,
  skip_count INTEGER NOT NULL DEFAULT 0,
  total_played_ms INTEGER NOT NULL DEFAULT 0,
  completion_sum REAL NOT NULL DEFAULT 0,
  completion_count INTEGER NOT NULL DEFAULT 0,
  first_played_at TEXT NOT NULL,
  last_played_at TEXT NOT NULL
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_favorite_playlists (
  playlist_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  cover_path TEXT,
  track_count INTEGER NOT NULL DEFAULT 0,
  added_at TEXT NOT NULL
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_stream_cache (
  cache_key TEXT PRIMARY KEY,
  track_key TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  artist TEXT NOT NULL DEFAULT '',
  file_name TEXT NOT NULL,
  audio_format TEXT NOT NULL DEFAULT 'unknown',
  bytes INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  source_url TEXT,
  created_at TEXT NOT NULL,
  last_accessed_at TEXT NOT NULL,
  access_count INTEGER NOT NULL DEFAULT 0,
  pinned INTEGER NOT NULL DEFAULT 0,
  complete INTEGER NOT NULL DEFAULT 0
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_podcast_subscriptions (
  feed_url TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  author TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  image_url TEXT,
  categories TEXT NOT NULL DEFAULT '',
  added_at TEXT NOT NULL,
  last_checked_at TEXT,
  auto_download INTEGER NOT NULL DEFAULT 0,
  keep_episodes INTEGER NOT NULL DEFAULT 3,
  notify_new INTEGER NOT NULL DEFAULT 1
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_podcast_episodes (
  episode_key TEXT PRIMARY KEY,
  feed_url TEXT NOT NULL,
  guid TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  audio_url TEXT NOT NULL,
  image_url TEXT,
  duration_seconds INTEGER NOT NULL DEFAULT 0,
  published_at TEXT,
  file_path TEXT,
  played_seconds INTEGER NOT NULL DEFAULT 0,
  is_played INTEGER NOT NULL DEFAULT 0,
  download_state TEXT NOT NULL DEFAULT 'none',
  added_at TEXT NOT NULL
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_recognition_history (
  result_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  artist TEXT NOT NULL DEFAULT '',
  album TEXT NOT NULL DEFAULT '',
  provider_id TEXT NOT NULL DEFAULT '',
  confidence REAL NOT NULL DEFAULT 0,
  identified_at TEXT NOT NULL,
  payload_json TEXT NOT NULL DEFAULT '{}'
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_offline_collections (
  collection_key TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  track_count INTEGER NOT NULL DEFAULT 0,
  auto_sync INTEGER NOT NULL DEFAULT 1,
  wifi_only INTEGER NOT NULL DEFAULT 1,
  last_synced_at TEXT,
  added_at TEXT NOT NULL
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_smart_playlist_state (
  playlist_id TEXT PRIMARY KEY,
  definition_json TEXT NOT NULL,
  last_materialized_at TEXT,
  last_track_count INTEGER NOT NULL DEFAULT 0
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_social_cache (
  cache_key TEXT PRIMARY KEY,
  payload_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_account_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  provider_id TEXT NOT NULL DEFAULT '',
  user_id TEXT NOT NULL DEFAULT '',
  email TEXT NOT NULL DEFAULT '',
  display_name TEXT NOT NULL DEFAULT '',
  avatar_url TEXT,
  is_guest INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_sync_tombstones (
  scope TEXT NOT NULL,
  record_id TEXT NOT NULL,
  deleted_at TEXT NOT NULL,
  PRIMARY KEY (scope, record_id)
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)
```

## Indexes

* `CREATE INDEX IF NOT EXISTS idx_ec_favorite_playlists_added ON ec_favorite_playlists(added_at DESC)`
* `CREATE INDEX IF NOT EXISTS idx_ec_listening_events_started ON ec_listening_events(started_at DESC)`
* `CREATE INDEX IF NOT EXISTS idx_ec_listening_events_track ON ec_listening_events(track_key)`
* `CREATE INDEX IF NOT EXISTS idx_ec_podcast_episodes_feed ON ec_podcast_episodes(feed_url, published_at DESC)`
* `CREATE INDEX IF NOT EXISTS idx_ec_podcast_episodes_played ON ec_podcast_episodes(is_played)`
* `CREATE INDEX IF NOT EXISTS idx_ec_recognition_history_time ON ec_recognition_history(identified_at DESC)`
* `CREATE INDEX IF NOT EXISTS idx_ec_stream_cache_lru ON ec_stream_cache(last_accessed_at ASC)`
* `CREATE INDEX IF NOT EXISTS idx_ec_stream_cache_track ON ec_stream_cache(track_key)`
* `CREATE INDEX IF NOT EXISTS idx_ec_track_history_last ON ec_track_history(last_played_at DESC)`
* `CREATE INDEX IF NOT EXISTS idx_ec_track_history_plays ON ec_track_history(play_count DESC)`

## Key conventions

* **Identity.** Favorite/sync records use stable, provider-namespaced keys
  (`isrc:USRC17607839`, `qobuz:albumId`, `playlist:<uuid>`). A key is never
  derived from a title, so renaming a track cannot orphan its history.
* **Aggregates.** `ec_track_history` is derived data: it can always be rebuilt
  from `ec_listening_events` (`completion_sum / completion_count` is the average
  completion).
* **Secrets.** No token ever lands here. `ec_account_state` holds only the
  non-secret profile mirror; tokens live in the platform keystore.
* **Sync bookkeeping.** `ec_sync_tombstones` records deletions that must
  propagate to other devices even after the local row is gone.

## Server-side schema

For a self-hosted/Supabase deployment, `server/schema.sql` contains an
equivalent PostgreSQL schema (including RLS policies) implementing the same
contract.
