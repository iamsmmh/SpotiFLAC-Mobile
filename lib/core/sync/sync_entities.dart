/// Cloud-sync domain entities (Phase 6).
///
/// Pure domain values: no Flutter, no platform channels, no I/O — the same
/// dependency rule as `core/domain/entities.dart`. Sync providers
/// (Firebase / Supabase / self-hosted) adapt these types to their wire
/// format; the orchestrator only ever sees [SyncRecord]s.
library;

/// Data domains that can be synchronized.
enum SyncScope {
  favorites,
  playlists,
  settings,
  history;

  /// Stable wire id. Used in provider documents/rows — never rename.
  String get wireId => name;
}

/// One versioned record inside a [SyncScope].
///
/// Conflict model is last-write-wins on [updatedAt] with [revision] as the
/// deterministic tie-breaker; deletions are explicit tombstones
/// ([deleted] == true) so a wiped record beats any stale replica.
class SyncRecord {
  const SyncRecord({
    required this.scope,
    required this.recordId,
    required this.revision,
    required this.updatedAt,
    this.payload = const <String, Object?>{},
    this.deleted = false,
  });

  final SyncScope scope;

  /// Stable identity within the scope (e.g., collection key `isrc:XXXX` or
  /// playlist id). Must be deterministic across devices for merging to work.
  final String recordId;

  /// Monotonic per-record version from the *writing* side. Compared only
  /// when [updatedAt] ties (same-millisecond writes on two devices).
  final int revision;

  /// UTC timestamp of the write that produced this version.
  final DateTime updatedAt;

  /// Opaque provider payload. The orchestrator never interprets it; scope
  /// owners (favorites service, playlist service, …) own encode/decode.
  final Map<String, Object?> payload;

  /// Tombstone: the record was deleted at [updatedAt].
  final bool deleted;

  SyncRecord copyWith({
    int? revision,
    DateTime? updatedAt,
    Map<String, Object?>? payload,
    bool? deleted,
  }) {
    return SyncRecord(
      scope: scope,
      recordId: recordId,
      revision: revision ?? this.revision,
      updatedAt: updatedAt ?? this.updatedAt,
      payload: payload ?? this.payload,
      deleted: deleted ?? this.deleted,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'scope': scope.wireId,
    'recordId': recordId,
    'revision': revision,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'deleted': deleted,
    'payload': payload,
  };

  static SyncRecord? tryParse(Map<String, Object?> json) {
    final scopeName = json['scope']?.toString();
    final recordId = json['recordId']?.toString();
    final updatedAtRaw = json['updatedAt']?.toString();
    if (scopeName == null || recordId == null || updatedAtRaw == null) {
      return null;
    }
    SyncScope? scope;
    for (final candidate in SyncScope.values) {
      if (candidate.wireId == scopeName) {
        scope = candidate;
        break;
      }
    }
    final updatedAt = DateTime.tryParse(updatedAtRaw);
    if (scope == null || updatedAt == null) return null;
    final payloadRaw = json['payload'];
    return SyncRecord(
      scope: scope,
      recordId: recordId,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      updatedAt: updatedAt.toUtc(),
      deleted: json['deleted'] == true,
      payload: payloadRaw is Map
          ? Map<String, Object?>.from(payloadRaw)
          : const <String, Object?>{},
    );
  }

  @override
  String toString() =>
      'SyncRecord(${scope.wireId}:$recordId rev=$revision '
      '${deleted ? 'deleted ' : ''}at=${updatedAt.toIso8601String()})';
}

/// Outcome class of a record-vs-record comparison.
enum SyncConflictWinner { local, remote, identical }

/// Signed-in account identity exposed by a [CloudSyncProvider].
class UserProfile {
  const UserProfile({
    required this.userId,
    required this.providerId,
    this.displayName,
    this.avatarUrl,
    this.email,
  });

  final String userId;
  final String providerId;
  final String? displayName;
  final String? avatarUrl;
  final String? email;

  @override
  String toString() => 'UserProfile($providerId:$userId)';
}

/// High-level state of the sync pipeline, surfaced to the UI.
enum SyncStatus {
  /// No provider configured (default): sync is inert by design.
  disabled,

  /// Provider configured, waiting for sign-in.
  signedOut,

  /// Signed in, nothing in flight.
  idle,

  /// Push or pull currently running.
  syncing,

  /// Last cycle failed; the outbox is retained and retried next cycle.
  error,
}

/// Immutable view consumed by the UI/settings page.
class SyncSnapshot {
  const SyncSnapshot({
    required this.status,
    this.user,
    this.lastSyncAt,
    this.pendingOutboxCount = 0,
    this.lastError,
  });

  final SyncStatus status;
  final UserProfile? user;
  final DateTime? lastSyncAt;
  final int pendingOutboxCount;
  final String? lastError;

  bool get isActive =>
      status == SyncStatus.idle ||
      status == SyncStatus.syncing ||
      status == SyncStatus.error;

  SyncSnapshot copyWith({
    SyncStatus? status,
    Object? user = _unset,
    Object? lastSyncAt = _unset,
    int? pendingOutboxCount,
    Object? lastError = _unset,
  }) {
    return SyncSnapshot(
      status: status ?? this.status,
      user: identical(user, _unset) ? this.user : user as UserProfile?,
      lastSyncAt: identical(lastSyncAt, _unset)
          ? this.lastSyncAt
          : lastSyncAt as DateTime?,
      pendingOutboxCount: pendingOutboxCount ?? this.pendingOutboxCount,
      lastError: identical(lastError, _unset)
          ? this.lastError
          : lastError as String?,
    );
  }
}

const Object _unset = Object();
