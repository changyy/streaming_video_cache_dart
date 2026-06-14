import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'cache_store.dart';
import 'upstream_client.dart';

class _Origin {
  _Origin(this.url, this.headers);
  final Uri url;
  final Map<String, String> headers;
  String? contentType;
}

/// A loopback HTTP server that proxies a remote video and caches only the byte
/// ranges the player actually reads (via a [CacheStore]).
///
/// Point any HTTP player (e.g. `video_player`) at the URL returned by
/// [localUrlFor]. The server translates the player's `Range` requests into
/// chunk-aligned upstream fetches, **streaming chunk-by-chunk and stopping as
/// soon as the player disconnects** — so an open-ended `bytes=0-` request that
/// the player cancels after a few seconds only ever fetches (and caches) those
/// few seconds, exactly like ExoPlayer's `SimpleCache`. Replays are served from
/// the [store] with no upstream traffic; the store's size cap bounds disk use.
///
/// Both the storage ([store]) and the transport ([UpstreamClient]) are
/// injectable. Pure `dart:io` — works on iOS, Android and desktop (not web).
class VideoCacheServer {
  VideoCacheServer({
    required this.store,
    UpstreamClient? upstream,
    Duration upstreamTimeout = const Duration(seconds: 30),
    this.onLog,
    this.onCacheStatus,
  }) : _upstream = upstream ?? HttpClientUpstream(timeout: upstreamTimeout);

  final CacheStore store;
  final UpstreamClient _upstream;

  /// Verbose diagnostics sink — one timed line PER request/chunk (range, fetch
  /// ms, served ms, disconnects). High-frequency; off by default. Wire it only
  /// when debugging stalls.
  final void Function(String message)? onLog;

  /// Low-frequency status sink — fires ONCE the first time each [cacheKey] is
  /// requested in this server's lifetime, with whether its first byte range was
  /// already resident (`true` = cache hit) or had to be downloaded (`false` =
  /// miss). Use this for a quiet per-clip "HIT/MISS" log instead of [onLog].
  final void Function(String cacheKey, bool servedFromCache)? onCacheStatus;

  void _log(String message) => onLog?.call(message);

  HttpServer? _server;
  final Map<String, _Origin> _origins = <String, _Origin>{};

  /// Keys already reported via [onCacheStatus] (announce once per lifetime).
  final Set<String> _statusAnnounced = <String>{};

  /// In-flight upstream chunk fetches, keyed by `"$cacheKey:$chunkIndex"`, so
  /// concurrent misses for the same chunk share one fetch instead of N.
  final Map<String, Future<Uint8List?>> _inflight =
      <String, Future<Uint8List?>>{};

  /// In-flight length probes, keyed by cache key, so concurrent first requests
  /// share one `bytes=0-0` probe.
  final Map<String, Future<int?>> _pendingTotal = <String, Future<int?>>{};

  /// Stable cache key for a URL: the Drive file id when present (survives
  /// token/URL churn), else a stable FNV-1a hash of the URL.
  static String keyForUrl(String url) {
    final driveId = RegExp(r'/files/([^/?#]+)').firstMatch(url)?.group(1);
    if (driveId != null && driveId.isNotEmpty) return driveId;
    return _fnv1a(url);
  }

