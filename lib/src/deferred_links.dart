import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'link_campaign.dart';
import 'resolved_deep_link.dart';

/// Where the check for a deferred link (a link tapped before the app was
/// installed) stands. Nothing about this check is ever reported as an error.
enum DeferredLinkStatus {
  /// Deferred links are off: the `deferredLinks` option is `false`, no
  /// `deferredLinkStore` was passed, the app's identifier for this platform
  /// (`androidPackageName` / `iosBundleId`) is missing, or the platform is
  /// neither Android nor iOS.
  disabled,

  /// The check is running in this launch.
  checking,

  /// This launch could not finish the check (store or network not reachable),
  /// or it has not started yet; a later launch tries again.
  pending,

  /// The check was finished in an earlier launch.
  notFirstLaunch,

  /// No referrer source is configured, or none can ever answer on this device.
  /// On iOS: probabilistic matching is off (only a pasted link can restore
  /// anything), or the device family or language is not usable.
  unavailable,

  /// The store returned a referrer without a click id of ours — the usual
  /// result of an ordinary install.
  noReferrer,

  /// The server refused: unknown, too old, already used, or another app's.
  notFound,

  /// A normal link of this app arrived first.
  superseded,

  /// The link was handed to `Strybok.links`.
  delivered,

  /// Three launches could not finish the check, or the server's answer was
  /// unusable.
  failed,

  /// iOS, probabilistic matching only: the clipboard may hold a link, so the
  /// SDK waits for `redeemPastedLink` or `skipPastedLink` before it matches.
  awaitingPaste,
}

/// Result of `Strybok.redeemPastedLink`.
enum PastedLinkResult {
  /// The link was handed to `Strybok.links`.
  delivered,

  /// The text is not a copied link of this app. Nothing was sent or kept.
  notOurs,

  /// The server refused the link: unknown, older than 24 hours, already used,
  /// or another app's.
  notFound,

  /// A deferred link was already handled in this installation.
  alreadyHandled,

  /// Deferred links are off (see [DeferredLinkStatus.disabled]) or this is
  /// not iOS.
  disabled,

  /// The request failed or the answer was unusable. After a network failure
  /// the person can paste again.
  failed,
}

/// Answer of an [InstallReferrerSource]: exactly one of a referrer string,
/// [unavailableForNow] or [unavailable].
@immutable
final class InstallReferrerAnswer {
  /// The raw install referrer of the store the app was installed from,
  /// exactly as the store returned it (it may be empty).
  const InstallReferrerAnswer.referrer(String this.referrer) : _kind = 0;

  const InstallReferrerAnswer._(this._kind) : referrer = null;

  /// The store could not be asked; a later launch may succeed.
  static const InstallReferrerAnswer unavailableForNow = InstallReferrerAnswer._(1);

  /// This store is not on the device, is too old, or its library is not in
  /// the app. Asking again is pointless.
  static const InstallReferrerAnswer unavailable = InstallReferrerAnswer._(2);

  /// The referrer string, or `null` for the two "unavailable" answers.
  final String? referrer;
  final int _kind;

  /// Deliberately without the referrer: it must never end up in a log.
  @override
  String toString() => switch (_kind) {
    0 => 'InstallReferrerAnswer.referrer',
    1 => 'InstallReferrerAnswer.unavailableForNow',
    _ => 'InstallReferrerAnswer.unavailable',
  };
}

/// Asks one store for its install referrer. Supplied by the app: this SDK has
/// no native code and reads no referrer itself.
///
/// It should not throw and should answer within 10 seconds; the SDK treats a
/// thrown error or a longer wait as [InstallReferrerAnswer.unavailableForNow].
/// It must release whatever connection it opened.
typedef InstallReferrerSource = Future<InstallReferrerAnswer> Function();

/// Small persistent key-value storage for the two values the deferred-link
/// check keeps per installation (`attempts` and `done`). Supplied by the app,
/// for example on top of `shared_preferences`.
///
/// It must survive a restart of the app and be removed with the app's data.
/// Without a store deferred links stay [DeferredLinkStatus.disabled]: keeping
/// the state in memory would redeem again on the next launch.
abstract interface class DeferredLinkStore {
  /// The value stored for [key], or `null`.
  Future<String?> read(String key);

