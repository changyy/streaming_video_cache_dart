import 'dart:io';
import 'dart:typed_data';

import 'package:streaming_video_cache/streaming_video_cache.dart';
import 'package:test/test.dart';

/// A fake origin that supports Range and records how many bytes it served, so
/// tests can prove the proxy only fetches what was requested (partial caching).
class _FakeOrigin {
  _FakeOrigin(this.length);
  final int length;
  late final Uint8List data = Uint8List.fromList(
    List<int>.generate(length, (i) => i % 256),
  );
  HttpServer? _server;
  int bytesServed = 0;
  int requestCount = 0;
  bool requireAuth = false;
  bool ignoreRange = false;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      requestCount++;
      if (requireAuth && req.headers.value('authorization') == null) {
        req.response.statusCode = HttpStatus.unauthorized;
        await req.response.close();
        return;
      }
      final range = req.headers.value('range');
      if (ignoreRange || range == null) {
        bytesServed += data.length;
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentLength = data.length
          ..add(data);
        await req.response.close();
        return;
      }
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
      final s = int.parse(m.group(1)!);
      final eStr = m.group(2)!;
      final e = eStr.isEmpty ? data.length - 1 : int.parse(eStr);
      final slice = data.sublist(s, e + 1);
      bytesServed += slice.length;
      req.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set('content-range', 'bytes $s-$e/${data.length}')
        ..headers.contentLength = slice.length
        ..add(slice);
      await req.response.close();
    });
  }

  String url(String id) => 'http://127.0.0.1:${_server!.port}/files/$id';
  Future<void> stop() async => _server?.close(force: true);
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
  late Directory dir;
  late _FakeOrigin origin;
  late RangeCacheStore store;
  late VideoCacheServer server;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vcs_test');
    origin = _FakeOrigin(1000);
    await origin.start();
    store = RangeCacheStore(directory: dir, maxBytes: 1 << 20, chunkSize: 256);
    await store.init();
    server = VideoCacheServer(store: store);
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    await origin.stop();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('serves a sub-range with correct bytes + 206 headers', () async {
    final local = server.localUrlFor(origin.url('a'), cacheKey: 'a');
    final (status, body) = await _get(local, range: 'bytes=100-600');
    expect(status, HttpStatus.partialContent);
    expect(body, Uint8List.fromList(origin.data.sublist(100, 601)));
  });

  test('only fetches the requested ranges, not the whole file', () async {
    final local = server.localUrlFor(origin.url('a'), cacheKey: 'a');
    // Ask only for the first chunk (256 bytes).
    await _get(local, range: 'bytes=0-255');
    // Upstream should have served ~1 chunk (+1 byte for the length probe),
    // never the full 1000 bytes.
    expect(origin.bytesServed, lessThan(origin.data.length));
    expect(origin.bytesServed, lessThanOrEqualTo(256 + 1));
  });

  test('replays from cache without hitting upstream again', () async {
    final local = server.localUrlFor(origin.url('a'), cacheKey: 'a');
    await _get(local, range: 'bytes=0-255');
    final servedAfterFirst = origin.bytesServed;
    final (status, body) = await _get(local, range: 'bytes=0-255');
    expect(status, HttpStatus.partialContent);
    expect(body, Uint8List.fromList(origin.data.sublist(0, 256)));
    expect(origin.bytesServed, servedAfterFirst); // no extra upstream bytes
  });

  test('open-ended range returns the rest of the file', () async {
    final local = server.localUrlFor(origin.url('a'), cacheKey: 'a');
    final (status, body) = await _get(local, range: 'bytes=900-');
    expect(status, HttpStatus.partialContent);
    expect(body, Uint8List.fromList(origin.data.sublist(900)));
  });

  test('full request (no Range) returns 200 + whole content', () async {
    final local = server.localUrlFor(origin.url('a'), cacheKey: 'a');
    final (status, body) = await _get(local);
    expect(status, HttpStatus.ok);
    expect(body.length, origin.data.length);
    expect(body, origin.data);
  });

  test('forwards auth headers to upstream', () async {
    origin.requireAuth = true;
    final local = server.localUrlFor(
      origin.url('a'),
      cacheKey: 'a',
      headers: const {'Authorization': 'Bearer tok'},
    );
    final (status, body) = await _get(local, range: 'bytes=0-99');
    expect(status, HttpStatus.partialContent);
    expect(body, Uint8List.fromList(origin.data.sublist(0, 100)));
  });

  test('falls back when upstream ignores Range (200 whole body)', () async {
    origin.ignoreRange = true;
    final local = server.localUrlFor(origin.url('a'), cacheKey: 'a');
    final (status, body) = await _get(local, range: 'bytes=100-200');
    expect(status, HttpStatus.partialContent);
    expect(body, Uint8List.fromList(origin.data.sublist(100, 201)));
  });

  test('unknown key returns 404', () async {
    final url = Uri.parse('http://127.0.0.1:${server.port}/v?k=nope');
    final (status, _) = await _get(url);
    expect(status, HttpStatus.notFound);
  });

  test('keyForUrl extracts Drive id else stable hash', () {
    expect(
      VideoCacheServer.keyForUrl(
        'https://www.googleapis.com/drive/v3/files/XYZ?alt=media',
      ),
      'XYZ',
    );
    final k = VideoCacheServer.keyForUrl('https://e.com/clip.mp4');
    expect(k, VideoCacheServer.keyForUrl('https://e.com/clip.mp4'));
    expect(k, startsWith('h'));
  });
}
