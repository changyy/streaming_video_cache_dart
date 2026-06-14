// Example: play a remote video through `streaming_video_cache`.
//
// The video plays via `video_player`, but its URL is routed through a local
// `VideoCacheServer`. Only the byte ranges actually played are cached — replay
// the same clip and it loads from disk with no network. Tap "Cache usage" to
// see how much is on disk.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:streaming_video_cache/streaming_video_cache.dart';
import 'package:video_player/video_player.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'streaming_video_cache',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const CachedPlayerPage(),
    );
  }
}

class CachedPlayerPage extends StatefulWidget {
  const CachedPlayerPage({super.key});

  @override
  State<CachedPlayerPage> createState() => _CachedPlayerPageState();
}

class _CachedPlayerPageState extends State<CachedPlayerPage> {
  // A Range-capable sample video.
  static const _sampleUrl =
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4';

  VideoCacheServer? _cache;
  VideoPlayerController? _controller;
  String _status = 'Initializing cache…';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final dir = Directory(
      '${(await getApplicationCacheDirectory()).path}/video_cache',
    );
    final store = RangeCacheStore(
      directory: dir,
      maxBytes: 256 * 1024 * 1024, // 256 MiB LRU cap
    );
    await store.init();
    final cache = VideoCacheServer(
      store: store,
      onLog: (m) => debugPrint('[cache] $m'),
    );
    await cache.start();
    if (!mounted) {
      await cache.stop();
      return;
    }
    _cache = cache;
    setState(() => _status = 'Cache ready on :${cache.port}');
  }

  Future<void> _play() async {
    final cache = _cache;
    if (cache == null) return;
    await _controller?.dispose();
    setState(() => _status = 'Loading…');

    // Route the remote URL through the cache → get a loopback URL.
    final localUrl = cache.localUrlFor(_sampleUrl, cacheKey: 'sample');
    final controller = VideoPlayerController.networkUrl(localUrl);
    _controller = controller;
    await controller.initialize();
    await controller.setLooping(true);
    await controller.play();
    if (!mounted) return;
    setState(() => _status = 'Playing (cached on replay)');
  }

  void _showUsage() {
    final u = _cache?.usage();
    final msg = u == null
        ? 'Cache not ready'
        : '${u.usedBytes ~/ 1024} KiB used / '
              '${u.maxBytes ~/ (1024 * 1024)} MiB cap · ${u.entryCount} entries';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _clear() async {
    await _cache?.store.clear();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Cache cleared')));
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _cache?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('streaming_video_cache')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Expanded(
              child: Center(
                child: (controller != null && controller.value.isInitialized)
                    ? AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: VideoPlayer(controller),
                      )
                    : const Text('Press Play to stream through the cache'),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _cache == null ? null : _play,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _cache == null ? null : _showUsage,
                  child: const Text('Cache usage'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _cache == null ? null : _clear,
                  child: const Text('Clear'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
