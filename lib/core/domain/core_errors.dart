/// Normalized error taxonomy shared by every core layer.
///
/// Stage 2 rule: errors crossing a layer boundary (native channel, gomobile
/// bridge, FFmpeg process, plugin runtime) are normalized into [CoreError]
/// exactly once — at the layer that caught them — so the queue engine, the UI,
/// and tests never pattern-match on raw platform exceptions.
library;

/// Coarse category of a normalized core failure.
///
/// Categories drive retry policy, provider priority switching, and the
/// user-facing recovery hint; they deliberately hide whether the failure came
/// from Kotlin, Swift, Go, or Dart.
enum CoreErrorCategory {
  /// Connectivity, DNS, TLS, timeouts. Retryable by default.
  network,

  /// Destination not writable, disk full, temp/commit failure.
  storage,

  /// SAF grant revoked, iOS bookmark expired, OS-level denial.
  permission,

  /// Track/source no longer available upstream.
  notFound,

  /// Provider throttling; retryable after backoff.
  rateLimited,

  /// SHA-256 mismatch or implausible file contents after transfer.
  integrity,

  /// Unsupported container/codec or malformed payload decoding.
  format,

  /// Dynamic extension/provider failure (JS runtime, plugin error).
  provider,

  /// Cooperative cancellation honoured (user cancel, pause, shutdown).
  cancelled,

  /// Anything not covered above.
  unknown,
}

/// Whether failures of [category] are worth retrying with backoff.
bool coreCategoryIsRetryable(CoreErrorCategory category) {
  return switch (category) {
    CoreErrorCategory.network || CoreErrorCategory.rateLimited => true,
    CoreErrorCategory.storage ||
    CoreErrorCategory.permission ||
    CoreErrorCategory.notFound ||
    CoreErrorCategory.integrity ||
    CoreErrorCategory.format ||
    CoreErrorCategory.provider ||
    CoreErrorCategory.cancelled ||
    CoreErrorCategory.unknown => false,
  };
}

/// Immutable, normalized failure description crossing core layer boundaries.
class CoreError implements Exception {
  const CoreError({
    required this.category,
    required this.message,
    this.providerId,
    this.cause,
    bool? retryable,
  }) : retryableOverride = retryable;

  /// Which subsystem produced the failure.
  final CoreErrorCategory category;

  /// Human-readable, redaction-safe description.
  final String message;

  /// Originating provider/extension when the failure is provider-scoped.
  final String? providerId;

  /// The raw error this was normalized from (kept for diagnostics/logs only;
  /// UI and scheduling must key off [category], never on [cause] types).
  final Object? cause;

  /// Explicit retryability override. When null, [isRetryable] derives from
  /// [category] via [coreCategoryIsRetryable].
  final bool? retryableOverride;

  bool get isRetryable => retryableOverride ?? coreCategoryIsRetryable(category);

  CoreError copyWith({
    CoreErrorCategory? category,
    String? message,
    Object? providerId = _sentinel,
    Object? cause = _sentinel,
    Object? retryable = _sentinel,
  }) {
    return CoreError(
      category: category ?? this.category,
      message: message ?? this.message,
      providerId: identical(providerId, _sentinel)
          ? this.providerId
          : providerId as String?,
      cause: identical(cause, _sentinel) ? this.cause : cause,
      retryable: identical(retryable, _sentinel)
          ? retryableOverride
          : retryable as bool?,
    );
  }

  @override
  String toString() {
    final provider = providerId == null ? '' : ' [$providerId]';
    return 'CoreError(${category.name})$provider: $message';
  }
}

const Object _sentinel = Object();

/// Aggregated failure raised when every dynamic provider in the priority
/// chain rejected the request. Carries the per-provider failures so the queue
/// can surface the most actionable one instead of an opaque "all failed".
class ExtensionExhaustedError extends CoreError {
  ExtensionExhaustedError({
    required List<CoreError> failures,
    required String message,
  }) : failures = List.unmodifiable(failures),
       super(
         category: _dominantCategory(failures),
         message: message,
         retryable: failures.any((f) => f.isRetryable),
       );

  /// One normalized entry per provider attempt that failed, in priority order.
  final List<CoreError> failures;

