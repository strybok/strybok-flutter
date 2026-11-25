import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'created_link.dart';
import 'deferred_links.dart';
import 'exceptions.dart';
import 'link_campaign.dart';
import 'link_source.dart';
import 'resolved_deep_link.dart';

/// Version reported with analytics events.
const String strybokSdkVersion = '0.3.0';

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
    bool deferredLinks = false,
    this.allowProbabilisticMatching = false,
    List<InstallReferrerSource> installReferrerSources = const [],
    this.androidPackageName,
    this.iosBundleId,
    FutureOr<String?> Function()? deviceFamily,
    FutureOr<String?> Function()? locale,
    Future<bool> Function()? pasteboardMayContainLink,
    DeferredLinkStore? deferredLinkStore,
    @visibleForTesting Duration installReferrerTimeout = const Duration(seconds: 10),
    @visibleForTesting DateTime Function()? clock,
  }) : allowedHosts = {for (final host in allowedHosts) host.toLowerCase()},
       _source = linkSource ?? AppLinksSource(),
       _http = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _now = clock ?? DateTime.now,
       assert(maxRetries >= 0) {
    _deferred = DeferredLinkEngine(
      enabled: deferredLinks,
      allowProbabilisticMatching: allowProbabilisticMatching,
      sources: List.unmodifiable(installReferrerSources),
      androidPackageName: androidPackageName,
      iosBundleId: iosBundleId,
      deviceFamily: deviceFamily,
      locale: locale,
      pasteboardMayContainLink: pasteboardMayContainLink,
      store: deferredLinkStore,
      sourceTimeout: installReferrerTimeout,
      sdkVersion: strybokSdkVersion,
      platform: _platform,
      post: _postDeferred,
      parse: _parseDeferred,
      isOurs: isStrybokUri,
      normalLinkAccepted: () => _normalLinkAccepted,
      isDisposed: () => _disposed,
      deliver: _deliver,
    );
  }

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

  /// iOS only, and only together with `deferredLinks`: lets the server
  /// **guess** the link of a first launch from the network address, the device
  /// family and the language. Off by default.
  ///
  /// This is fingerprinting in Apple's terms: the App Store Review Guidelines
  /// and the Apple Developer Program License Agreement forbid it, with or
  /// without the user's consent; the App Review and legal risk is the app
  /// owner's. A match can be another person's link on a shared network, so
  /// check [ResolvedDeepLink.isProbabilisticMatch]. It also needs the
  /// `deviceFamily` and `locale` callbacks.
  final bool allowProbabilisticMatching;

  /// The app's own Android application ID, e.g. `com.example.app`. Required
  /// for deferred links on Android: the SDK has no native code to read it.
  final String? androidPackageName;

  /// The app's own iOS bundle identifier. Required for deferred links on iOS.
  final String? iosBundleId;

  late final DeferredLinkEngine _deferred;
  bool _normalLinkAccepted = false;

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
    // The deferred-link check starts after everything else and nothing waits for it.
    scheduleMicrotask(_deferred.start);
  }

  /// Where the deferred-link check stands. Readable at any time; it never
  /// throws and nothing about the check is passed to [onError].
  DeferredLinkStatus get deferredLinkStatus => _deferred.status;

  /// Every change of [deferredLinkStatus] (a broadcast stream; the current
  /// value is not replayed).
  Stream<DeferredLinkStatus> get deferredLinkStatusChanges => _deferred.changes;

  /// Switches deferred links on after construction, for example after a
  /// consent screen, and runs the check once if [initialize] has completed
  /// (otherwise it runs after it). Calling it again does nothing.
  ///
  /// Without a `deferredLinkStore`, without the identifier of the platform
  /// ([androidPackageName] / [iosBundleId]) or off Android and iOS the status
  /// stays [DeferredLinkStatus.disabled].
  void enableDeferredLinks() => _deferred.enable();

  /// iOS: hands over the text the person pasted, to restore the link they
  /// copied on the page before the App Store.
  ///
  /// The SDK never reads the clipboard: [text] comes from the app's paste
  /// button. Anything that is not a copied link of this app gives
  /// [PastedLinkResult.notOurs] without a request, and the text is dropped —
  /// not stored, not logged, not sent. Of a link of ours only the click id in
  /// it is sent. A restored link arrives through [links] with
  /// [ResolvedDeepLink.isDeferred] set, even if another link was delivered
  /// earlier in this launch. Never throws.
  Future<PastedLinkResult> redeemPastedLink(String? text) => _deferred.redeemPastedLink(text);

  /// iOS, only with [allowProbabilisticMatching] and a
  /// `pasteboardMayContainLink` callback: tells the SDK that the person moved
  /// on without pasting, so matching may start
  /// ([DeferredLinkStatus.awaitingPaste]). Does nothing otherwise.
  void skipPastedLink() => _deferred.skipPastedLink();

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
  /// Query and fragment do not matter.
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
    // Of the query only the campaign parameters are sent; the rest and the fragment are not
    // needed for the lookup and may hold private data.
    final campaign = campaignQuery(uri.hasQuery ? uri.query : '');
    final lookup =
        '${Uri(scheme: 'https', host: uri.host.toLowerCase(), path: uri.path)}'
        '${campaign.isEmpty ? '' : '?$campaign'}';
    final endpoint = _endpoint('/v1/public/resolve', {'url': lookup});

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
    await _deferred.close();
    if (_ownsHttpClient) _http.close();
  }

  // ---------------------------------------------------------------------------

  Future<void> _handle(Uri uri, {bool isInitial = false}) async {
    if (_disposed || !isStrybokUri(uri)) return;
    // From here on a deferred link is dropped: one launch, one navigation.
    _normalLinkAccepted = true;
    if (_isDuplicate(uri)) return;
    try {
      final link = await resolveUri(uri);
      if (_disposed) return; // Disposed while the request was in flight.
      if (isInitial) _initialLink = link;
      _deliver(link);
      if (reportAppOpens) unawaited(_reportAppOpen(link));
    } on StrybokException catch (error) {
      if (!_disposed) onError?.call(error);
    } on StateError {
      // Disposed mid-flight; nothing to deliver.
    }
  }

  void _deliver(ResolvedDeepLink link) {
    if (_disposed) return;
    if (_controller.hasListener) {
      _controller.add(link);
    } else {
      _pending.add(link);
    }
  }

  /// One deferred-link request with [timeout] and the usual retries. The
  /// answer, or `null` when none below 500 arrived. Never throws and creates
  /// no error: a deferred-link check that fails is not a failed link.
  Future<http.Response?> _postDeferred(String path, List<int> body) async {
    final endpoint = _endpoint(path);
    const headers = {'Content-Type': 'application/json', 'Accept': 'application/json'};
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      if (attempt > 0) await Future<void>.delayed(retryDelay * (1 << (attempt - 1)));
      if (_disposed) return null;
      try {
        // The same bytes on every attempt.
        final response = await _http.post(endpoint, headers: headers, body: body).timeout(timeout);
        if (response.statusCode < 500) return response;
      } catch (_) {
        // Timeout or transport failure: try again.
      }
    }
    return null;
  }

  /// A usable redeem or match answer as a link, or `null`.
  ResolvedDeepLink? _parseDeferred(String body, {required bool probabilistic}) {
    try {
      final json = jsonDecode(body);
      if (json case {
        'linkId': final String linkId,
        'appId': final String appId,
        'routePath': final String routePath,
        'deferred': true,
        'url': final String url,
      } when routePath.startsWith('/') && !routePath.startsWith('//')) {
        if (probabilistic && json['matched'] != 'probabilistic') return null;
        final uri = Uri.tryParse(url);
        // The server is not trusted to name a link of another app.
        if (uri == null || !isStrybokUri(uri)) return null;
        final payload = json['payload'];
        return ResolvedDeepLink(
          uri: uri,
          linkId: linkId,
          appId: appId,
          routePath: routePath,
          payload: payload is Map ? Map<String, Object?>.from(payload) : const {},
          campaign: LinkCampaign.fromJson(json['campaign']),
          isDeferred: true,
          isProbabilisticMatch: probabilistic,
        );
      }
    } catch (_) {
      // Not JSON, or not the shape we know.
    }
    return null;
  }

  static String _platform() => switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.android => 'android',
    _ => 'unknown',
  };

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
          campaign: LinkCampaign.fromJson(json['campaign']),
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
              'platform': _platform(),
              'sdkVersion': strybokSdkVersion,
              // What resolve returned, never read from the URL here; left out when empty.
              if (link.campaign.isNotEmpty) 'campaign': link.campaign.toJson(),
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
