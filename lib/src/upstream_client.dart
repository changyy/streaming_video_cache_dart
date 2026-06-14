import 'dart:io';
import 'dart:typed_data';

/// Result of an upstream byte-range fetch.
class UpstreamResponse {
  const UpstreamResponse({
    required this.statusCode,
    required this.bytes,
    this.totalLength,
    this.contentType,
  });

  final int statusCode;

  /// The returned bytes. For a `206` this is the requested range; for a `200`
  /// (server ignored Range) it's the whole body and the caller slices.
  final Uint8List bytes;

  /// Total resource length parsed from `Content-Range` (or `Content-Length`),
  /// if the server reported it.
  final int? totalLength;

  final String? contentType;

  bool get ok =>
      statusCode == HttpStatus.ok || statusCode == HttpStatus.partialContent;
  bool get isFullBody => statusCode == HttpStatus.ok;
}

/// Transport used by [VideoCacheServer] to fetch upstream bytes. Inject your
/// own (e.g. backed by `package:http`, `dio`, auth-refreshing, or a test fake)
/// to control how/where bytes are fetched — the cache logic stays the same.
abstract class UpstreamClient {
  /// Fetch [url] (with [headers]) for the inclusive byte range [start]..[end].
  Future<UpstreamResponse?> fetchRange(
    Uri url,
    Map<String, String> headers,
    int start,
    int end,
  );

  void close();
}

/// Default [UpstreamClient] backed by `dart:io`'s [HttpClient].
class HttpClientUpstream implements UpstreamClient {
  HttpClientUpstream({
    Duration timeout = const Duration(seconds: 30),
    HttpClient? client,
  }) : _timeout = timeout,
       _client = client ?? HttpClient() {
    _client.connectionTimeout = timeout;
  }

  final Duration _timeout;
  final HttpClient _client;

  @override
  Future<UpstreamResponse?> fetchRange(
    Uri url,
    Map<String, String> headers,
    int start,
    int end,
  ) async {
    try {
      final request = await _client.getUrl(url);
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
      final response = await request.close().timeout(_timeout);
      int? total;
      if (response.statusCode == HttpStatus.partialContent) {
        final cr = response.headers.value(HttpHeaders.contentRangeHeader);
        final m = RegExp(r'/(\d+)\s*$').firstMatch(cr ?? '');
        total = m != null ? int.tryParse(m.group(1)!) : null;
      } else if (response.statusCode == HttpStatus.ok) {
        total = response.contentLength > 0 ? response.contentLength : null;
      }
      final contentType = response.headers.contentType?.toString();
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return UpstreamResponse(
        statusCode: response.statusCode,
        bytes: builder.toBytes(),
        totalLength: total,
        contentType: contentType,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void close() {
    try {
      _client.close(force: true);
    } catch (_) {}
  }
}
