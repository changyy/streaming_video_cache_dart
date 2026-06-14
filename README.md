# streaming_video_cache

[![Pub Version](https://img.shields.io/pub/v/streaming_video_cache)](https://pub.dev/packages/streaming_video_cache)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A **player-agnostic local caching proxy** for streaming video whose defining
feature is **partial-length caching**: it stores only the portion of each video
that is actually played — **not the whole file** — with an LRU size cap, so
repeated playback uses no network. Play the first ~45 s of a clip and only those
bytes are cached; the rest is never downloaded. Point `video_player` (or any
HTTP-based player) at the loopback URL it hands you.

Pure `dart:io` — works on **iOS, Android and desktop** (not web). No native code.

## Why

`video_player` streams progressively but gives you no control over caching: you
can't bound it or guarantee a replay hit. Downloading whole files to cache them
is wasteful when a slideshow only plays the first ~45s of each clip. This package
caches like ExoPlayer's `SimpleCache` does — **only the played byte ranges** —
but in portable Dart, at the HTTP layer, so it works with the player you already
use.

```
video_player ──HTTP Range──▶ 127.0.0.1:<port>  (VideoCacheServer)
                                   │
                     ┌─────────────┴──────────────┐
                     ▼                             ▼
            cached range → from disk      missing → fetch upstream
                                          (+ your auth headers)
                                          → store range, LRU-evict
```

Because the proxy streams chunk-by-chunk and **stops the moment the player
disconnects**, an open-ended `bytes=0-` request that the player cancels after a
few seconds only ever fetches (and caches) those few seconds.

## Usage

```dart
import 'dart:io';
import 'package:streaming_video_cache/streaming_video_cache.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';

// Start once (e.g. per player screen).
final store = RangeCacheStore(
  directory: Directory('${(await getApplicationCacheDirectory()).path}/video_cache'),
  maxBytes: 2 * 1024 * 1024 * 1024, // 2 GiB LRU cap
);
await store.init();
final cache = VideoCacheServer(store: store);
await cache.start();

// Wrap a remote URL → get a loopback URL for the player.
final localUrl = cache.localUrlFor(
  'https://www.googleapis.com/drive/v3/files/FILE_ID?alt=media',
  headers: {'Authorization': 'Bearer $accessToken'},
  cacheKey: 'FILE_ID', // stable key so the cache survives token/URL changes
);

final controller = VideoPlayerController.networkUrl(localUrl);
await controller.initialize();
await controller.play();

// Keep the current playlist resident (never LRU-evicted):
cache.pin(['FILE_ID_1', 'FILE_ID_2']);

// Diagnostics / teardown
print(cache.usage()); // used / cap / entry count
await cache.stop();
```

## API

- `VideoCacheServer({store, upstream, upstreamTimeout, onLog, onCacheStatus})` —
  `start()` / `stop()`, `localUrlFor(url, {headers, cacheKey})`, `pin(keys)`,
  `usage()`, `VideoCacheServer.keyForUrl(url)` (Drive id or stable hash).
  - `onCacheStatus(key, hit)` — **low-frequency**: fires once per key on first
    touch (a quiet per-clip HIT/MISS log).
  - `onLog(message)` — **high-frequency** verbose trace, one line per
    request/chunk; opt-in for debugging stalls.
- `CacheStore` — storage interface (chunk-addressed). `RangeCacheStore` is the
  default file-backed impl: `RangeCacheStore({directory, maxBytes, chunkSize})`
  with `init()`, `usage()`, `pin()`, `evictKey()`, `clear()`. `maxBytes <= 0`
  disables eviction.
- `UpstreamClient` — transport interface. `HttpClientUpstream` is the default
  (`dart:io`).

## Custom storage & transport (dependency injection)

Both sides are pluggable, so the cache logic isn't tied to `dart:io` files or
any particular HTTP stack:

```dart
// Your own storage backend (in-memory, encrypted, …):
class MyStore implements CacheStore { /* implement the chunk methods */ }

// Your own transport (package:http, dio, auth-refreshing, a test fake…):
class MyUpstream implements UpstreamClient { /* fetchRange(...) */ }

final cache = VideoCacheServer(store: MyStore(), upstream: MyUpstream());
```

The server speaks only "chunk N of key K" to the store and "fetch byte range"
to the upstream — everything else (Range parsing, partial caching, serving)
stays the same. This also makes the server unit-testable with no real network.

## Partial-length caching

This package caches **only the portion of each video that is actually played**
— not the whole file. Because playback flows through the proxy as HTTP `Range`
requests and the proxy stops fetching the moment the player disconnects, a clip
that you only play for the first N seconds caches just those bytes; the rest of
the file is never downloaded.

This is what makes a **bounded** cache practical: a digital-frame slideshow that
shows the first ~45 s of hundreds of long clips can keep them all hot under a
small disk budget (each entry is the played slice, not the full file), and the
LRU cap + `pin()` decide what stays resident. Whole-file/offline caching is not
a goal here.

## Requirements & limits

- The upstream **should support HTTP Range** (most CDNs and Google Drive
  `alt=media` do). If it ignores Range, the proxy falls back to fetching the
  whole file and slicing.
- **No web** (uses `dart:io HttpServer`).
- **iOS App Transport Security**: connecting to `http://127.0.0.1` is allowed,
  but if you see ATS errors add `NSAllowsLocalNetworking` (`true`) under
  `NSAppTransportSecurity` in `Info.plist`.
- Tokens (e.g. Drive bearer ~1h): the proxy uses the headers you passed at
  `localUrlFor`. If they expire, re-call `localUrlFor` with fresh headers.

## License

MIT