  /// Stores [value] for [key]; must have completed durably when it returns.
  Future<void> write(String key, String value);
}

/// Key of the attempt counter in a [DeferredLinkStore] (a decimal integer).
const String deferredAttemptsKey = 'strybok.deferred.attempts';

/// Key of the "finished" mark in a [DeferredLinkStore] (the value is `1`).
const String deferredDoneKey = 'strybok.deferred.done';

const _maxAttempts = 3;
const _referrerKey = 'strybok_click';
final RegExp _clickId = RegExp(r'^dc_[0-9A-Za-z]{32}$');
final RegExp _locale = RegExp(r'^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8}){0,4}$');
const _deviceFamilies = {'iphone', 'ipad', 'ipod'};

/// The click id in a store's install referrer, or `null`.
///
/// The first `&`-separated part whose key is exactly `strybok_click` decides.
/// Only when no part has that key and the string contains `strybok_click%3D`
/// is the whole string percent-decoded once and searched again. Nothing else
/// of the referrer is looked at.
String? clickIdFromReferrer(String referrer) => _findClickId(referrer, mayDecode: true);

String? _findClickId(String referrer, {required bool mayDecode}) {
  for (final part in referrer.split('&')) {
    final equals = part.indexOf('=');
    if ((equals >= 0 ? part.substring(0, equals) : part) != _referrerKey) continue;
    final value = equals >= 0 ? part.substring(equals + 1) : '';
    return _clickId.hasMatch(value) ? value : null;
  }
  if (!mayDecode || !referrer.toLowerCase().contains('$_referrerKey%3d')) return null;
  final String decoded;
  try {
    decoded = Uri.decodeComponent(referrer);
  } catch (_) {
    return null; // Malformed encoding: no id.
  }
  return _findClickId(decoded, mayDecode: false);
}

/// The click id of a pasted link, or `null` when [text] is not a link of this
/// app ([isOurs]) whose first `strybok_click` query parameter is a click id.
String? clickIdFromPastedLink(String? text, bool Function(Uri uri) isOurs) {
  if (text == null) return null;
  final uri = Uri.tryParse(text.trim());
  if (uri == null || !isOurs(uri) || !uri.hasQuery) return null;
  for (final part in uri.query.split('&')) {
    final equals = part.indexOf('=');
    final key = decodeQueryComponent(equals >= 0 ? part.substring(0, equals) : part);
    if (key != _referrerKey) continue;
    final value = equals >= 0 ? decodeQueryComponent(part.substring(equals + 1)) : '';
    return value != null && _clickId.hasMatch(value) ? value : null;
  }
  return null;
}

/// The deferred-link state machine of the SDK contract ("Deferred links" for
/// Android and for iOS). Not part of the public API: `Strybok` owns one and
/// supplies the transport and the delivery pipeline.
class DeferredLinkEngine {
  DeferredLinkEngine({
    required this._enabled,
    required this.allowProbabilisticMatching,
    required this.sources,
    required this.androidPackageName,
    required this.iosBundleId,
    required this.deviceFamily,
    required this.locale,
    required this.pasteboardMayContainLink,
    required this.store,
    required this.sourceTimeout,
    required this.sdkVersion,
    required this.platform,
    required this.post,
    required this.parse,
    required this.isOurs,
    required this.normalLinkAccepted,
    required this.isDisposed,
    required this.deliver,
  }) {
    _status = _effective ? DeferredLinkStatus.pending : DeferredLinkStatus.disabled;
  }

  final bool allowProbabilisticMatching;
  final List<InstallReferrerSource> sources;
  final String? androidPackageName;
  final String? iosBundleId;
  final FutureOr<String?> Function()? deviceFamily;
  final FutureOr<String?> Function()? locale;
  final Future<bool> Function()? pasteboardMayContainLink;
  final DeferredLinkStore? store;
  final Duration sourceTimeout;
  final String sdkVersion;

