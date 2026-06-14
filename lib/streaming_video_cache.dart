/// A player-agnostic local caching proxy for streaming video: caches only the
/// byte ranges actually played (not whole files), with an LRU size cap.
library;

export 'src/cache_store.dart';
export 'src/range_cache_store.dart';
export 'src/upstream_client.dart';
export 'src/version.dart';
export 'src/video_cache_server.dart';
