import 'dart:io';
import 'dart:typed_data';

import 'package:streaming_video_cache/streaming_video_cache.dart';
import 'package:test/test.dart';

/// An in-memory [UpstreamClient] — proves the transport is injectable and the
/// server can be exercised without a real origin HTTP server.
class _FakeUpstream implements UpstreamClient {
  _FakeUpstream(this.data, {this.delay = Duration.zero});
  final Uint8List data;
  final Duration delay;
  int fetches = 0;

  @override
  Future<UpstreamResponse?> fetchRange(
    Uri url,
    Map<String, String> headers,
    int start,
    int end,
  ) async {
    fetches++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final hi = (end + 1).clamp(0, data.length);
    final lo = start.clamp(0, hi);
    return UpstreamResponse(
      statusCode: HttpStatus.partialContent,
      bytes: Uint8List.sublistView(data, lo, hi),
      totalLength: data.length,
      contentType: 'video/mp4',
    );
  }

  @override
  void close() {}
}

Future<(int, Uint8List)> _get(Uri url, {String? range}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(url);
    if (range != null) req.headers.set('range', range);
    final resp = await req.close();
    final bb = BytesBuilder(copy: false);
    await for (final c in resp) {
      bb.add(c);
    }
    return (resp.statusCode, bb.toBytes());
  } finally {
    client.close();
  }
}

void main() {
  test('a custom UpstreamClient can be injected and is used', () async {
    final dir = await Directory.systemTemp.createTemp('di_test');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final data = Uint8List.fromList(List<int>.generate(800, (i) => i % 256));
    final upstream = _FakeUpstream(data);
    final store = RangeCacheStore(
      directory: dir,
      maxBytes: 1 << 20,
      chunkSize: 256,
    );
    await store.init();
    final server = VideoCacheServer(store: store, upstream: upstream);
    await server.start();
    addTearDown(server.stop);

    final url = server.localUrlFor('https://x/files/clip', cacheKey: 'clip');

    final (status, body) = await _get(url, range: 'bytes=0-299');
    expect(status, HttpStatus.partialContent);
    expect(body, Uint8List.sublistView(data, 0, 300));
    expect(upstream.fetches, greaterThan(0));

    // Replay the same range → served from the store, no extra upstream fetch.
    final fetchesAfterFirst = upstream.fetches;
    final (status2, body2) = await _get(url, range: 'bytes=0-299');
    expect(status2, HttpStatus.partialContent);
    expect(body2, Uint8List.sublistView(data, 0, 300));
    expect(upstream.fetches, fetchesAfterFirst); // cache hit
  });

  test(
    'concurrent requests for the same chunk coalesce to one fetch',
    () async {
      final dir = await Directory.systemTemp.createTemp('coalesce_test');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final data = Uint8List.fromList(List<int>.generate(1024, (i) => i % 256));
      // Slow upstream so the requests genuinely overlap in flight.
      final upstream = _FakeUpstream(
        data,
        delay: const Duration(milliseconds: 80),
      );
      final store = RangeCacheStore(
        directory: dir,
        maxBytes: 1 << 20,
        chunkSize: 256,
      );
      await store.init();
      final server = VideoCacheServer(store: store, upstream: upstream);
      await server.start();
      addTearDown(server.stop);

      final url = server.localUrlFor('https://x/files/c', cacheKey: 'c');
      // 5 concurrent reads of the same first chunk (256 bytes).
      await Future.wait(
        List.generate(5, (_) => _get(url, range: 'bytes=0-255')),
      );

      // The length probe (bytes=0-0) + ONE fetch for chunk 0 — not five.
      expect(upstream.fetches, lessThanOrEqualTo(2));
    },
  );
}
