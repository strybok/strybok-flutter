import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strybok/strybok.dart';
import 'package:strybok/testing.dart';

const host = 'my-app-123.links.example.com';
final apiBase = Uri.parse('https://api.example.com');
final invite = Uri.parse('https://$host/invite777');
const clickId = 'dc_0123456789abcdefghijABCDEFGHIJ01';
const otherId = 'dc_ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ';
const package = 'com.example.app';
const bundle = 'com.example.App';
final pasted = 'https://$host/invite777?strybok_click=$clickId';

http.Response deferredOk({
  String? url,
  Object? deferred = true,
  String? matched,
  String route = '/invite/abc123',
}) => http.Response(
  jsonEncode({
    'linkId': 'link_1',
    'appId': 'app_1',
    'routePath': route,
    'payload': {'invitationId': 'abc123'},
    'campaign': {'source': 'instagram', 'ignored': 1},
    'url': url ?? 'https://$host/invite777',
    'deferred': ?deferred,
    'matched': ?matched,
    'somethingNew': true,
  }),
  200,
);

http.Response resolved() => http.Response(
  jsonEncode({'linkId': 'link_n', 'appId': 'app_1', 'routePath': '/normal', 'payload': {}}),
  200,
);

/// Records every request by endpoint.
class Api {
  final redeems = <http.Request>[];
  final matches = <http.Request>[];
  final resolves = <http.Request>[];
  final events = <http.Request>[];
  FutureOr<http.Response> Function(http.Request request)? onRedeem;
  FutureOr<http.Response> Function(http.Request request)? onMatch;
  FutureOr<http.Response> Function(http.Request request)? onResolve;

  int get deferredRequests => redeems.length + matches.length;

  late final client = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/v1/public/events')) {
      events.add(request);
      return http.Response('', 202);
    }
    if (path.endsWith('/v1/public/deferred-links/redeem')) {
      redeems.add(request);
      return await (onRedeem?.call(request) ?? deferredOk());
    }
    if (path.endsWith('/v1/public/deferred-links/match')) {
      matches.add(request);
      return await (onMatch?.call(request) ?? deferredOk(matched: 'probabilistic'));
    }
    resolves.add(request);
    return await (onResolve?.call(request) ?? resolved());
  });
}

/// A store whose reads or writes can be made to fail.
class FlakyStore extends InMemoryDeferredLinkStore {
  bool failReads = false;
  final failWrites = <String>{};

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('read failed');
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites.contains(key)) throw StateError('write failed');
    return super.write(key, value);
  }
}

InstallReferrerSource referrer(String value, [List<String>? log, String name = 'play']) =>
    () async {
      log?.add(name);
      return InstallReferrerAnswer.referrer(value);
    };

InstallReferrerSource answering(InstallReferrerAnswer answer, [List<String>? log, String? name]) =>
    () async {
      log?.add(name ?? '$answer');
      return answer;
    };

final errors = <StrybokException>[];