  /// `android`, `ios` or anything else.
  final String Function() platform;

  /// Sends a JSON body with the usual timeout and retries. The answer, or
  /// `null` when none below 500 arrived.
  final Future<http.Response?> Function(String path, List<int> body) post;

  /// A usable answer as a link, or `null`.
  final ResolvedDeepLink? Function(String body, {required bool probabilistic}) parse;
  final bool Function(Uri uri) isOurs;

  /// Whether a link of this app arrived from the link source in this process.
  final bool Function() normalLinkAccepted;
  final bool Function() isDisposed;
  final void Function(ResolvedDeepLink link) deliver;

  final StreamController<DeferredLinkStatus> _changes =
      StreamController<DeferredLinkStatus>.broadcast();

  bool _enabled;
  late DeferredLinkStatus _status;

  /// Start-up has completed, so the automatic check may run.
  bool _started = false;

  /// The automatic check ran (or is running) in this process.
  bool _ran = false;

  /// In-memory mirror of the stored `done`, set the moment a flow decides to
  /// store it, so two flows can never both deliver.
  bool _done = false;
  bool _awaitingPaste = false;
  Future<void> _pasteQueue = Future<void>.value();

  DeferredLinkStatus get status => _status;
  Stream<DeferredLinkStatus> get changes => _changes.stream;

  String? get _identifier => switch (platform()) {
    'android' => androidPackageName,
    'ios' => iosBundleId,
    _ => null,
  };

  bool get _effective => _enabled && store != null && (_identifier?.isNotEmpty ?? false);

  /// Called once `initialize` has done everything else.
  void start() {
    _started = true;
    _maybeRun();
  }

  void enable() {
    _enabled = true;
    if (!_effective || isDisposed()) return;
    if (_status == DeferredLinkStatus.disabled) _setStatus(DeferredLinkStatus.pending);
    _maybeRun();
  }

  void skipPastedLink() => _continueAfterPaste();

  Future<PastedLinkResult> redeemPastedLink(String? text) {
    final result = _pasteQueue.then((_) => _redeemPasted(text));
    _pasteQueue = result.then((_) {});
    return result;
  }

  Future<void> close() => _changes.close();

  void _maybeRun() {
    if (!_started || _ran || !_effective || isDisposed()) return;
    _ran = true;
    unawaited(_run());
  }

  /// Never throws.
  Future<void> _run() async {
    try {
      if (platform() == 'android') {
        await _runAndroid();
      } else {
        await _runIos();
      }
    } catch (_) {
      // A check that fails is not a failed link: nothing is reported.
    }
  }

  Future<void> _runAndroid() async {
    _setStatus(DeferredLinkStatus.checking);
    if (!await _beginAttempt()) return;

    String? clickId;
    var unavailableForNow = false;
    var sawReferrer = false;
    for (final source in sources) {
      final answer = await _ask(source);
      final referrer = answer.referrer;
      if (referrer != null) {
        sawReferrer = true;
        clickId = clickIdFromReferrer(referrer);
        if (clickId != null) break;
      } else if (identical(answer, InstallReferrerAnswer.unavailableForNow)) {
        unavailableForNow = true;
      }
    }
    if (clickId == null) {
      if (unavailableForNow) return _setStatus(DeferredLinkStatus.pending);
      await _storeDone();
      return _setStatus(
        sawReferrer ? DeferredLinkStatus.noReferrer : DeferredLinkStatus.unavailable,
      );
    }
    if (normalLinkAccepted()) {
      await _storeDone();
      return _setStatus(DeferredLinkStatus.superseded);
    }
    final response = await post(
      '/v1/public/deferred-links/redeem',
      utf8.encode(
        jsonEncode({
          'platform': 'android',
          'clickId': clickId,
          'packageName': androidPackageName,
          'sdkVersion': sdkVersion,
        }),
      ),
    );
    await _finish(response, probabilistic: false);
  }

