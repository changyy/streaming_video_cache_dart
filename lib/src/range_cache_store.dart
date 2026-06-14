import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'cache_store.dart';

class _Entry {
  _Entry(this.dirName);
  final String dirName;
  int? totalLength;
  final Set<int> chunks = <int>{};
  int bytes = 0;
  int lastAccess = 0;
}

/// Fixed-size, chunked, byte-range disk cache with an LRU size cap.
///
/// Each entry (keyed by an arbitrary [String]) stores media as fixed-size
/// chunks under `<directory>/<encodedKey>/c<index>`, plus `meta.json` holding
/// the known total length and a last-access counter. A chunk file is either
/// fully present or absent — written atomically (`.part` → rename) — so a
/// present chunk is always complete.
///
/// The store never fetches anything itself; [VideoCacheServer] fills it. It
/// persists/serves chunks and evicts least-recently-used ENTRIES once total
/// bytes exceed [maxBytes]. Pinned keys are never evicted (let a consumer keep
/// the current playlist resident). `maxBytes <= 0` disables eviction.
///
/// This is the default [CacheStore]; implement [CacheStore] yourself for a
/// different backend (in-memory, encrypted, …).
class RangeCacheStore implements CacheStore {
  RangeCacheStore({
    required this.directory,
    required this.maxBytes,
    this.chunkSize = 1 << 20, // 1 MiB
  }) : assert(chunkSize > 0);

  final Directory directory;
  final int maxBytes;
  @override
  final int chunkSize;

  final Map<String, _Entry> _entries = <String, _Entry>{};
  final Set<String> _pinned = <String>{};
  int _clock = 0;

  static String _encodeKey(String key) =>
      base64Url.encode(utf8.encode(key)).replaceAll('=', '');

  String _dirName(String key) => _encodeKey(key);
  String _entryPath(String key) => '${directory.path}/${_dirName(key)}';
  String _chunkPath(String key, int index) => '${_entryPath(key)}/c$index';
  String _metaPath(String key) => '${_entryPath(key)}/meta.json';

  /// Loads any previously-cached entries from disk. Best-effort.
  Future<void> init() async {
    _entries.clear();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
      return;
    }
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final dirName = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final entry = _Entry(dirName);
        try {
          await for (final f in entity.list(followLinks: false)) {
            if (f is! File) continue;
            final name = f.uri.pathSegments.last;
            if (name.startsWith('c')) {
              final idx = int.tryParse(name.substring(1));
              if (idx == null) continue;
              entry.chunks.add(idx);
              entry.bytes += await f.length();
            } else if (name == 'meta.json') {
              try {
                final meta =
                    jsonDecode(await f.readAsString()) as Map<String, dynamic>;
                entry.totalLength = (meta['totalLength'] as num?)?.toInt();
                entry.lastAccess = (meta['lastAccess'] as num?)?.toInt() ?? 0;
              } catch (_) {}
            }
          }
        } catch (_) {}
        _entries[dirName] = entry;
        if (entry.lastAccess > _clock) _clock = entry.lastAccess;
      }
    } catch (_) {}
    _clock++;
  }

  int get usedBytes => _entries.values.fold<int>(0, (sum, e) => sum + e.bytes);

  @override
  CacheUsage usage() => CacheUsage(
    usedBytes: usedBytes,
    maxBytes: maxBytes,
    entryCount: _entries.length,
  );

  _Entry _entryFor(String key) =>
      _entries.putIfAbsent(_dirName(key), () => _Entry(_dirName(key)));

  /// Total media length for [key] (from upstream Content-Range), or null.
  @override
  int? totalLength(String key) => _entries[_dirName(key)]?.totalLength;

  @override
  Future<void> setTotalLength(String key, int length) async {
    final entry = _entryFor(key);
    if (entry.totalLength == length) return;
    entry.totalLength = length;
    await _persistMeta(key, entry);
  }

  @override
  bool hasChunk(String key, int index) =>
      _entries[_dirName(key)]?.chunks.contains(index) ?? false;

  /// Reads chunk [index] for [key], or null if absent. Touches the entry.
  @override
  Future<Uint8List?> readChunk(String key, int index) async {
    final entry = _entries[_dirName(key)];
    if (entry == null || !entry.chunks.contains(index)) return null;
    try {
      final bytes = await File(_chunkPath(key, index)).readAsBytes();
      _touch(entry);
      return bytes;
    } catch (_) {
      // File vanished under us — forget it so it can be re-fetched.
      entry.chunks.remove(index);
      return null;
    }
  }

  /// Stores chunk [index] for [key] (atomic), then enforces the LRU cap.
  @override
  Future<void> putChunk(String key, int index, List<int> bytes) async {
    final entry = _entryFor(key);
    final dir = Directory(_entryPath(key));
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final part = File('${_chunkPath(key, index)}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(_chunkPath(key, index));
      if (!entry.chunks.contains(index)) {
        entry.chunks.add(index);
        entry.bytes += bytes.length;
      }
      _touch(entry);
      await _persistMeta(key, entry);
      await _enforceLru(protect: _dirName(key));
    } catch (_) {
      // best-effort
    }
  }

  /// Keep [keys] resident (never evicted) until the next [pin] call.
  @override
  void pin(Iterable<String> keys) {
    _pinned
      ..clear()
      ..addAll(keys.map(_dirName));
  }

  @override
  Future<void> evictKey(String key) async {
    final dirName = _dirName(key);
    _entries.remove(dirName);
    try {
      final dir = Directory('${directory.path}/$dirName');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    _entries.clear();
    try {
      if (await directory.exists()) {
        await for (final e in directory.list(followLinks: false)) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _touch(_Entry entry) => entry.lastAccess = ++_clock;

  Future<void> _persistMeta(String key, _Entry entry) async {
    try {
      await File(_metaPath(key)).writeAsString(
        jsonEncode(<String, dynamic>{
          'totalLength': entry.totalLength,
          'lastAccess': entry.lastAccess,
        }),
        flush: false,
      );
    } catch (_) {}
  }

  /// Evicts least-recently-used, non-pinned entries until usage is within the
  /// cap. [protect] is the entry currently being written (never evicted this
  /// pass). No-op when [maxBytes] <= 0.
  Future<void> _enforceLru({String? protect}) async {
    if (maxBytes <= 0) return;
    while (usedBytes > maxBytes) {
      _Entry? victim;
      for (final e in _entries.values) {
        if (e.dirName == protect || _pinned.contains(e.dirName)) continue;
        if (victim == null || e.lastAccess < victim.lastAccess) victim = e;
      }
      if (victim == null) break; // nothing evictable (all pinned/protected)
      _entries.remove(victim.dirName);
      try {
        final dir = Directory('${directory.path}/${victim.dirName}');
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    }
  }
}
