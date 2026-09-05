# Ecosystem migrations

## How migrations run

`EcosystemDatabase` opens `ecosystem.db` with the shared helper
`services/sqlite_helpers.dart`. Migrations are **data**, not code branches:

```dart
const List<EcosystemMigration> ecosystemMigrations = [ ... ];

List<EcosystemMigration> migrationsBetween(int from, int to);
```

* **Fresh install** → `onCreate` replays `migrationsBetween(0, version)`.
* **Upgrade** → `onUpgrade` first re-runs the full v1 schema (every statement is
  `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`, so this is a
  no-op on an existing database and repairs one that was written by an
  intermediate build), then replays `migrationsBetween(oldVersion, newVersion)`.

That combination makes every migration **idempotent and resumable**: a crash
half-way through simply re-runs the remaining statements on the next launch.

Rules for adding a migration:

1. append a new `EcosystemMigration(fromVersion: current, toVersion: current + 1, …)`;
2. bump `ecosystemDatabaseVersion`;
3. only use idempotent DDL (`IF NOT EXISTS`) and `ALTER TABLE … ADD COLUMN` with
   a default — SQLite cannot drop or rename columns portably;
4. one statement per list entry (`Database.execute` does not run batches);
5. never use `ON CONFLICT … DO UPDATE` (Android API 24 ships SQLite 3.9);
6. add a case to `test/ecosystem_migrations_test.dart` if the new step has
   behaviour worth pinning.

## Plan

| From → To | Description |
|---|---|
| 0 → 1 | Initial schema: history, favorite playlists, stream cache, podcasts, recognition, offline collections, smart-playlist state, social cache, account mirror, sync tombstones, metadata |
| 1 → 2 | Podcast episode progress + download bookkeeping; completion index on listening events |
| 2 → 3 | Per-collection network policy for offline collections; stream-cache completion + source URL |
| 3 → 4 | Podcast retention/notification policy; smart-playlist materialization results |

## Verifying

```bash
flutter test test/ecosystem_migrations_test.dart
```

The test asserts that the plan is contiguous (no gaps, no duplicate steps),
that every statement is a single idempotent DDL statement, and that v1 creates
every table the modules use.

## Roll-forward only

There is no downgrade path: a downgrade keeps the newer database file and simply
ignores unknown columns (SQLite ignores `SELECT *` extras it does not map).
Because every column added after v1 has a `NOT NULL DEFAULT`, an older build
reading a newer database still works.

## Server-side

`server/schema.sql` is the PostgreSQL equivalent for self-hosted deployments.
It is versioned the same way (`schema_migrations` table) so client and server
can be rolled out independently.
