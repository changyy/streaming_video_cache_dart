import 'dart:io';
import 'dart:typed_data';

import 'package:streaming_video_cache/streaming_video_cache.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('range_cache_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Uint8List bytes(int n, [int fill = 0]) =>
      Uint8List.fromList(List<int>.filled(n, fill));

  test('stores and reads a chunk; reports usage', () async {
    final store = RangeCacheStore(
      directory: dir,
      maxBytes: 10 << 20,
      chunkSize: 1024,
    );
    await store.init();
    expect(store.hasChunk('a', 0), isFalse);

    await store.putChunk('a', 0, bytes(1024, 7));
    expect(store.hasChunk('a', 0), isTrue);
    final read = await store.readChunk('a', 0);
    expect(read, isNotNull);
    expect(read!.length, 1024);
    expect(read.every((b) => b == 7), isTrue);
    expect(store.usage().usedBytes, 1024);
  });

  test('readChunk returns null for an absent chunk', () async {
    final store = RangeCacheStore(directory: dir, maxBytes: 0, chunkSize: 1024);
    await store.init();
    expect(await store.readChunk('missing', 3), isNull);
  });

  test('persists chunks + total length across re-init (restart)', () async {
    final a = RangeCacheStore(directory: dir, maxBytes: 0, chunkSize: 1024);
    await a.init();
    await a.putChunk('vid', 0, bytes(1024));
    await a.putChunk('vid', 1, bytes(512));
    await a.setTotalLength('vid', 99999);

    final b = RangeCacheStore(directory: dir, maxBytes: 0, chunkSize: 1024);
    await b.init();
    expect(b.hasChunk('vid', 0), isTrue);
    expect(b.hasChunk('vid', 1), isTrue);
    expect(b.totalLength('vid'), 99999);
    expect(b.usage().usedBytes, 1536);
  });

  test('LRU evicts the least-recently-used entry over the cap', () async {
    // Cap = 2 KiB, chunks = 1 KiB → holds 2 entries.
    final store = RangeCacheStore(
      directory: dir,
      maxBytes: 2048,
      chunkSize: 1024,
    );
    await store.init();
    await store.putChunk('a', 0, bytes(1024)); // a
    await store.putChunk('b', 0, bytes(1024)); // a,b
    await store.readChunk('a', 0); // touch a → b is now LRU
    await store.putChunk('c', 0, bytes(1024)); // over cap → evict b

    expect(store.hasChunk('a', 0), isTrue);
    expect(store.hasChunk('c', 0), isTrue);
    expect(store.hasChunk('b', 0), isFalse);
    expect(store.usage().usedBytes, 2048);
  });

  test('pinned entries are never evicted', () async {
    final store = RangeCacheStore(
      directory: dir,
      maxBytes: 2048,
      chunkSize: 1024,
    );
    await store.init();
    await store.putChunk('keep', 0, bytes(1024));
    store.pin(['keep']);
    // Add two more — cap forces eviction, but 'keep' is pinned.
    await store.putChunk('x', 0, bytes(1024));
    await store.putChunk('y', 0, bytes(1024));

    expect(store.hasChunk('keep', 0), isTrue);
  });

  test('maxBytes <= 0 disables eviction (unbounded)', () async {
    final store = RangeCacheStore(directory: dir, maxBytes: 0, chunkSize: 1024);
    await store.init();
    for (var i = 0; i < 5; i++) {
      await store.putChunk('k$i', 0, bytes(1024));
    }
    expect(store.usage().usedBytes, 5120);
    expect(store.usage().entryCount, 5);
  });

  test('evictKey and clear remove data', () async {
    final store = RangeCacheStore(directory: dir, maxBytes: 0, chunkSize: 1024);
    await store.init();
    await store.putChunk('a', 0, bytes(1024));
    await store.putChunk('b', 0, bytes(1024));
    await store.evictKey('a');
    expect(store.hasChunk('a', 0), isFalse);
    expect(store.hasChunk('b', 0), isTrue);
    await store.clear();
    expect(store.usage().usedBytes, 0);
  });

  test('keys with filesystem-unsafe characters are handled', () async {
    final store = RangeCacheStore(directory: dir, maxBytes: 0, chunkSize: 1024);
    await store.init();
    const key = 'https://x/drive/v3/files/AB?alt=media&t=1';
    await store.putChunk(key, 2, bytes(1024));
    expect(store.hasChunk(key, 2), isTrue);
    expect(await store.readChunk(key, 2), isNotNull);
  });
}