  static CoreErrorCategory _dominantCategory(List<CoreError> failures) {
    // Permission beats everything: more retries against an unauthenticated
    // or revoked provider are pointless until the user re-auths.
    for (final failure in failures) {
      if (failure.category == CoreErrorCategory.permission) {
        return CoreErrorCategory.permission;
      }
    }
    for (final failure in failures) {
      if (failure.category == CoreErrorCategory.rateLimited) {
        return CoreErrorCategory.rateLimited;
      }
    }
    return failures.isEmpty
        ? CoreErrorCategory.provider
        : failures.first.category;
  }
}

/// Maps backend/`error_type`-style strings to a [CoreErrorCategory].
///
/// Pure re-derivation of the legacy `isStorageWriteFailure` policy so both
/// the old queue and the new engine agree on storage classification, widened
/// to the full taxonomy. Matching is intentionally conservative: an
/// unrecognized combination stays [CoreErrorCategory.unknown] rather than
/// being mislabeled retryable.
CoreErrorCategory coreCategoryForBackendError({
  Object? errorType,
  Object? errorMessage,
}) {
  final type = errorType?.toString().trim().toLowerCase() ?? '';
  final message = errorMessage?.toString().trim().toLowerCase() ?? '';

  if (type == 'permission' || type == 'permission_denied') {
    return CoreErrorCategory.permission;
  }
  if (type == 'cancelled' || type == 'canceled' || type == 'aborted') {
    return CoreErrorCategory.cancelled;
  }
  if (type == 'not_found' || type == 'notfound') {
    return CoreErrorCategory.notFound;
  }
  if (type == 'rate_limit' ||
      type == 'ratelimit' ||
      type == 'rate_limited' ||
      type == 'too_many_requests') {
    return CoreErrorCategory.rateLimited;
  }
  if (type == 'network' ||
      type == 'timeout' ||
      type == 'dns' ||
      type == 'connection') {
    return CoreErrorCategory.network;
  }
  if (type == 'storage' ||
      type == 'disk_full' ||
      type == 'out_of_space' ||
      type == 'write_failed') {
    return CoreErrorCategory.storage;
  }
  if (type == 'integrity' || type == 'checksum' || type == 'corrupt') {
    return CoreErrorCategory.integrity;
  }
  if (type == 'not_supported' || type == 'unsupported_format') {
    return CoreErrorCategory.format;
  }
  if (type == 'extension' || type == 'js_exception' || type == 'runtime') {
    return CoreErrorCategory.provider;
  }

  if (message.isEmpty) return CoreErrorCategory.unknown;

  if (message.contains('saf permission') ||
      message.contains('permission') && message.contains('denied') ||
      message.contains('eacces')) {
    return CoreErrorCategory.permission;
  }
  if (message.contains('cancel')) {
    return CoreErrorCategory.cancelled;
  }
  if (message.contains('no space') ||
      message.contains('enospc') ||
      message.contains('not writable') ||
      message.contains('read-only file system') ||
      message.contains('failed to write')) {
    return CoreErrorCategory.storage;
  }
  if (message.contains('not found') || message.contains('404')) {
    return CoreErrorCategory.notFound;
  }
  if (message.contains('429') || message.contains('rate limit')) {
    return CoreErrorCategory.rateLimited;
  }
  if (message.contains('checksum') ||
      message.contains('sha-256') ||
      message.contains('sha256') ||
      message.contains('corrupt')) {
    return CoreErrorCategory.integrity;
  }
  if (message.contains('timed out') ||
      message.contains('timeout') ||
      message.contains('socket') ||
      message.contains('connection reset') ||
      message.contains('connection refused') ||
      message.contains('network')) {
    return CoreErrorCategory.network;
  }
  return CoreErrorCategory.unknown;
}

/// Normalizes any thrown object into a [CoreError].
///
/// Importantly this runs at layer boundaries *after* platform-specific
/// mapping happened (the data layer remaps `PlatformException` codes first).
/// [CoreError]s pass through untouched so normalization stays idempotent.
CoreError normalizeCoreError(
  Object error, {
  String? providerId,
  CoreErrorCategory fallback = CoreErrorCategory.unknown,
  String? fallbackMessage,
}) {
  if (error is CoreError) {
    if (providerId != null && error.providerId == null) {
      return error.copyWith(providerId: providerId);
    }
    return error;
  }
  final description = fallbackMessage ?? error.toString();
  return CoreError(
    category: fallback,
    message: description,
    providerId: providerId,
    cause: error,
  );
}