Strybok sdk(
  Api api, {
  bool deferredLinks = true,
  bool allowProbabilisticMatching = false,
  List<InstallReferrerSource>? sources,
  String? androidPackageName = package,
  String? iosBundleId = bundle,
  FutureOr<String?> Function()? deviceFamily,
  FutureOr<String?> Function()? locale,
  Future<bool> Function()? pasteboardMayContainLink,
  DeferredLinkStore? store,
  bool noStore = false,
  FakeLinkSource? source,
  int maxRetries = 2,
  Duration installReferrerTimeout = const Duration(seconds: 10),
}) {
  final instance = Strybok(
    apiBaseUrl: apiBase,
    allowedHosts: {host},
    linkSource: source ?? FakeLinkSource(),
    httpClient: api.client,
    timeout: const Duration(milliseconds: 60),
    maxRetries: maxRetries,
    retryDelay: const Duration(milliseconds: 1),
    onError: errors.add,
    deferredLinks: deferredLinks,
    allowProbabilisticMatching: allowProbabilisticMatching,
    installReferrerSources: sources ?? [referrer('strybok_click=$clickId')],
    androidPackageName: androidPackageName,
    iosBundleId: iosBundleId,
    deviceFamily: deviceFamily,
    locale: locale,
    pasteboardMayContainLink: pasteboardMayContainLink,
    deferredLinkStore: noStore ? null : (store ?? InMemoryDeferredLinkStore()),
    installReferrerTimeout: installReferrerTimeout,
  );
  addTearDown(instance.dispose);
  return instance;
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

/// Waits until the check has left `pending`/`checking`, or for [status].
Future<void> finished(Strybok sdk, [DeferredLinkStatus? status]) async {
  for (var i = 0; i < 2000; i++) {
    final now = sdk.deferredLinkStatus;
    if (status != null
        ? now == status
        : now != DeferredLinkStatus.pending && now != DeferredLinkStatus.checking) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('the check did not finish: ${sdk.deferredLinkStatus}');
}

/// Starts [instance] and returns the status the automatic check ended with.
Future<DeferredLinkStatus> launch(Strybok instance) async {
  await instance.initialize();
  await finished(instance);
  return instance.deferredLinkStatus;
}

void main() {
  setUp(() {
    errors.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    expect(errors, isEmpty, reason: 'nothing about deferred links goes to onError');
    debugDefaultTargetPlatformOverride = null;
  });

  group('switched off', () {
    test('off by default: nothing is asked, sent or stored', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final asked = <String>[];
      final instance = Strybok(
        apiBaseUrl: apiBase,
        allowedHosts: {host},
        linkSource: FakeLinkSource(),
        httpClient: api.client,
        installReferrerSources: [referrer('strybok_click=$clickId', asked)],
        androidPackageName: package,
        deferredLinkStore: store,
      );
      addTearDown(instance.dispose);
      expect(instance.deferredLinkStatus, DeferredLinkStatus.disabled);
      await instance.initialize();
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.disabled);
      expect(asked, isEmpty);
      expect(api.deferredRequests, 0);
      expect(store.values, isEmpty);
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.disabled);
    });

    test('without a store deferred links stay disabled', () async {
      final api = Api();
      final asked = <String>[];
      final instance = sdk(
        api,
        noStore: true,
        sources: [referrer('strybok_click=$clickId', asked)],
      );
      expect(instance.deferredLinkStatus, DeferredLinkStatus.disabled);
      await instance.initialize();
      instance.enableDeferredLinks();
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.disabled);
      expect(asked, isEmpty);
      expect(api.deferredRequests, 0);
    });

    test('without the package name (Android) or bundle id (iOS) they stay disabled', () async {
      for (final name in [null, '']) {
        final api = Api();
        final store = InMemoryDeferredLinkStore();
        final instance = sdk(api, androidPackageName: name, store: store);
        await instance.initialize();
        await settle();
        expect(instance.deferredLinkStatus, DeferredLinkStatus.disabled);
        expect(api.deferredRequests, 0);
        expect(store.values, isEmpty);
      }
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final api = Api();
      final instance = sdk(api, iosBundleId: null);
      await instance.initialize();
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.disabled);
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.disabled);
      expect(api.deferredRequests, 0);
    });

    test('on a platform that is neither Android nor iOS they stay disabled', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(api, store: store, allowProbabilisticMatching: true);
      await instance.initialize();
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.disabled);
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.disabled);
      expect(api.deferredRequests, 0);
      expect(store.values, isEmpty);
    });

    test('redeemPastedLink is disabled on Android', () async {
      final api = Api();
      final instance = sdk(api, sources: []);
      await launch(instance);
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.disabled);
      expect(api.deferredRequests, 0);
    });
  });

  group('Android: finding the click id', () {
    final cases = <String, String?>{
      'strybok_click=$clickId': clickId,
      'utm_source=x&strybok_click=$clickId&utm_medium=y': clickId,
      'strybok_click=$clickId&strybok_click=$otherId': clickId,
      'strybok_click=bad&strybok_click=$clickId': null,
      '': null,
      'utm_source=google-play&utm_medium=organic': null,
      'xstrybok_click=$clickId': null,
      'strybok_click': null,
      'strybok_click=': null,
      'strybok_click=$clickId ': null,
      'strybok_click=${clickId.substring(0, 34)}': null,
      'strybok_click=${clickId}0': null,
      'strybok_click=dc_0123456789abcdefghijABCDEFGHIJ0%31': null,
      'Strybok_Click=$clickId': null,
      'strybok_click%3D$clickId': clickId,
      'utm_source%3Dx%26strybok_click%3d$clickId%26utm_medium%3Dy': clickId,
      'STRYBOK_CLICK%3D$clickId': null,
      'strybok_click%3D$clickId%zz': null,
      'strybok_click%253D$clickId': null,
      'strybok_click=bad&other=strybok_click%3D$clickId': null,
      'xstrybok_click%3D$clickId': null,
    };
    cases.forEach((value, expected) {
      test('"$value" → ${expected ?? 'no id'}', () async {
        final api = Api();
        final instance = sdk(api, sources: [referrer(value)]);
        final status = await launch(instance);
        if (expected == null) {
          expect(status, DeferredLinkStatus.noReferrer);
          expect(api.redeems, isEmpty);
        } else {
          expect(status, DeferredLinkStatus.delivered);
          expect((jsonDecode(api.redeems.single.body) as Map)['clickId'], expected);
        }
      });
    });
  });

  group('Android: the check', () {
    test('delivers the link through links, marked deferred, with the exact request', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(
        api,
        store: store,
        sources: [referrer('utm_source=secret&strybok_click=$clickId&gclid=private')],
      );
      final statuses = <DeferredLinkStatus>[];
      instance.deferredLinkStatusChanges.listen(statuses.add);
      final links = <ResolvedDeepLink>[];
      final doneAtDelivery = <String?>[];
      instance.links.listen((link) {
        links.add(link);
        doneAtDelivery.add(store.values[deferredDoneKey]);
      });
      expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);

      expect(await launch(instance), DeferredLinkStatus.delivered);
      await settle();

      final request = api.redeems.single;
      expect(request.method, 'POST');
      expect('${request.url}', 'https://api.example.com/v1/public/deferred-links/redeem');
      expect(request.headers['content-type'], 'application/json');
      expect(request.headers['accept'], 'application/json');
      expect(
        request.body,
        '{"platform":"android","clickId":"$clickId","packageName":"$package","sdkVersion":"0.3.0"}',
      );

      final link = links.single;
      expect(link.uri, Uri.parse('https://$host/invite777'));
      expect(link.linkId, 'link_1');
      expect(link.appId, 'app_1');
      expect(link.routePath, '/invite/abc123');
      expect(link.payload, {'invitationId': 'abc123'});
      expect(link.campaign, const LinkCampaign(source: 'instagram'));
      expect(link.isDeferred, isTrue);
      expect(link.isProbabilisticMatch, isFalse);
      expect(doneAtDelivery, ['1'], reason: 'done is stored before the link is handed over');
      expect(statuses, [DeferredLinkStatus.checking, DeferredLinkStatus.delivered]);
      // Only the two state values are ever stored; no app_open is sent for a deferred link.
      expect(store.values, {deferredAttemptsKey: '1', deferredDoneKey: '1'});
      expect(api.events, isEmpty);
      expect(api.resolves, isEmpty);
    });

    test('an API base URL with a path prefix is preserved', () async {
      final api = Api();
      final instance = Strybok(
        apiBaseUrl: Uri.parse('https://example.com/strybok/'),
        allowedHosts: {host},
        linkSource: FakeLinkSource(),
        httpClient: api.client,
        deferredLinks: true,
        installReferrerSources: [referrer('strybok_click=$clickId')],
        androidPackageName: package,
        deferredLinkStore: InMemoryDeferredLinkStore(),
      );
      addTearDown(instance.dispose);
      await launch(instance);
      expect(
        '${api.redeems.single.url}',
        'https://example.com/strybok/v1/public/deferred-links/redeem',
      );
    });

    test('initialize completes while a source blocks; attempts are stored first', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final never = Completer<InstallReferrerAnswer>();
      String? attemptsWhenAsked;
      final instance = sdk(
        api,
        store: store,
        sources: [
          () {
            attemptsWhenAsked = store.values[deferredAttemptsKey];
            return never.future;
          },
        ],
      );
      await instance.initialize();
      expect(await instance.getInitialLink(), isNull);
      await finished(instance, DeferredLinkStatus.checking);
      await settle();
      expect(attemptsWhenAsked, '1');
      expect(instance.deferredLinkStatus, DeferredLinkStatus.checking);
      expect(store.values, {deferredAttemptsKey: '1'});
      expect(api.deferredRequests, 0);
    });

    test('a link is never returned by getInitialLink and waits for a listener', () async {
      final api = Api();
      final instance = sdk(api);
      expect(await launch(instance), DeferredLinkStatus.delivered);
      expect(await instance.getInitialLink(), isNull);
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      await settle();
      expect(links.single.isDeferred, isTrue);
      expect(api.events, isEmpty);
    });

    test('sources are asked in order and the first id ends the search', () async {
      final api = Api();
      final asked = <String>[];
      final instance = sdk(
        api,
        sources: [
          answering(InstallReferrerAnswer.unavailable, asked, 'play'),
          answering(InstallReferrerAnswer.unavailableForNow, asked, 'galaxy'),
          referrer('utm_source=x', asked, 'other'),
          referrer('strybok_click=$otherId', asked, 'huawei'),
          referrer('strybok_click=$clickId', asked, 'never'),
        ],
      );
      expect(await launch(instance), DeferredLinkStatus.delivered);
      expect(asked, ['play', 'galaxy', 'other', 'huawei']);
      expect((jsonDecode(api.redeems.single.body) as Map)['clickId'], otherId);
    });

    test('no source configured → unavailable, done', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(api, store: store, sources: []);
      expect(await launch(instance), DeferredLinkStatus.unavailable);
      expect(store.values, {deferredAttemptsKey: '1', deferredDoneKey: '1'});
      expect(api.deferredRequests, 0);
    });

    test('every source unavailable → unavailable, done', () async {
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(
        Api(),
        store: store,
        sources: [
          answering(InstallReferrerAnswer.unavailable),
          answering(InstallReferrerAnswer.unavailable),
        ],
      );
      expect(await launch(instance), DeferredLinkStatus.unavailable);
      expect(store.values[deferredDoneKey], '1');
    });

    test('a referrer without an id beside an unavailable source → noReferrer, done', () async {
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(
        Api(),
        store: store,
        sources: [answering(InstallReferrerAnswer.unavailable), referrer('')],
      );
      expect(await launch(instance), DeferredLinkStatus.noReferrer);
      expect(store.values[deferredDoneKey], '1');
    });

    test('"unavailable for now" from any source → pending, done not stored', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(
        api,
        store: store,
        sources: [
          referrer('utm_source=x'),
          answering(InstallReferrerAnswer.unavailableForNow),
          answering(InstallReferrerAnswer.unavailable),
        ],
      );
      await instance.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
      expect(store.values, {deferredAttemptsKey: '1'});
      expect(api.deferredRequests, 0);
    });

    test('a source that takes too long counts as "unavailable for now"', () async {
      final asked = <String>[];
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(
        Api(),
        store: store,
        installReferrerTimeout: const Duration(milliseconds: 30),
        sources: [
          () => Completer<InstallReferrerAnswer>().future,
          answering(InstallReferrerAnswer.unavailable, asked, 'second'),
        ],
      );
      await instance.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
      expect(asked, ['second'], reason: 'the slow call is abandoned and the next source asked');
      expect(store.values.containsKey(deferredDoneKey), isFalse);
    });

    test('a source that throws counts as "unavailable for now"', () async {
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(
        Api(),
        store: store,
        sources: [
          () => throw StateError('plugin missing'),
          () async => throw StateError('plugin failed'),
        ],
      );
      await instance.initialize();
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
      expect(store.values, {deferredAttemptsKey: '1'});
    });

    test('a throwing source does not hide the id of a later one', () async {
      final instance = sdk(
        Api(),
        sources: [() => throw StateError('x'), referrer('strybok_click=$clickId')],
      );
      expect(await launch(instance), DeferredLinkStatus.delivered);
    });
  });

  group('Android: answers of the server', () {
    for (final status in [404, 400, 401, 403, 410, 422]) {
      test('$status → notFound, done, nothing delivered', () async {
        final api = Api()..onRedeem = (_) => http.Response('{"error":{}}', status);
        final store = InMemoryDeferredLinkStore();
        final instance = sdk(api, store: store);
        final links = <ResolvedDeepLink>[];
        instance.links.listen(links.add);
        expect(await launch(instance), DeferredLinkStatus.notFound);
        await settle();
        expect(api.redeems, hasLength(1));
        expect(store.values[deferredDoneKey], '1');
        expect(links, isEmpty);
      });
    }

    test('429 → pending without a retry in this launch', () async {
      final api = Api()..onRedeem = (_) => http.Response('', 429);
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(api, store: store);
      await instance.initialize();
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
      expect(api.redeems, hasLength(1));
      expect(store.values, {deferredAttemptsKey: '1'});
    });

    test('5xx is retried with the identical body, then pending', () async {
      final api = Api()..onRedeem = (_) => http.Response('', 503);
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(api, store: store);
      await instance.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
      expect(api.redeems, hasLength(3));
      expect(api.redeems.map((request) => request.body).toSet(), hasLength(1));
      expect(store.values, {deferredAttemptsKey: '1'});
    });

    test('a retry that succeeds delivers', () async {
      var calls = 0;
      final api = Api()
        ..onRedeem = (_) {
          calls++;
          if (calls == 1) return http.Response('', 500);
          if (calls == 2) throw http.ClientException('offline');
          return deferredOk();
        };
      final instance = sdk(api);
      expect(await launch(instance), DeferredLinkStatus.delivered);
      expect(api.redeems, hasLength(3));
    });

    test('transport failures and timeouts after the retries → pending', () async {
      for (final FutureOr<http.Response> Function(http.Request) answer in [
        (_) => throw http.ClientException('offline'),
        (_) => Completer<http.Response>().future,
      ]) {
        final api = Api()..onRedeem = answer;
        final store = InMemoryDeferredLinkStore();
        final instance = sdk(api, store: store, maxRetries: 1);
        await instance.initialize();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
        expect(api.redeems, hasLength(2));
        expect(store.values, {deferredAttemptsKey: '1'});
      }
    });

    final unusable = <String, http.Response>{
      'not JSON': http.Response('<html>', 200),
      'a JSON array': http.Response('[]', 200),
      'missing linkId': http.Response(
        jsonEncode({'appId': 'a', 'routePath': '/x', 'url': 'https://$host/abc', 'deferred': true}),
        200,
      ),
      'deferred missing': deferredOk(deferred: null),
      'deferred not true': deferredOk(deferred: 'true'),
      'url on a foreign host': deferredOk(url: 'https://evil.example.com/invite777'),
      'url that is not a link': deferredOk(url: 'https://$host/a/b'),
      'url with http': deferredOk(url: 'http://$host/invite777'),
      'routePath without slash': deferredOk(route: 'invite'),
      'routePath with two slashes': deferredOk(route: '//evil.example.com'),
    };
    unusable.forEach((name, response) {
      test('200 with $name → failed, done, nothing delivered', () async {
        final api = Api()..onRedeem = (_) => response;
        final store = InMemoryDeferredLinkStore();
        final instance = sdk(api, store: store);
        final links = <ResolvedDeepLink>[];
        instance.links.listen(links.add);
        expect(await launch(instance), DeferredLinkStatus.failed);
        await settle();
        expect(api.redeems, hasLength(1));
        expect(store.values[deferredDoneKey], '1');
        expect(links, isEmpty);
      });
    });

    test('an answer without payload and campaign gives empty ones', () async {
      final api = Api()
        ..onRedeem = (_) => http.Response(
          jsonEncode({
            'linkId': 'l',
            'appId': 'a',
            'routePath': '/x',
            'url': 'https://$host/abc?x=1',
            'deferred': true,
          }),
          200,
        );
      final instance = sdk(api);
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      expect(await launch(instance), DeferredLinkStatus.delivered);
      await settle();
      expect(links.single.payload, isEmpty);
      expect(links.single.campaign.isEmpty, isTrue);
      expect(links.single.uri, Uri.parse('https://$host/abc?x=1'));
    });
  });

  group('a normal link wins', () {
    test('the launch link arrived first: no request, superseded, done', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final asked = <String>[];
      final instance = sdk(
        api,
        store: store,
        source: FakeLinkSource(initialLink: invite),
        sources: [referrer('strybok_click=$clickId', asked)],
      );
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      expect(await launch(instance), DeferredLinkStatus.superseded);
      await settle();
      expect(asked, ['play']);
      expect(api.redeems, isEmpty);
      expect(store.values, {deferredAttemptsKey: '1', deferredDoneKey: '1'});
      expect(links.single.routePath, '/normal');
      expect(links.single.isDeferred, isFalse);
      expect(links.single.isProbabilisticMatch, isFalse);
      expect(api.events, hasLength(1), reason: 'the normal link still reports its app open');
    });

    test('a link that arrives while the request is in flight wins', () async {
      final api = Api();
      final answer = Completer<http.Response>();
      api.onRedeem = (_) => answer.future;
      final store = InMemoryDeferredLinkStore();
      final source = FakeLinkSource();
      final instance = sdk(api, store: store, source: source);
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      await instance.initialize();
      await settle();
      expect(api.redeems, hasLength(1));
      source.emit(invite);
      await settle();
      answer.complete(deferredOk());
      await finished(instance);
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.superseded);
      expect(store.values[deferredDoneKey], '1');
      expect(links.map((link) => link.routePath), ['/normal']);
    });

    test('a link of ours that fails to resolve still supersedes', () async {
      final api = Api()..onResolve = (_) => http.Response('', 404);
      final failures = <StrybokException>[];
      final instance = Strybok(
        apiBaseUrl: apiBase,
        allowedHosts: {host},
        linkSource: FakeLinkSource(initialLink: invite),
        httpClient: api.client,
        onError: failures.add,
        deferredLinks: true,
        installReferrerSources: [referrer('strybok_click=$clickId')],
        androidPackageName: package,
        deferredLinkStore: InMemoryDeferredLinkStore(),
      );
      addTearDown(instance.dispose);
      expect(await launch(instance), DeferredLinkStatus.superseded);
      expect(api.redeems, isEmpty);
      expect(failures.single, isA<LinkNotFoundException>());
    });

    test('a URL that is not ours does not supersede', () async {
      final api = Api();
      final instance = sdk(
        api,
        source: FakeLinkSource(initialLink: Uri.parse('https://other.example.com/abc')),
      );
      expect(await launch(instance), DeferredLinkStatus.delivered);
    });

    test('resolveUri does not supersede', () async {
      final api = Api();
      final answer = Completer<http.Response>();
      api.onRedeem = (_) => answer.future;
      final instance = sdk(api);
      await instance.initialize();
      await settle();
      await instance.resolveUri(invite);
      answer.complete(deferredOk());
      await finished(instance);
      expect(instance.deferredLinkStatus, DeferredLinkStatus.delivered);
    });
  });

  group('once only, across restarts', () {
    test('after a delivery the next launch does nothing', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      expect(await launch(sdk(api, store: store)), DeferredLinkStatus.delivered);

      final asked = <String>[];
      final second = sdk(api, store: store, sources: [referrer('strybok_click=$clickId', asked)]);
      final links = <ResolvedDeepLink>[];
      second.links.listen(links.add);
      expect(await launch(second), DeferredLinkStatus.notFirstLaunch);
      await settle();
      expect(asked, isEmpty);
      expect(api.redeems, hasLength(1));
      expect(links, isEmpty);
    });

    for (final ended in [
      DeferredLinkStatus.notFound,
      DeferredLinkStatus.failed,
      DeferredLinkStatus.noReferrer,
      DeferredLinkStatus.unavailable,
      DeferredLinkStatus.superseded,
    ]) {
      test('after $ended the next launch is notFirstLaunch', () async {
        final api = Api();
        if (ended == DeferredLinkStatus.notFound) api.onRedeem = (_) => http.Response('', 404);
        if (ended == DeferredLinkStatus.failed) api.onRedeem = (_) => http.Response('x', 200);
        final store = InMemoryDeferredLinkStore();
        final first = sdk(
          api,
          store: store,
          source: FakeLinkSource(
            initialLink: ended == DeferredLinkStatus.superseded ? invite : null,
          ),
          sources: switch (ended) {
            DeferredLinkStatus.noReferrer => [referrer('utm_source=x')],
            DeferredLinkStatus.unavailable => [],
            _ => null,
          },
        );
        expect(await launch(first), ended);
        final requests = api.deferredRequests;
        expect(await launch(sdk(api, store: store)), DeferredLinkStatus.notFirstLaunch);
        expect(api.deferredRequests, requests);
      });
    }

    test('a launch that dies during the check has used one of three attempts', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      for (var launchNumber = 1; launchNumber <= 3; launchNumber++) {
        // The source never answers and the process is "killed".
        final instance = sdk(
          api,
          store: store,
          sources: [() => Completer<InstallReferrerAnswer>().future],
        );
        await instance.initialize();
        await settle();
        expect(store.values, {deferredAttemptsKey: '$launchNumber'});
        await instance.dispose();
      }
      final asked = <String>[];
      final fourth = sdk(api, store: store, sources: [referrer('strybok_click=$clickId', asked)]);
      expect(await launch(fourth), DeferredLinkStatus.failed);
      expect(asked, isEmpty);
      expect(api.redeems, isEmpty);
      expect(store.values, {deferredAttemptsKey: '3', deferredDoneKey: '1'});
      expect(await launch(sdk(api, store: store)), DeferredLinkStatus.notFirstLaunch);
    });

    test('three launches without network, then failed', () async {
      final api = Api()..onRedeem = (_) => http.Response('', 503);
      final store = InMemoryDeferredLinkStore();
      for (var launchNumber = 1; launchNumber <= 3; launchNumber++) {
        final instance = sdk(api, store: store, maxRetries: 0);
        await instance.initialize();
        await settle();
        expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
        expect(store.values, {deferredAttemptsKey: '$launchNumber'});
      }
      expect(await launch(sdk(api, store: store, maxRetries: 0)), DeferredLinkStatus.failed);
      expect(api.redeems, hasLength(3));
    });

    test('a pending launch is followed by a launch that delivers', () async {
      final api = Api()..onRedeem = (_) => http.Response('', 429);
      final store = InMemoryDeferredLinkStore();
      final first = sdk(api, store: store);
      await first.initialize();
      await settle();
      expect(first.deferredLinkStatus, DeferredLinkStatus.pending);

      api.onRedeem = null;
      expect(await launch(sdk(api, store: store)), DeferredLinkStatus.delivered);
      expect(store.values, {deferredAttemptsKey: '2', deferredDoneKey: '1'});
    });

    test('a crash between the answer and the write of done sends the same id again', () async {
      final api = Api();
      final store = FlakyStore()..failWrites.add(deferredDoneKey);
      final first = sdk(api, store: store);
      final links = <ResolvedDeepLink>[];
      first.links.listen(links.add);
      expect(await launch(first), DeferredLinkStatus.failed);
      await settle();
      expect(links, isEmpty, reason: 'without a stored done nothing is delivered');
      expect(store.values, {deferredAttemptsKey: '1'});

      store.failWrites.clear();
      expect(await launch(sdk(api, store: store)), DeferredLinkStatus.delivered);
      expect(api.redeems.map((request) => request.body).toSet(), hasLength(1));
    });

    test('a stored attempts value that is not a number counts as used up', () async {
      final store = InMemoryDeferredLinkStore({deferredAttemptsKey: 'many'});
      final api = Api();
      expect(await launch(sdk(api, store: store)), DeferredLinkStatus.failed);
      expect(api.redeems, isEmpty);
    });
  });

  group('store failures', () {
    test('a store that cannot be read → pending, nothing asked or sent', () async {
      final api = Api();
      final store = FlakyStore()..failReads = true;
      final asked = <String>[];
      final instance = sdk(api, store: store, sources: [referrer('strybok_click=$clickId', asked)]);
      await instance.initialize();
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
      expect(asked, isEmpty);
      expect(api.deferredRequests, 0);
    });

    test('attempts cannot be written → pending, nothing asked or sent', () async {
      final api = Api();
      final store = FlakyStore()..failWrites.add(deferredAttemptsKey);
      final asked = <String>[];
      final instance = sdk(api, store: store, sources: [referrer('strybok_click=$clickId', asked)]);
      await instance.initialize();
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
      expect(asked, isEmpty);
      expect(api.deferredRequests, 0);
    });

    test('a failed write of done elsewhere keeps the computed status', () async {
      final store = FlakyStore()..failWrites.add(deferredDoneKey);
      final instance = sdk(Api(), store: store, sources: [referrer('x=1')]);
      expect(await launch(instance), DeferredLinkStatus.noReferrer);
    });
  });

  group('enabling later and disposing', () {
    test('enableDeferredLinks after initialize runs the check once', () async {
      final api = Api();
      final asked = <String>[];
      final instance = sdk(
        api,
        deferredLinks: false,
        sources: [referrer('strybok_click=$clickId', asked)],
      );
      await instance.initialize();
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.disabled);
      expect(asked, isEmpty);

      instance.enableDeferredLinks();
      instance.enableDeferredLinks();
      await finished(instance);
      expect(instance.deferredLinkStatus, DeferredLinkStatus.delivered);
      instance.enableDeferredLinks();
      await settle();
      expect(asked, ['play']);
      expect(api.redeems, hasLength(1));
    });

    test('enableDeferredLinks before initialize waits for it', () async {
      final api = Api();
      final asked = <String>[];
      final instance = sdk(
        api,
        deferredLinks: false,
        sources: [referrer('strybok_click=$clickId', asked)],
      );
      instance.enableDeferredLinks();
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
      expect(asked, isEmpty);
      expect(await launch(instance), DeferredLinkStatus.delivered);
      expect(asked, ['play']);
    });

    test('the check does not run before or without initialize', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(api, store: store);
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
      expect(store.values, isEmpty);
      expect(api.deferredRequests, 0);
    });

    test('initialize twice runs the check once', () async {
      final api = Api();
      final instance = sdk(api);
      await instance.initialize();
      await instance.initialize();
      await finished(instance);
      await settle();
      expect(api.redeems, hasLength(1));
    });

    test('disposed while the request is in flight: done is stored, nothing delivered', () async {
      final api = Api();
      final answer = Completer<http.Response>();
      api.onRedeem = (_) => answer.future;
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(api, store: store);
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      await instance.initialize();
      await settle();
      await instance.dispose();
      answer.complete(deferredOk());
      await settle();
      expect(links, isEmpty);
      expect(store.values[deferredDoneKey], '1');
    });

    test('nothing happens after dispose', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(api, store: store, deferredLinks: false);
      await instance.initialize();
      await instance.dispose();
      instance.enableDeferredLinks();
      instance.skipPastedLink();
      await settle();
      expect(api.deferredRequests, 0);
      expect(store.values, isEmpty);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.disabled);
      expect(api.deferredRequests, 0);
    });
  });

  group('iOS: pasted link', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test('without matching nothing is automatic: unavailable, nothing stored or sent', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final asked = <String>[];
      final instance = sdk(
        api,
        store: store,
        sources: [referrer('strybok_click=$clickId', asked)],
        deviceFamily: () => 'iphone',
        locale: () => 'en-GB',
      );
      expect(await launch(instance), DeferredLinkStatus.unavailable);
      await settle();
      expect(asked, isEmpty, reason: 'there is no install referrer on iOS');
      expect(api.deferredRequests, 0);
      expect(store.values, isEmpty);
    });

    test('delivers the pasted link with the exact request, even after a normal link', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(
        api,
        store: store,
        source: FakeLinkSource(initialLink: invite),
      );
      final links = <ResolvedDeepLink>[];
      final doneAtDelivery = <String?>[];
      instance.links.listen((link) {
        links.add(link);
        doneAtDelivery.add(store.values[deferredDoneKey]);
      });
      await launch(instance);
      await settle();
      expect(links.single.isDeferred, isFalse);

      expect(await instance.redeemPastedLink('  $pasted\n'), PastedLinkResult.delivered);
      await settle();
      final request = api.redeems.single;
      expect('${request.url}', 'https://api.example.com/v1/public/deferred-links/redeem');
      expect(request.headers['content-type'], 'application/json');
      expect(request.headers['accept'], 'application/json');
      expect(
        request.body,
        '{"platform":"ios","clickId":"$clickId","bundleId":"$bundle","sdkVersion":"0.3.0"}',
      );
      expect(links, hasLength(2));
      expect(links.last.uri, Uri.parse('https://$host/invite777'));
      expect(links.last.isDeferred, isTrue);
      expect(links.last.isProbabilisticMatch, isFalse);
      expect(doneAtDelivery.last, '1');
      expect(instance.deferredLinkStatus, DeferredLinkStatus.delivered);
      expect(store.values, {deferredDoneKey: '1'});
      expect(api.events, hasLength(1), reason: 'only the normal link reports an app open');
      expect(await instance.getInitialLink(), isNull);
    });

    test('works before initialize and is queued until a listener attaches', () async {
      final api = Api();
      final instance = sdk(api);
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.delivered);
      expect(await instance.getInitialLink(), isNull);
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      await settle();
      expect(links.single.isDeferred, isTrue);
      expect(instance.deferredLinkStatus, DeferredLinkStatus.delivered);
    });

    final notOurs = <String?>[
      null,
      '',
      '   ',
      'hello',
      'https://$host/invite777',
      'https://$host/invite777?utm_source=x',
      'https://$host/invite777?strybok_click=dc_short',
      'https://$host/invite777?strybok_click=bad&strybok_click=$clickId',
      'https://$host/invite777?xstrybok_click=$clickId',
      'https://$host/invite777#strybok_click=$clickId',
      'https://evil.example.com/invite777?strybok_click=$clickId',
      'http://$host/invite777?strybok_click=$clickId',
      'https://$host:8443/invite777?strybok_click=$clickId',
      'https://user@$host/invite777?strybok_click=$clickId',
      'https://$host/a/b?strybok_click=$clickId',
      'see https://$host/invite777?strybok_click=$clickId',
      'strybok_click=$clickId',
    ];
    for (final text in notOurs) {
      test('"$text" is notOurs: no request, nothing stored', () async {
        final api = Api();
        final store = InMemoryDeferredLinkStore();
        final instance = sdk(api, store: store);
        await launch(instance);
        expect(await instance.redeemPastedLink(text), PastedLinkResult.notOurs);
        expect(api.deferredRequests, 0);
        expect(store.values, isEmpty);
        expect(instance.deferredLinkStatus, DeferredLinkStatus.unavailable);
      });
    }

    test(
      'the first strybok_click parameter is used; host case and other keys do not matter',
      () async {
        final api = Api();
        final instance = sdk(api);
        final text =
            'https://MY-APP-123.links.example.com/invite777'
            '?utm_source=x&strybok%5Fclick=$clickId&strybok_click=$otherId#top';
        expect(await instance.redeemPastedLink(text), PastedLinkResult.delivered);
        expect((jsonDecode(api.redeems.single.body) as Map)['clickId'], clickId);
      },
    );

    for (final status in [404, 400, 410, 422]) {
      test('$status → notFound, done; pasting again is alreadyHandled', () async {
        final api = Api()..onRedeem = (_) => http.Response('', status);
        final store = InMemoryDeferredLinkStore();
        final instance = sdk(api, store: store);
        expect(await instance.redeemPastedLink(pasted), PastedLinkResult.notFound);
        expect(store.values, {deferredDoneKey: '1'});
        expect(instance.deferredLinkStatus, DeferredLinkStatus.notFound);
        expect(await instance.redeemPastedLink(pasted), PastedLinkResult.alreadyHandled);
        expect(api.redeems, hasLength(1));
      });
    }

    test('an unusable 200 → failed, done', () async {
      final api = Api()..onRedeem = (_) => deferredOk(url: 'https://evil.example.com/x');
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(api, store: store);
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.failed);
      await settle();
      expect(links, isEmpty);
      expect(store.values, {deferredDoneKey: '1'});
      expect(instance.deferredLinkStatus, DeferredLinkStatus.failed);
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.alreadyHandled);
    });

    test('429 is not retried: failed, done not stored, the person can paste again', () async {
      final api = Api()..onRedeem = (_) => http.Response('', 429);
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(api, store: store);
      await launch(instance);
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.failed);
      expect(api.redeems, hasLength(1));
      expect(store.values, isEmpty);
      expect(instance.deferredLinkStatus, DeferredLinkStatus.unavailable);

      api.onRedeem = null;
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.delivered);
    });

    test('5xx and transport failures are retried with the identical body, then failed', () async {
      var calls = 0;
      final api = Api()
        ..onRedeem = (_) {
          if (calls++ == 0) return http.Response('', 502);
          throw http.ClientException('offline');
        };
      final store = InMemoryDeferredLinkStore();
      final instance = sdk(api, store: store);
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.failed);
      expect(api.redeems, hasLength(3));
      expect(api.redeems.map((request) => request.body).toSet(), hasLength(1));
      expect(store.values, isEmpty);
    });

    test('alreadyHandled in a later launch, without a request', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      expect(await sdk(api, store: store).redeemPastedLink(pasted), PastedLinkResult.delivered);
      final second = sdk(api, store: store);
      expect(await launch(second), DeferredLinkStatus.notFirstLaunch);
      expect(await second.redeemPastedLink(pasted), PastedLinkResult.alreadyHandled);
      expect(api.redeems, hasLength(1));
    });

    test('calls are serialized: the second waits and is alreadyHandled', () async {
      final api = Api();
      final answer = Completer<http.Response>();
      api.onRedeem = (_) => answer.future;
      final instance = sdk(api);
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      final first = instance.redeemPastedLink(pasted);
      final second = instance.redeemPastedLink(pasted);
      await settle();
      expect(api.redeems, hasLength(1));
      answer.complete(deferredOk());
      expect(await first, PastedLinkResult.delivered);
      expect(await second, PastedLinkResult.alreadyHandled);
      await settle();
      expect(api.redeems, hasLength(1));
      expect(links, hasLength(1));
    });

    test(
      'store failures: unreadable → failed; done not writable → failed, nothing delivered',
      () async {
        final api = Api();
        final unreadable = FlakyStore()..failReads = true;
        expect(await sdk(api, store: unreadable).redeemPastedLink(pasted), PastedLinkResult.failed);
        expect(api.redeems, isEmpty);

        final unwritable = FlakyStore()..failWrites.add(deferredDoneKey);
        final instance = sdk(api, store: unwritable);
        final links = <ResolvedDeepLink>[];
        instance.links.listen(links.add);
        expect(await instance.redeemPastedLink(pasted), PastedLinkResult.failed);
        await settle();
        expect(links, isEmpty);
      },
    );

    test(
      'disposed while the request is in flight: failed, done stored, nothing delivered',
      () async {
        final api = Api();
        final answer = Completer<http.Response>();
        api.onRedeem = (_) => answer.future;
        final store = InMemoryDeferredLinkStore();
        final instance = sdk(api, store: store);
        final links = <ResolvedDeepLink>[];
        instance.links.listen(links.add);
        final result = instance.redeemPastedLink(pasted);
        await settle();
        await instance.dispose();
        answer.complete(deferredOk());
        expect(await result, PastedLinkResult.failed);
        expect(links, isEmpty);
        expect(store.values, {deferredDoneKey: '1'});
      },
    );
  });

  group('iOS: probabilistic matching', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    Strybok matching(
      Api api, {
      DeferredLinkStore? store,
      FakeLinkSource? source,
      FutureOr<String?> Function()? deviceFamily,
      FutureOr<String?> Function()? locale,
      bool noCallbacks = false,
      Future<bool> Function()? pasteboardMayContainLink,
      int maxRetries = 2,
    }) => sdk(
      api,
      store: store,
      source: source,
      allowProbabilisticMatching: true,
      deviceFamily: noCallbacks ? null : (deviceFamily ?? () => 'iphone'),
      locale: noCallbacks ? null : (locale ?? () async => 'en-GB'),
      pasteboardMayContainLink: pasteboardMayContainLink,
      maxRetries: maxRetries,
    );

    test('delivers a match, marked as a guess, with the exact request', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final instance = matching(api, store: store);
      final links = <ResolvedDeepLink>[];
      final doneAtDelivery = <String?>[];
      instance.links.listen((link) {
        links.add(link);
        doneAtDelivery.add(store.values[deferredDoneKey]);
      });
      expect(await launch(instance), DeferredLinkStatus.delivered);
      await settle();
      final request = api.matches.single;
      expect('${request.url}', 'https://api.example.com/v1/public/deferred-links/match');
      expect(request.headers['content-type'], 'application/json');
      expect(request.headers['accept'], 'application/json');
      expect(
        request.body,
        '{"platform":"ios","bundleId":"$bundle","deviceFamily":"iphone","locale":"en-GB",'
        '"sdkVersion":"0.3.0"}',
      );
      expect(links.single.isDeferred, isTrue);
      expect(links.single.isProbabilisticMatch, isTrue);
      expect(links.single.uri, Uri.parse('https://$host/invite777'));
      expect(doneAtDelivery, ['1']);
      expect(store.values, {deferredAttemptsKey: '1', deferredDoneKey: '1'});
      expect(api.events, isEmpty);
      expect(api.redeems, isEmpty);
      expect(await instance.getInitialLink(), isNull);
    });

    test('initialize does not wait for the match', () async {
      final api = Api()..onMatch = (_) => Completer<http.Response>().future;
      final instance = matching(api);
      await instance.initialize();
      await finished(instance, DeferredLinkStatus.checking);
    });

    test('200 without matched: "probabilistic" → failed, done', () async {
      for (final response in [deferredOk(), deferredOk(matched: 'exact')]) {
        final api = Api()..onMatch = (_) => response;
        final store = InMemoryDeferredLinkStore();
        final instance = matching(api, store: store);
        final links = <ResolvedDeepLink>[];
        instance.links.listen(links.add);
        expect(await launch(instance), DeferredLinkStatus.failed);
        await settle();
        expect(links, isEmpty);
        expect(store.values[deferredDoneKey], '1');
      }
    });

    test('200 with a foreign url → failed; 404 and 422 → notFound; all done', () async {
      final answers = <http.Response, DeferredLinkStatus>{
        deferredOk(matched: 'probabilistic', url: 'https://evil.example.com/abc'):
            DeferredLinkStatus.failed,
        http.Response('', 404): DeferredLinkStatus.notFound,
        http.Response('', 422): DeferredLinkStatus.notFound,
      };
      for (final MapEntry(key: response, value: expected) in answers.entries) {
        final api = Api()..onMatch = (_) => response;
        final store = InMemoryDeferredLinkStore();
        expect(await launch(matching(api, store: store)), expected);
        expect(api.matches, hasLength(1));
        expect(store.values[deferredDoneKey], '1');
      }
    });

    test(
      '429 → pending without retry; 5xx → pending after retries; three launches → failed',
      () async {
        final api = Api()..onMatch = (_) => http.Response('', 429);
        final store = InMemoryDeferredLinkStore();
        final first = matching(api, store: store);
        await first.initialize();
        await settle();
        expect(first.deferredLinkStatus, DeferredLinkStatus.pending);
        expect(api.matches, hasLength(1));

        api.onMatch = (_) => http.Response('', 500);
        for (var launchNumber = 2; launchNumber <= 3; launchNumber++) {
          final instance = matching(api, store: store, maxRetries: 1);
          await instance.initialize();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(instance.deferredLinkStatus, DeferredLinkStatus.pending);
          expect(store.values, {deferredAttemptsKey: '$launchNumber'});
        }
        expect(api.matches, hasLength(5));
        expect(api.matches.map((request) => request.body).toSet(), hasLength(1));
        expect(await launch(matching(api, store: store)), DeferredLinkStatus.failed);
        expect(api.matches, hasLength(5));
        expect(await launch(matching(api, store: store)), DeferredLinkStatus.notFirstLaunch);
      },
    );

    test('a normal link first → superseded, done, no request', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final instance = matching(
        api,
        store: store,
        source: FakeLinkSource(initialLink: invite),
      );
      expect(await launch(instance), DeferredLinkStatus.superseded);
      expect(api.matches, isEmpty);
      expect(store.values, {deferredAttemptsKey: '1', deferredDoneKey: '1'});
    });

    test('a normal link during the request → superseded, nothing delivered twice', () async {
      final api = Api();
      final answer = Completer<http.Response>();
      api.onMatch = (_) => answer.future;
      final source = FakeLinkSource();
      final instance = matching(api, source: source);
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      await instance.initialize();
      await settle();
      source.emit(invite);
      await settle();
      answer.complete(deferredOk(matched: 'probabilistic'));
      await finished(instance);
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.superseded);
      expect(links.map((link) => link.isDeferred), [false]);
    });

    final unusable = <String, (FutureOr<String?> Function()?, FutureOr<String?> Function()?)>{
      'a Mac': (() => 'mac', () => 'en-GB'),
      'an upper-case family': (() => 'iPhone', () => 'en-GB'),
      'no family': (() => null, () => 'en-GB'),
      'a throwing family callback': (() => throw StateError('x'), () => 'en-GB'),
      'no language': (() => 'ipad', () => null),
      'an empty language': (() => 'ipad', () => ''),
      'a language that is not a tag': (() => 'ipod', () => 'English (UK)'),
      'a throwing language callback': (() => 'ipod', () async => throw StateError('x')),
    };
    unusable.forEach((name, callbacks) {
      test('$name → unavailable, done, no request', () async {
        final api = Api();
        final store = InMemoryDeferredLinkStore();
        final instance = matching(
          api,
          store: store,
          deviceFamily: callbacks.$1,
          locale: callbacks.$2,
        );
        expect(await launch(instance), DeferredLinkStatus.unavailable);
        expect(api.matches, isEmpty);
        expect(store.values, {deferredAttemptsKey: '1', deferredDoneKey: '1'});
      });
    });

    test('without the two callbacks → unavailable, done, no request', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      expect(
        await launch(matching(api, store: store, noCallbacks: true)),
        DeferredLinkStatus.unavailable,
      );
      expect(api.matches, isEmpty);
      expect(store.values[deferredDoneKey], '1');
    });

    test('every device family and an underscore locale are sent as given', () async {
      for (final family in ['iphone', 'ipad', 'ipod']) {
        final api = Api();
        final instance = matching(api, deviceFamily: () => family, locale: () => 'zh_Hant_TW');
        expect(await launch(instance), DeferredLinkStatus.delivered);
        final body = jsonDecode(api.matches.single.body) as Map;
        expect(body['deviceFamily'], family);
        expect(body['locale'], 'zh_Hant_TW');
      }
    });

    test('the clipboard may hold a link → awaitingPaste; notOurs then starts matching', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final instance = matching(api, store: store, pasteboardMayContainLink: () async => true);
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      await instance.initialize();
      await finished(instance, DeferredLinkStatus.awaitingPaste);
      await settle();
      expect(api.deferredRequests, 0);
      expect(store.values, isEmpty);

      expect(await instance.redeemPastedLink('my shopping list'), PastedLinkResult.notOurs);
      await finished(instance, DeferredLinkStatus.delivered);
      await settle();
      expect(api.redeems, isEmpty);
      expect(api.matches, hasLength(1));
      expect(links.single.isProbabilisticMatch, isTrue);
      // Matching runs once only.
      expect(await instance.redeemPastedLink('again'), PastedLinkResult.alreadyHandled);
      instance.skipPastedLink();
      await settle();
      expect(api.matches, hasLength(1));
    });

    test('skipPastedLink starts matching, once', () async {
      final api = Api();
      final instance = matching(api, pasteboardMayContainLink: () async => true);
      await instance.initialize();
      await finished(instance, DeferredLinkStatus.awaitingPaste);
      instance.skipPastedLink();
      instance.skipPastedLink();
      await finished(instance, DeferredLinkStatus.delivered);
      await settle();
      expect(api.matches, hasLength(1));
    });

    test('a pasted link of ours ends it: matching never runs', () async {
      final api = Api();
      final store = InMemoryDeferredLinkStore();
      final instance = matching(api, store: store, pasteboardMayContainLink: () async => true);
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      await instance.initialize();
      await finished(instance, DeferredLinkStatus.awaitingPaste);
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.delivered);
      instance.skipPastedLink();
      await settle();
      expect(api.matches, isEmpty);
      expect(links.single.isProbabilisticMatch, isFalse);
      expect(instance.deferredLinkStatus, DeferredLinkStatus.delivered);
      expect(store.values, {deferredDoneKey: '1'});
    });

    test('a paste that fails for now keeps waiting; the person can paste again', () async {
      final api = Api()..onRedeem = (_) => http.Response('', 429);
      final instance = matching(api, pasteboardMayContainLink: () async => true);
      await instance.initialize();
      await finished(instance, DeferredLinkStatus.awaitingPaste);
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.failed);
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.awaitingPaste);
      expect(api.matches, isEmpty);
    });

    test('the clipboard holds nothing, or the callback throws → matching starts at once', () async {
      for (final Future<bool> Function() callback in [
        () async => false,
        () async => throw StateError('x'),
      ]) {
        final api = Api();
        final instance = matching(api, pasteboardMayContainLink: callback);
        expect(await launch(instance), DeferredLinkStatus.delivered);
        expect(api.matches, hasLength(1));
      }
    });

    test('skipPastedLink does nothing when the SDK is not waiting', () async {
      final api = Api();
      final instance = matching(api);
      expect(await launch(instance), DeferredLinkStatus.delivered);
      instance.skipPastedLink();
      await settle();
      expect(api.matches, hasLength(1));

      final plain = sdk(Api());
      await launch(plain);
      plain.skipPastedLink();
      await settle();
      expect(plain.deferredLinkStatus, DeferredLinkStatus.unavailable);
    });

    test('a paste delivered while the match is in flight wins; one delivery', () async {
      final api = Api();
      final answer = Completer<http.Response>();
      api.onMatch = (_) => answer.future;
      final instance = matching(api);
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      await instance.initialize();
      await settle();
      expect(api.matches, hasLength(1));
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.delivered);
      answer.complete(deferredOk(matched: 'probabilistic'));
      await settle();
      expect(links, hasLength(1));
      expect(links.single.isProbabilisticMatch, isFalse);
      expect(instance.deferredLinkStatus, DeferredLinkStatus.delivered);
    });

    test('a match delivered while a paste is in flight: the paste is alreadyHandled', () async {
      final api = Api();
      final redeem = Completer<http.Response>();
      api.onRedeem = (_) => redeem.future;
      final match = Completer<http.Response>();
      api.onMatch = (_) => match.future;
      final instance = matching(api);
      final links = <ResolvedDeepLink>[];
      instance.links.listen(links.add);
      await instance.initialize();
      await settle();
      final result = instance.redeemPastedLink(pasted);
      await settle();
      match.complete(deferredOk(matched: 'probabilistic'));
      await finished(instance, DeferredLinkStatus.delivered);
      redeem.complete(deferredOk());
      expect(await result, PastedLinkResult.alreadyHandled);
      await settle();
      expect(links, hasLength(1));
      expect(links.single.isProbabilisticMatch, isTrue);
    });

    test('enableDeferredLinks later runs matching once', () async {
      final api = Api();
      final instance = sdk(
        api,
        deferredLinks: false,
        allowProbabilisticMatching: true,
        deviceFamily: () => 'iphone',
        locale: () => 'uk',
      );
      await instance.initialize();
      await settle();
      expect(instance.deferredLinkStatus, DeferredLinkStatus.disabled);
      expect(await instance.redeemPastedLink(pasted), PastedLinkResult.disabled);
      instance.enableDeferredLinks();
      instance.enableDeferredLinks();
      await finished(instance);
      expect(instance.deferredLinkStatus, DeferredLinkStatus.delivered);
      expect(api.matches, hasLength(1));
    });
  });

  test('InstallReferrerAnswer never prints the referrer', () {
    const answer = InstallReferrerAnswer.referrer('strybok_click=$clickId');
    expect('$answer', isNot(contains('dc_')));
    expect(answer.referrer, 'strybok_click=$clickId');
    expect(InstallReferrerAnswer.unavailable.referrer, isNull);
    expect(InstallReferrerAnswer.unavailableForNow.referrer, isNull);
  });

  test('every link has isDeferred and isProbabilisticMatch, false by default', () async {
    final link = ResolvedDeepLink(
      uri: invite,
      linkId: 'l',
      appId: 'a',
      routePath: '/x',
      payload: const {},
    );
    expect(link.isDeferred, isFalse);
    expect(link.isProbabilisticMatch, isFalse);
    final api = Api();
    final resolvedLink = await sdk(api, deferredLinks: false).resolveUri(invite);
    expect(resolvedLink.isDeferred, isFalse);
    expect(resolvedLink.isProbabilisticMatch, isFalse);
  });
}
