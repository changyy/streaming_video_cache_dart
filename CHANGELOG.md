## 1.20260614.1215351

A player-agnostic local caching proxy for streaming video. Caches only the byte
ranges a player actually reads (not whole files), with an LRU size cap.

- `VideoCacheServer` — loopback HTTP proxy. Translates the player's `Range`
  requests into chunk-aligned upstream fetches, streaming chunk-by-chunk and
  stopping when the player disconnects (an open-ended request only fetches what
  is played). Coalesces concurrent fetches (one per chunk, one length probe per
  key). Auth header forwarding, open-ended ranges, HEAD, whole-file fallback.
  Diagnostics: low-frequency `onCacheStatus` (one HIT/MISS per clip) + opt-in
  high-frequency `onLog` (per request/chunk).
- `CacheStore` interface + `RangeCacheStore` (default file-backed): chunked
  range storage, per-entry LRU eviction, `pin()` to keep a playlist resident,
  persists across restarts.
- `UpstreamClient` interface + `HttpClientUpstream` (default `dart:io`):
  pluggable transport.
- `streamingVideoCacheVersion` constant.

Pure `dart:io` — iOS, Android, desktop (not web).