  Future<void> _runIos() async {
    if (_done) return; // A link pasted before start-up was handled; its status stands.
    final bool done;
    try {
      done = await _readDone();
    } catch (_) {
      return _setStatus(DeferredLinkStatus.pending);
    }
    if (done) return _setStatus(DeferredLinkStatus.notFirstLaunch);
    // Only a pasted link can restore anything; that needs the person, so nothing is stored.
    if (!allowProbabilisticMatching) return _setStatus(DeferredLinkStatus.unavailable);

    _setStatus(DeferredLinkStatus.checking);
    final mayContainLink = pasteboardMayContainLink;
    if (mayContainLink != null) {
      var answer = false;
      try {
        answer = await mayContainLink();
      } catch (_) {
        answer = false;
      }
      if (_done) return; // A pasted link was handled meanwhile.
      if (answer) {
        _awaitingPaste = true;
        return _setStatus(DeferredLinkStatus.awaitingPaste);
      }
    }
    await _match();
  }

  void _continueAfterPaste() {
    if (!_awaitingPaste) return;
    _awaitingPaste = false;
    unawaited(() async {
      try {
        await _match();
      } catch (_) {
        // Never reported.
      }
    }());
  }

  Future<void> _match() async {
    if (_done) return; // A pasted link was handled; matching never runs.
    _setStatus(DeferredLinkStatus.checking);
    if (!await _beginAttempt()) return;
    if (normalLinkAccepted()) {
      await _storeDone();
      return _setStatus(DeferredLinkStatus.superseded);
    }
    final family = await _value(deviceFamily);
    final language = await _value(locale);
    if (family == null ||
        !_deviceFamilies.contains(family) ||
        language == null ||
        !_locale.hasMatch(language)) {
      await _storeDone();
      return _setStatus(DeferredLinkStatus.unavailable);
    }
    final response = await post(
      '/v1/public/deferred-links/match',
      utf8.encode(
        jsonEncode({
          'platform': 'ios',
          'bundleId': iosBundleId,
          'deviceFamily': family,
          'locale': language,
          'sdkVersion': sdkVersion,
        }),
      ),
    );
    await _finish(response, probabilistic: true);
  }

  /// Steps "done?", "three attempts?" and "store attempts + 1". `false` when
  /// the check ends here; the status is set.
  Future<bool> _beginAttempt() async {
    final int attempts;
    try {
      // Set by a pasted link in this launch: that flow owns the status.
      if (_done) return false;
      final stored = await store!.read(deferredDoneKey);
      if (_done) return false;
      if (stored != null) {
        _done = true;
        _setStatus(DeferredLinkStatus.notFirstLaunch);
        return false;
      }
      attempts = await _readAttempts();
    } catch (_) {
      _setStatus(DeferredLinkStatus.pending);
      return false;
    }
    if (attempts >= _maxAttempts) {
      await _storeDone();
      _setStatus(DeferredLinkStatus.failed);
      return false;
    }
    try {
      // Before anything else happens: a launch that dies from here on has used an attempt.
      await store!.write(deferredAttemptsKey, '${attempts + 1}');
    } catch (_) {
      _setStatus(DeferredLinkStatus.pending);
      return false;
    }
    return true;
  }

  /// The outcome table of the automatic flows (Android redeem, iOS match).
  Future<void> _finish(http.Response? response, {required bool probabilistic}) async {
    if (response == null || response.statusCode == 429) {
      return _setStatus(DeferredLinkStatus.pending);
    }
    if (response.statusCode != 200) {
      await _storeDone();
      return _setStatus(DeferredLinkStatus.notFound);
    }
    final link = parse(response.body, probabilistic: probabilistic);
    if (link == null) {
      await _storeDone();
      return _setStatus(DeferredLinkStatus.failed);
    }
    if (_done) return; // A pasted link was handled meanwhile; its status stands.
    if (normalLinkAccepted()) {
      await _storeDone();
      return _setStatus(DeferredLinkStatus.superseded);
    }
    if (!await _storeDone()) return _setStatus(DeferredLinkStatus.failed);
    if (isDisposed()) return;
    // A normal link wins at any moment before the hand-over.
    if (normalLinkAccepted()) return _setStatus(DeferredLinkStatus.superseded);
    deliver(link);
    _setStatus(DeferredLinkStatus.delivered);
  }