  static String _fnv1a(String s) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    const mask = 0xFFFFFFFFFFFFFFFF;
    for (final c in s.codeUnits) {
      hash = (hash ^ c) & mask;
      hash = (hash * prime) & mask;
    }
    return 'h${hash.toRadixString(16)}';
  }

  bool get isRunning => _server != null;
  int get port => _server!.port;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    try {
      await server?.close(force: true);
    } catch (_) {}
    _upstream.close();
  }

  /// Registers [originUrl] (with optional [headers] such as an Authorization
  /// bearer) and returns the loopback URL to hand to the player. Pass a stable
  /// [cacheKey] (e.g. a file id) so the cache survives token/query changes;
  /// defaults to [keyForUrl].
  Uri localUrlFor(
    String originUrl, {
    Map<String, String>? headers,
    String? cacheKey,
  }) {
    final key = cacheKey ?? keyForUrl(originUrl);
    _origins[key] = _Origin(Uri.parse(originUrl), headers ?? const {});
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: '/v',
      queryParameters: <String, String>{'k': key},
    );
  }

  /// Keep [cacheKeys] resident in the cache (never LRU-evicted) — typically the
  /// current playlist.
  void pin(Iterable<String> cacheKeys) => store.pin(cacheKeys);

  CacheUsage usage() => store.usage();

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final sw = Stopwatch()..start();
    try {
      final key = req.uri.queryParameters['k'];
      final origin = key == null ? null : _origins[key];
      if (key == null || origin == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }

      final rawRange = req.headers.value(HttpHeaders.rangeHeader);
      _log('▶ ${req.method} key=$key range=${rawRange ?? "(none)"}');

      final total = await _ensureTotalLength(key, origin);
      if (total == null || total <= 0) {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
        return;
      }

      // Parse Range (supports open-ended `bytes=start-`).
      var start = 0;
      var end = total - 1;
      var partial = false;
      if (rawRange != null) {
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rawRange);
        if (m != null) {
          start = int.parse(m.group(1)!);
          final e = m.group(2)!;
          end = e.isEmpty ? total - 1 : int.parse(e);
          partial = true;
        }
      }
      if (start >= total) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await res.close();
        return;
      }
      end = end.clamp(0, total - 1);

      // Low-frequency: announce HIT/MISS once, the first time this key is hit.
      if (onCacheStatus != null && _statusAnnounced.add(key)) {
        onCacheStatus!(key, store.hasChunk(key, start ~/ store.chunkSize));
      }

      res.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      res.headers.set(
        HttpHeaders.contentTypeHeader,
        origin.contentType ?? 'video/mp4',
      );
      res.headers.set(HttpHeaders.contentLengthHeader, '${end - start + 1}');
      if (partial) {
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$total',
        );
      }
      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      res.bufferOutput = false;

      // Stream chunk-by-chunk; break the moment the client disconnects so an
      // open-ended request only fetches what the player actually consumes.
      var pos = start;
      var sent = 0;
      var hits = 0;
      var misses = 0;
      var disconnected = false;
      while (pos <= end) {
        final chunkIndex = pos ~/ store.chunkSize;
        final hit = store.hasChunk(key, chunkIndex);
        final chunk = await _ensureChunk(key, origin, chunkIndex, total);
        if (chunk == null) {
          _log('  ✗ chunk $chunkIndex fetch failed → abort');
          break;
        }
        hit ? hits++ : misses++;
        final chunkStart = chunkIndex * store.chunkSize;
        final from = pos - chunkStart;
        final to = (end - chunkStart + 1).clamp(0, chunk.length);
        if (from >= to) break;
        try {
          res.add(chunk.sublist(from, to));
          await res.flush();
        } catch (_) {
          disconnected = true;
          break; // client disconnected (seek/cancel) → stop fetching
        }
        sent += to - from;
        pos = chunkStart + to;
      }
      await res.close();
      _log(
        '■ key=$key range=$start-$end served=${sent}B '
        'hits=$hits misses=$misses${disconnected ? ' (client disconnected)' : ''} '
        'in ${sw.elapsedMilliseconds}ms',
      );
    } catch (e) {
      _log('✗ handler error after ${sw.elapsedMilliseconds}ms: $e');
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// Returns the cached chunk, fetching the chunk-aligned upstream range first
  /// if absent. Null on upstream failure.
  Future<Uint8List?> _ensureChunk(
    String key,
    _Origin origin,
    int index,
    int total,
  ) async {
    final cached = await store.readChunk(key, index);
    if (cached != null) return cached;
    // Coalesce concurrent misses for the same chunk into ONE upstream fetch —
    // players open several connections and re-read overlapping ranges, which
    // would otherwise download the same chunk many times.
    final fkey = '$key:$index';
    final pending = _inflight[fkey];
    if (pending != null) {
      _log('  ~ chunk $index coalesced (joined in-flight fetch)');
      return pending;
    }
    final future = _fetchAndStore(key, origin, index, total);
    _inflight[fkey] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(fkey);
    }
  }

  Future<Uint8List?> _fetchAndStore(
    String key,
    _Origin origin,
    int index,
    int total,
  ) async {
    final from = index * store.chunkSize;
    if (from >= total) return null;
    final to = ((index + 1) * store.chunkSize).clamp(0, total) - 1; // inclusive
    final data = await _fetchRange(origin, from, to, total);
    if (data == null) return null;
    await store.putChunk(key, index, data);
    return data;
  }

  /// Fetches upstream bytes [from]..[to] (inclusive). Handles servers that
  /// ignore Range (200 with the whole body) by slicing.
  Future<Uint8List?> _fetchRange(
    _Origin origin,
    int from,
    int to,
    int total,
  ) async {
    final sw = Stopwatch()..start();
    final resp = await _upstream.fetchRange(
      origin.url,
      origin.headers,
      from,
      to,
    );
    if (resp == null || !resp.ok) {
      _log(
        '  ↑ upstream $from-$to → ${resp?.statusCode ?? "FAILED"} '
        'in ${sw.elapsedMilliseconds}ms',
      );
      return null;
    }
    origin.contentType ??= resp.contentType;
    _log(
      '  ↑ upstream MISS fetch $from-$to → ${resp.bytes.length}B '
      'in ${sw.elapsedMilliseconds}ms (status ${resp.statusCode})',
    );
    if (resp.isFullBody) {
      // Upstream ignored Range → body is the whole file; slice our window.
      final hi = (to + 1).clamp(0, resp.bytes.length);
      final lo = from.clamp(0, hi);
      return Uint8List.fromList(resp.bytes.sublist(lo, hi));
    }
    return resp.bytes;
  }

  /// Learns total length (+ content-type) via a tiny `bytes=0-0` probe, cached
  /// in the store so it's only done once per key. Concurrent first requests
  /// share a single probe (players open several connections at once).
  Future<int?> _ensureTotalLength(String key, _Origin origin) async {
    final known = store.totalLength(key);
    if (known != null) {
      _log('  length cached: total=$known');
      return known;
    }
    final pending = _pendingTotal[key];
    if (pending != null) return pending;
    final future = _probeTotal(key, origin);
    _pendingTotal[key] = future;
    try {
      return await future;
    } finally {
      _pendingTotal.remove(key);
    }
  }

  Future<int?> _probeTotal(String key, _Origin origin) async {
    final sw = Stopwatch()..start();
    final resp = await _upstream.fetchRange(origin.url, origin.headers, 0, 0);
    if (resp == null) {
      _log('  length probe FAILED in ${sw.elapsedMilliseconds}ms');
      return null;
    }
    origin.contentType ??= resp.contentType;
    final total = resp.totalLength;
    if (total != null && total > 0) {
      await store.setTotalLength(key, total);
    }
    _log(
      '  length probe: total=$total in ${sw.elapsedMilliseconds}ms '
      '(status ${resp.statusCode})',
    );
    return total;
  }
}
