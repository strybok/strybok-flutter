import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'created_link.dart';
import 'exceptions.dart';
import 'link_source.dart';
import 'resolved_deep_link.dart';

/// Version reported with analytics events.
const String strybokSdkVersion = '0.2.0';

/// Called when a received link could not be turned into a [ResolvedDeepLink].
typedef LinkErrorHandler = void Function(StrybokException error);

final RegExp _slugPath = RegExp(r'^/[A-Za-z0-9_-]{1,64}$');

/// A key that can be sent as an HTTP header value: visible ASCII only.
final RegExp _headerSafe = RegExp(r'^[\x21-\x7E]+$');

/// Entry point of the SDK.
///
/// ```dart
/// final strybok = Strybok(
///   apiBaseUrl: Uri.parse('https://api.example.com'),
///   allowedHosts: {'my-app-123.links.example.com'},
/// );
/// await strybok.initialize();
/// strybok.links.listen((link) => router.go(link.routePath));
/// ```
class Strybok {
  Strybok({
    required this.apiBaseUrl,
    required Set<String> allowedHosts,
    LinkSource? linkSource,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 5),
    this.maxRetries = 2,
    this.retryDelay = const Duration(milliseconds: 400),
    this.dedupeWindow = const Duration(seconds: 2),
    this.reportAppOpens = true,
    this.onError,
    this.clientKey,
    @visibleForTesting DateTime Function()? clock,
  }) : allowedHosts = {for (final host in allowedHosts) host.toLowerCase()},
       _source = linkSource ?? AppLinksSource(),
       _http = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _now = clock ?? DateTime.now,
       assert(maxRetries >= 0);

  /// Base URL of the Strybok API, e.g. `https://api.example.com`.
  final Uri apiBaseUrl;

  /// Link hostnames of this app. Links on any other host are ignored.
  final Set<String> allowedHosts;

  /// Time allowed for a single attempt of a resolve or [createLink] request.
  final Duration timeout;

  /// Extra attempts after a timeout, network error or 5xx. Resolving is an
  /// idempotent GET and creating a link returns the same link for the same
  /// content, so retrying is safe. Other answers (`4xx`) are never retried.
  final int maxRetries;

  /// Pause before the first retry; doubles for each further retry.
  final Duration retryDelay;

  /// An identical URI received again within this window is treated as a
  /// duplicate delivery of the same tap and dropped.
  final Duration dedupeWindow;

  /// Whether to send a best-effort `app_open` event after a link was resolved.
  final bool reportAppOpens;

  /// Receives errors for links that arrived from the OS but could not be
  /// resolved. Links that are simply not ours are ignored without an error.
  final LinkErrorHandler? onError;

  /// Publishable key (`pk_…`) of the application, from "Links from the app" in
  /// the dashboard. Only needed for [createLink]. It is safe to ship inside the
  /// app; never put a secret API key (`lb_…`) here.
  final String? clientKey;

  final LinkSource _source;
  final http.Client _http;
  final bool _ownsHttpClient;
  final DateTime Function() _now;

  late final StreamController<ResolvedDeepLink> _controller =
      StreamController<ResolvedDeepLink>.broadcast(onListen: _flushPending);

  /// Links resolved while nobody was listening (typically the cold-start link).
  final List<ResolvedDeepLink> _pending = [];
  StreamSubscription<Uri>? _subscription;
  Future<void>? _initialization;
  ResolvedDeepLink? _initialLink;
  String? _lastUri;
  DateTime? _lastUriAt;
  bool _disposed = false;

  /// Resolved links, each delivered exactly once.
  ///
  /// Links that arrive before the first listener is attached (for example the
  /// one that cold-started the app) are kept and delivered as soon as you listen.
  Stream<ResolvedDeepLink> get links => _controller.stream;

  /// Starts listening for links and handles the one that launched the app.
  ///
  /// Completes once the launch link, if any, has been resolved (or has failed),
  /// so it is safe to `await` before building your router. Calling it again
  /// returns the same future.
  Future<void> initialize() {
    _checkNotDisposed();
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    // Listen first so a link arriving during start-up is not missed.
    _subscription = _source.uriStream.listen(
      (uri) => unawaited(_handle(uri)),
      onError: (Object _) {},
    );
    Uri? initial;
    try {
      initial = await _source.getInitialLink();
    } catch (_) {
      initial = null; // The platform could not tell us; treat as "no launch link".
    }
    if (initial != null) await _handle(initial, isInitial: true);
  }

  /// The link that launched the app, if it has not been delivered through
  /// [links] yet. Returns it at most once and removes it from [links], so using
  /// both APIs never navigates twice.
  Future<ResolvedDeepLink?> getInitialLink() async {
    await initialize();
    final link = _initialLink;
    _initialLink = null;
    return link != null && _pending.remove(link) ? link : null;
  }

  /// Whether [uri] looks like a Strybok link of this app: `https`, a host
  /// from [allowedHosts], default port, no credentials and a single slug path.
  bool isStrybokUri(Uri uri) =>
      uri.scheme == 'https' &&
      allowedHosts.contains(uri.host.toLowerCase()) &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      _slugPath.hasMatch(uri.path);

  /// Resolves [uri] through the API without touching [links].
  ///
  /// Throws a [StrybokException]: [UnsupportedLinkException] before any
  /// network call when the URI is not ours, [LinkNotFoundException] for unknown,
  /// disabled or expired links, and network/timeout/server errors otherwise.
  Future<ResolvedDeepLink> resolveUri(Uri uri) async {
    _checkNotDisposed();
    if (!isStrybokUri(uri)) {
      throw UnsupportedLinkException('Not a link for this app', uri: uri);
    }
    // Query and fragment are not needed for the lookup and may hold private data.
    final lookup = Uri(scheme: 'https', host: uri.host.toLowerCase(), path: uri.path);
    final endpoint = _endpoint('/v1/public/resolve', {'url': '$lookup'});

    final response = await _send(
      () => _http.get(endpoint, headers: const {'Accept': 'application/json'}),
      uri: uri,
      timeoutMessage: 'The resolve request timed out',
    );
    if (response.statusCode == 200) return _parse(uri, response.body);
    if (response.statusCode == 404) throw LinkNotFoundException(uri: uri);
    throw StrybokServerException(
      'Unexpected status ${response.statusCode}',
      uri: uri,
      statusCode: response.statusCode,
    );
  }

  /// Asks the service for a short link to [routePath], a screen of this app —
  /// the "Share" button. Share [CreatedLink.url].
  ///
  /// Needs [clientKey], and the route must be covered by the route patterns
  /// listed for the application in the dashboard. [payload] is a JSON object
  /// delivered with the link; [title], [description] and [imageUrl] are shown
  /// in link previews. Arguments left out are not sent. Do not put personal
  /// data in a route or payload: whoever receives the link can read them.
  ///
  /// It runs only when called: [initialize] and incoming links never depend on
  /// it, and it works before or without [initialize]. Asking again with the
  /// same content returns the same link, so timeouts, network errors and 5xx
  /// are retried like in [resolveUri].
  ///
  /// Throws a [StrybokException], never passed to [onError]:
  /// [StrybokUnauthorizedException], [RouteNotAllowedException] and
  /// [StrybokValidationException] need a change in the app or the dashboard;
  /// [StrybokRateLimitedException], [StrybokNetworkException],
  /// [StrybokTimeoutException] and [StrybokServerException] are temporary.
  Future<CreatedLink> createLink(
    String routePath, {
    Map<String, Object?>? payload,
    String? title,
    String? description,
    Uri? imageUrl,
  }) async {
    _checkNotDisposed();
    final key = clientKey;
    if (key == null || key.isEmpty) {
      throw const StrybokUnauthorizedException('No client key is configured');
    }
    if (!_headerSafe.hasMatch(key)) {
      // It could not be sent as a header, and no key the service issues looks like this.
      throw const StrybokUnauthorizedException('The client key is not valid');
    }
    if (!routePath.startsWith('/') || routePath.startsWith('//')) {
      throw const StrybokValidationException('routePath must start with a single "/"');
    }
    if (routePath.length > 512) {
      throw const StrybokValidationException('routePath must be at most 512 characters');
    }
    // Encoded once, so every retry sends exactly the same bytes.
    final List<int> body;
    try {
      body = utf8.encode(
        jsonEncode({
          'routePath': routePath,
          'payload': ?payload,
          'title': ?title,
          'description': ?description,
          if (imageUrl != null) 'imageUrl': '$imageUrl',
        }),
      );
    } on JsonUnsupportedObjectError {
      throw const StrybokValidationException('payload must contain only JSON values');
    }
    final endpoint = _endpoint('/v1/public/links');
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-Strybok-Key': key,
    };

    final response = await _send(
      () => _http.post(endpoint, headers: headers, body: body),
      timeoutMessage: 'The create-link request timed out',
    );
    final status = response.statusCode;
    switch (status) {
      case 200 || 201:
        return _parseCreated(response.body, status);
      case 401:
        throw const StrybokUnauthorizedException();
      case 403:
        throw RouteNotAllowedException(routePath);
      case 429:
        final seconds = int.tryParse(response.headers['retry-after']?.trim() ?? '');
        throw StrybokRateLimitedException(
          retryAfter: seconds != null && seconds >= 0 ? Duration(seconds: seconds) : null,
        );
      case 400 || 413 || 422:
        throw _validationError(response.body, status);
      default:
        throw StrybokServerException('Unexpected status $status', statusCode: status);
    }
  }

  /// Stops listening and releases resources. The instance cannot be reused.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pending.clear();
    _initialLink = null;
    await _subscription?.cancel();
    await _controller.close();
    if (_ownsHttpClient) _http.close();
  }

  // ---------------------------------------------------------------------------

  Future<void> _handle(Uri uri, {bool isInitial = false}) async {
    if (_disposed || !isStrybokUri(uri) || _isDuplicate(uri)) return;
    try {
      final link = await resolveUri(uri);
      if (_disposed) return; // Disposed while the request was in flight.
      if (isInitial) _initialLink = link;
      if (_controller.hasListener) {
        _controller.add(link);
      } else {
        _pending.add(link);
      }
      if (reportAppOpens) unawaited(_reportAppOpen(link));
    } on StrybokException catch (error) {
      if (!_disposed) onError?.call(error);
    } on StateError {
      // Disposed mid-flight; nothing to deliver.
    }
  }

  /// The OS (or the plugin) can hand over the same tap twice, e.g. as the
  /// initial link and again on the stream.
  bool _isDuplicate(Uri uri) {
    final now = _now();
    final key = '$uri';
    final duplicate =
        _lastUri == key && _lastUriAt != null && now.difference(_lastUriAt!) < dedupeWindow;
    _lastUri = key;
    _lastUriAt = now;
    return duplicate;
  }

  void _flushPending() {
    final queued = List.of(_pending);
    _pending.clear();
    // Deliver asynchronously: the listener is still being attached.
    scheduleMicrotask(() {
      for (final link in queued) {
        if (!_controller.isClosed) _controller.add(link);
      }
    });
  }

  /// Sends a request with [timeout] and retries. Returns the first answer
  /// below 500; throws the last error once the attempts are used up.
  Future<http.Response> _send(
    Future<http.Response> Function() request, {
    Uri? uri,
    required String timeoutMessage,
  }) async {
    late StrybokException lastError;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      if (attempt > 0) await Future<void>.delayed(retryDelay * (1 << (attempt - 1)));
      _checkNotDisposed();
      try {
        final response = await request().timeout(timeout);
        if (response.statusCode < 500) return response; // Client errors will not improve.
        lastError = StrybokServerException(
          'Unexpected status ${response.statusCode}',
          uri: uri,
          statusCode: response.statusCode,
        );
      } on TimeoutException {
        lastError = StrybokTimeoutException(uri: uri, message: timeoutMessage);
      } catch (error) {
        lastError = StrybokNetworkException('Network error', uri: uri, cause: error);
      }
    }
    throw lastError;
  }

  CreatedLink _parseCreated(String body, int status) {
    try {
      final json = jsonDecode(body);
      if (json case {
        'linkId': final String linkId,
        'slug': final String slug,
        'routePath': final String routePath,
        'url': final String url,
      } when url.startsWith('https://')) {
        final parsed = Uri.tryParse(url);
        if (parsed != null && parsed.host.isNotEmpty) {
          return CreatedLink(url: parsed, slug: slug, routePath: routePath, linkId: linkId);
        }
      }
    } on FormatException {
      // Fall through to the error below.
    }
    throw StrybokServerException('Malformed create-link response', statusCode: status);
  }

  /// Keeps the service's explanation (`error.message`, `error.details.issues`).
  StrybokValidationException _validationError(String body, int status) {
    var message = 'The request was rejected (status $status)';
    final issues = <StrybokValidationIssue>[];
    try {
      if (jsonDecode(body) case {'error': final Map<String, dynamic> error}) {
        if (error['message'] case final String text when text.isNotEmpty) message = text;
        if (error['details'] case {'issues': final List<dynamic> list}) {
          for (final issue in list) {
            if (issue case {'message': final String text}) {
              final path = issue['path'];
              issues.add(StrybokValidationIssue(path: path is String ? path : '', message: text));
            }
          }
        }
      }
    } on FormatException {
      // No readable explanation; the status is all we know.
    }
    return StrybokValidationException(message, issues: List.unmodifiable(issues));
  }

  ResolvedDeepLink _parse(Uri uri, String body) {
    try {
      final json = jsonDecode(body);
      if (json case {
        'linkId': final String linkId,
        'appId': final String appId,
        'routePath': final String routePath,
      } when routePath.startsWith('/') && !routePath.startsWith('//')) {
        final payload = json['payload'];
        return ResolvedDeepLink(
          uri: uri,
          linkId: linkId,
          appId: appId,
          routePath: routePath,
          payload: payload is Map ? Map<String, Object?>.from(payload) : const {},
        );
      }
    } on FormatException {
      // Fall through to the error below.
    }
    throw StrybokServerException('Malformed resolve response', uri: uri, statusCode: 200);
  }

  /// Best effort and never awaited by navigation. This is a self-reported
  /// metric (an app can be modified), separate from server-side fallback visits.
  Future<void> _reportAppOpen(ResolvedDeepLink link) async {
    try {
      await _http
          .post(
            _endpoint('/v1/public/events'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'eventId': _uuidV4(),
              'linkId': link.linkId,
              'type': 'app_open',
              'platform': switch (defaultTargetPlatform) {
                TargetPlatform.iOS => 'ios',
                TargetPlatform.android => 'android',
                _ => 'unknown',
              },
              'sdkVersion': strybokSdkVersion,
            }),
          )
          .timeout(timeout);
    } catch (_) {
      // Analytics must never affect the app.
    }
  }

  Uri _endpoint(String path, [Map<String, String>? query]) {
    final base = apiBaseUrl.path.endsWith('/')
        ? apiBaseUrl.path.substring(0, apiBaseUrl.path.length - 1)
        : apiBaseUrl.path;
    return apiBaseUrl.replace(path: '$base$path', queryParameters: query);
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('Strybok has been disposed');
  }
}

/// Random RFC 4122 version 4 UUID; identifies one event for de-duplication only.
String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