  Future<PastedLinkResult> _redeemPasted(String? text) async {
    try {
      if (isDisposed() || !_effective || platform() != 'ios') return PastedLinkResult.disabled;
      if (await _readDone()) return PastedLinkResult.alreadyHandled;
      final clickId = clickIdFromPastedLink(text, isOurs);
      if (clickId == null) {
        _continueAfterPaste();
        return PastedLinkResult.notOurs;
      }
      // Only the click id is sent, never the pasted URL.
      final response = await post(
        '/v1/public/deferred-links/redeem',
        utf8.encode(
          jsonEncode({
            'platform': 'ios',
            'clickId': clickId,
            'bundleId': iosBundleId,
            'sdkVersion': sdkVersion,
          }),
        ),
      );
      if (response == null || response.statusCode == 429) return PastedLinkResult.failed;
      if (response.statusCode != 200) {
        await _storeDone();
        _setStatus(DeferredLinkStatus.notFound);
        return PastedLinkResult.notFound;
      }
      final link = parse(response.body, probabilistic: false);
      if (link == null) {
        await _storeDone();
        _setStatus(DeferredLinkStatus.failed);
        return PastedLinkResult.failed;
      }
      if (_done) return PastedLinkResult.alreadyHandled; // Matching delivered meanwhile.
      if (!await _storeDone()) {
        _setStatus(DeferredLinkStatus.failed);
        return PastedLinkResult.failed;
      }
      if (isDisposed()) return PastedLinkResult.failed;
      // Delivered even after a normal link: pasting was the person's own, explicit action.
      deliver(link);
      _setStatus(DeferredLinkStatus.delivered);
      return PastedLinkResult.delivered;
    } catch (_) {
      return PastedLinkResult.failed;
    }
  }

  Future<InstallReferrerAnswer> _ask(InstallReferrerSource source) async {
    final completer = Completer<InstallReferrerAnswer>();
    void complete(InstallReferrerAnswer answer) {
      if (!completer.isCompleted) completer.complete(answer);
    }

    // A call that takes too long is abandoned; whatever it answers later is ignored.
    final timer = Timer(sourceTimeout, () => complete(InstallReferrerAnswer.unavailableForNow));
    try {
      unawaited(
        source().then<void>(
          complete,
          onError: (Object _) => complete(InstallReferrerAnswer.unavailableForNow),
        ),
      );
    } catch (_) {
      complete(InstallReferrerAnswer.unavailableForNow);
    }
    final answer = await completer.future;
    timer.cancel();
    return answer;
  }

  Future<String?> _value(FutureOr<String?> Function()? callback) async {
    if (callback == null) return null;
    try {
      return await callback();
    } catch (_) {
      return null;
    }
  }

  /// Throws when the store cannot be read.
  Future<bool> _readDone() async {
    if (_done) return true;
    if (await store!.read(deferredDoneKey) != null) _done = true;
    return _done;
  }

  /// Throws when the store cannot be read. A value that is not a number
  /// counts as "used up": never more than three checks.
  Future<int> _readAttempts() async {
    final stored = await store!.read(deferredAttemptsKey);
    if (stored == null) return 0;
    final attempts = int.tryParse(stored);
    return attempts == null || attempts < 0 ? _maxAttempts : attempts;
  }

  /// Marks the check finished, in memory at once and then in the store.
  /// `false` when the store refused the write.
  Future<bool> _storeDone() async {
    _done = true;
    try {
      await store!.write(deferredDoneKey, '1');
      return true;
    } catch (_) {
      return false;
    }
  }

  void _setStatus(DeferredLinkStatus status) {
    if (_status == status || _changes.isClosed) return;
    _status = status;
    _changes.add(status);
  }
}
