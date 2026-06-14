import 'dart:typed_data';

/// Snapshot of cache usage for diagnostics.
class CacheUsage {
  const CacheUsage({
    required this.usedBytes,
    required this.maxBytes,
    required this.entryCount,
  });

  final int usedBytes;
  final int maxBytes;
  final int entryCount;

  @override
  String toString() =>
      'CacheUsage(${usedBytes ~/ 1024} KiB / ${maxBytes ~/ 1024} KiB, '
      '$entryCount entries)';
}

/// Storage backend for [VideoCacheServer], addressed in fixed-size chunks.
///
/// The server is storage-agnostic: it only speaks "chunk N of key K". Implement
/// this to back the cache with anything (the default [RangeCacheStore] uses
/// on-disk files; you could provide an in-memory, encrypted, or custom store).
/// A chunk is either fully present or absent.
abstract class CacheStore {
  /// Fixed chunk size in bytes. The server aligns upstream fetches to it.
  int get chunkSize;

  bool hasChunk(String key, int index);

  /// Bytes of chunk [index] for [key], or null if absent.
  Future<Uint8List?> readChunk(String key, int index);

  /// Stores chunk [index] for [key]; the store enforces its own size policy.
  Future<void> putChunk(String key, int index, List<int> bytes);

  /// Known total media length for [key] (from upstream), or null.
  int? totalLength(String key);

  Future<void> setTotalLength(String key, int length);

  /// Keep [keys] resident (never evicted) — typically the current playlist.
  void pin(Iterable<String> keys);

  CacheUsage usage();

  Future<void> evictKey(String key);

  Future<void> clear();
}
