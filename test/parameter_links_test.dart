// Links without an API call (SDK contract, "Links without an API call"; decision 0035): every
// case of the shared test vectors, through the launch link, the link stream and resolveUrl, and
// the behaviour around them.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strybok/src/parameter_links.dart' show decodeQueryText, encodeQueryValue;
import 'package:strybok/strybok.dart';
import 'package:strybok/testing.dart';

final api = Uri.parse('https://api.example.com');

/// A byte-identical copy of the shared file of the SDK contract.
final vectors =
    jsonDecode(File('test/fixtures/parameter-links-vectors.json').readAsStringSync())
        as Map<String, Object?>;

final allowedHosts = {
  for (final host in vectors['allowedHosts']! as List<Object?>) host! as String,
};

const host = 'myapp.strybok.link';
const keys = ParameterLinks(payloadKeys: ['id', 'lang']);
const clickId = 'dc_0123456789abcdefghijABCDEFGHIJ01';

ParameterLinks? optionOf(Object? json) => json == null
    ? null
    : ParameterLinks(
        payloadKeys: [
          for (final key in (json as Map<String, Object?>)['payloadKeys']! as List<Object?>)
            key! as String,
        ],
      );

/// The resolve request for [lookup], with `url` encoded the way the SDK always encoded it.
String resolveUrlFor(String lookup) =>
    '${api.replace(path: '/v1/public/resolve', queryParameters: {'url': lookup})}';

http.Response resolved([Map<String, Object?> extra = const {}]) => http.Response(
  jsonEncode({
    'linkId': 'plk_paths',
    'appId': 'app_1',
    'routePath': '/from-the-server',
    'payload': {'id': 'server'},
    ...extra,
  }),
  200,
);

/// Records every request by endpoint.
class Api {
  Api([this.onResolve]);

  FutureOr<http.Response> Function(http.Request request)? onResolve;
  FutureOr<http.Response> Function(http.Request request)? onRedeem;
  FutureOr<http.Response> Function(http.Request request)? onMatch;
  final resolves = <http.Request>[];
  final events = <http.Request>[];
  final redeems = <http.Request>[];
  final matches = <http.Request>[];

  late final client = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/v1/public/events')) {
      events.add(request);
      return http.Response('', 202);
    }
    if (path.endsWith('/v1/public/deferred-links/redeem')) {
      redeems.add(request);
      return await (onRedeem?.call(request) ?? http.Response('', 404));
    }
    if (path.endsWith('/v1/public/deferred-links/match')) {
      matches.add(request);
      return await (onMatch?.call(request) ?? http.Response('', 404));
    }
    resolves.add(request);
    return await (onResolve?.call(request) ?? resolved());
  });
}

Strybok sdk(
  Api api_, {
  ParameterLinks? parameterLinks = keys,
  LinkSource? source,
  List<StrybokException>? errors,
  DateTime Function()? clock,
  bool deferredLinks = false,
  bool allowProbabilisticMatching = false,
  List<InstallReferrerSource> installReferrerSources = const [],
}) {
  final instance = Strybok(
    apiBaseUrl: api,
    allowedHosts: allowedHosts,
    parameterLinks: parameterLinks,
    linkSource: source ?? FakeLinkSource(),
    httpClient: api_.client,
    timeout: const Duration(milliseconds: 60),
    retryDelay: const Duration(milliseconds: 1),
    onError: errors?.add,
    clock: clock,
    deferredLinks: deferredLinks,
    allowProbabilisticMatching: allowProbabilisticMatching,
    installReferrerSources: installReferrerSources,
    androidPackageName: 'com.example.app',
    iosBundleId: 'com.example.App',
    deviceFamily: () => 'iphone',
    locale: () => 'en-GB',
    deferredLinkStore: InMemoryDeferredLinkStore(),
  );
  addTearDown(instance.dispose);
  return instance;
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

/// Waits until the deferred-link check has reached [status].
Future<void> statusReached(Strybok instance, DeferredLinkStatus status) async {
  for (var i = 0; i < 2000 && instance.deferredLinkStatus != status; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(instance.deferredLinkStatus, status);
}

/// A link source of an app that only has parsed URIs.
class UriOnlySource implements LinkSource {
  final controller = StreamController<Uri>.broadcast();

  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<Uri> get uriStream => controller.stream;
}

void main() {
  group('shared vectors: lookups', () {
    for (final entry in vectors['lookups']! as List<Object?>) {
      final vector = entry! as Map<String, Object?>;
      final url = vector['url']! as String;
      final lookup = vector['lookup'] as String?;
      final option = optionOf(vector['parameterLinks']);

      test(vector['name']! as String, () async {
        final errors = <StrybokException>[];

        // The link that launched the app.
        final launchApi = Api();
        final launch = sdk(
          launchApi,
          parameterLinks: option,
          source: FakeLinkSource(initialLinkString: url),
          errors: errors,
        );
        await launch.initialize();

        // A link that arrives while the app runs.
        final runningApi = Api();
        final source = FakeLinkSource();
        final running = sdk(runningApi, parameterLinks: option, source: source, errors: errors);
        await running.initialize();
        source.emitString(url);
        await settle();

        // The explicit call.
        final manualApi = Api();
        final manual = sdk(manualApi, parameterLinks: option);
        expect(manual.isStrybokUrl(url), lookup != null);

        if (lookup == null) {
          await expectLater(manual.resolveUrl(url), throwsA(isA<UnsupportedLinkException>()));
          expect(await launch.getInitialLink(), isNull);
          for (final recorded in [launchApi, runningApi, manualApi]) {
            expect(recorded.resolves, isEmpty, reason: 'not ours: no request');
          }
        } else {
          final link = await manual.resolveUrl(url);
          expect(link.uri, Uri.parse(url), reason: 'the link keeps the URL as received');
          expect((await launch.getInitialLink())?.uri, Uri.parse(url));
          for (final recorded in [launchApi, runningApi, manualApi]) {
            final request = recorded.resolves.single;
            expect('${request.url}', resolveUrlFor(lookup));
            expect(request.url.queryParameters, {'url': lookup});
            expect(request.method, 'GET');
            expect(request.headers, {'Accept': 'application/json'});
            expect(request.body, isEmpty);
          }
        }
        expect(errors, isEmpty);
      });
    }
  });

  group('shared vectors: configurations', () {
    for (final entry in vectors['configurations']! as List<Object?>) {
      final vector = entry! as Map<String, Object?>;
      final option = optionOf(vector['parameterLinks']);
      final valid = vector['valid']! as bool;

      test(vector['name']! as String, () {
        Strybok build() => Strybok(
          apiBaseUrl: api,
          allowedHosts: allowedHosts,
          parameterLinks: option,
          linkSource: FakeLinkSource(),
          httpClient: Api().client,
        );
        if (valid) {
          final instance = build();
          addTearDown(instance.dispose);
          expect(instance.parameterLinks, option);
        } else {
          expect(build, throwsArgumentError);
        }
      });
    }
  });

  group('the option', () {
    test('is off by default', () {
      final instance = Strybok(apiBaseUrl: api, allowedHosts: allowedHosts);
      addTearDown(instance.dispose);
      expect(instance.parameterLinks, isNull);
      expect(instance.isStrybokUrl('https://$host/product/42'), isFalse);
      expect(instance.isStrybokUrl('https://$host/promo'), isTrue);
    });

    test('an invalid one is an ArgumentError that names the option and the key', () {
      expect(
        () => Strybok(
          apiBaseUrl: api,
          allowedHosts: allowedHosts,
          parameterLinks: const ParameterLinks(payloadKeys: ['id', 'utm_medium']),
          httpClient: Api().client,
        ),
        throwsA(
          isA<ArgumentError>()
              .having((error) => error.name, 'name', 'parameterLinks')
              .having((error) => '${error.message}', 'message', contains('utm_medium')),
        ),
      );
    });

    test('the keys are copied: changing the list later changes nothing', () async {
      final list = ['id'];
      final api_ = Api();
      final instance = sdk(api_, parameterLinks: ParameterLinks(payloadKeys: list));
      list.add('lang');
      await instance.resolveUrl('https://$host/p/1?id=7&lang=uk');
      expect(api_.resolves.single.url.queryParameters, {'url': 'https://$host/p/1?id=7'});
    });

    test('ParameterLinks is a value', () {
      expect(
        ParameterLinks(payloadKeys: ['id', 'lang']),
        const ParameterLinks(payloadKeys: ['id', 'lang']),
      );
      expect(
        ParameterLinks(payloadKeys: ['id', 'lang']).hashCode,
        const ParameterLinks(payloadKeys: ['id', 'lang']).hashCode,
      );
      expect(keys, isNot(const ParameterLinks(payloadKeys: ['lang', 'id'])));
      expect('$keys', 'ParameterLinks(payloadKeys: [id, lang])');
    });
  });

  group('delivery', () {
    test('the route and payload come from the answer, never from the tapped URL', () async {
      final api_ = Api(
        (_) => resolved({
          'routePath': '/product/42',
          'payload': {'id': '7'},
          'campaign': {'source': 'mail'},
        }),
      );
      final source = FakeLinkSource();
      final instance = sdk(api_, source: source);
      final received = <ResolvedDeepLink>[];
      instance.links.listen(received.add);
      await instance.initialize();

      const tapped = 'https://$host/Product/42/?id=8&lang=uk&secret=x#top';
      source.emitString(tapped);
      await settle();

      expect(api_.resolves.single.url.queryParameters, {
        'url': 'https://$host/Product/42/?id=8&lang=uk',
      });
      final link = received.single;
      expect(link.routePath, '/product/42');
      expect(link.payload, {'id': '7'});
      expect(link.linkId, 'plk_paths');
      expect(link.campaign, const LinkCampaign(source: 'mail'));
      expect(link.uri, Uri.parse(tapped));
      expect(link.isDeferred, isFalse);
    });

    test('a long link is delivered with the route and payload the server read', () async {
      final api_ = Api((_) => resolved({'routePath': '/p', 'payload': <String, Object?>{}}));
      final instance = sdk(
        api_,
        source: FakeLinkSource(
          initialLinkString:
              'https://go.example.com/?link=https%3A%2F%2Fexample.com%2Fother%3Fid%3D1&apn=com.example.app',
        ),
      );
      final link = await instance.getInitialLink();
      expect(link?.routePath, '/p');
      expect(link?.payload, isEmpty);
    });

    test('app_open carries the linkId the server returned', () async {
      final api_ = Api(
        (_) => resolved({
          'linkId': 'plk_firebase',
          'campaign': {'source': 'mail'},
        }),
      );
      final source = FakeLinkSource();
      final instance = sdk(api_, source: source);
      instance.links.listen((_) {});
      await instance.initialize();
      source.emitString(
        'https://go.example.com/?link=https%3A%2F%2Fexample.com%2Fp&utm_source=newsletter',
      );
      await settle();

      final event = jsonDecode(api_.events.single.body) as Map<String, Object?>;
      expect(
        event.keys,
        unorderedEquals(['eventId', 'linkId', 'type', 'platform', 'sdkVersion', 'campaign']),
      );
      expect(event['linkId'], 'plk_firebase');
      expect(event['type'], 'app_open');
      expect(event['sdkVersion'], '0.4.0');
      expect(event['campaign'], {'source': 'mail'});
    });

    test('an address that is no link is a LinkNotFoundException, reported to onError', () async {
      final api_ = Api((_) => http.Response('{"error":{"code":"LINK_NOT_FOUND"}}', 404));
      final errors = <StrybokException>[];
      final source = FakeLinkSource();
      final instance = sdk(api_, source: source, errors: errors);
      await instance.initialize();
      source.emitString('https://$host/typo/1');
      await settle();
      expect(errors.single, isA<LinkNotFoundException>());
      expect(errors.single.uri, Uri.parse('https://$host/typo/1'));
      await expectLater(
        instance.resolveUrl('https://$host/typo/1'),
        throwsA(isA<LinkNotFoundException>()),
      );
    });

    test('duplicates are the same string as received, as before', () async {
      final now = DateTime(2026);
      final api_ = Api();
      final source = FakeLinkSource();
      final instance = sdk(api_, source: source, clock: () => now);
      final received = <ResolvedDeepLink>[];
      instance.links.listen(received.add);
      await instance.initialize();

      source.emitString('https://$host/product/42?id=7');
      source.emitString('https://$host/product/42?id=7');
      await settle();
      expect(received, hasLength(1));

      // The same lookup from two different strings is two links.
      source.emitString('https://$host/product/42?id=7&x=1');
      await settle();
      expect(received, hasLength(2));
      expect(api_.resolves.map((request) => '${request.url}').toSet(), hasLength(1));
    });

    test('a link source with parsed URIs only is read as Uri.parse left the link', () async {
      final api_ = Api();
      final source = UriOnlySource();
      final instance = sdk(api_, source: source);
      final received = <ResolvedDeepLink>[];
      instance.links.listen(received.add);
      await instance.initialize();
      source.controller.add(Uri.parse('https://$host/product/42?id=7&ref=x'));
      // Uri.parse removed the dot segments: the SDK sees /b.
      source.controller.add(Uri.parse('https://$host/a/../b'));
      await settle();
      expect(api_.resolves.map((request) => request.url.queryParameters['url']), [
        'https://$host/product/42?id=7',
        'https://$host/b',
      ]);
      expect(received, hasLength(2));
      await source.controller.close();
    });

    test('isStrybokUri and resolveUri read the Uri as Uri.parse left it', () async {
      final api_ = Api();
      final instance = sdk(api_);
      final long = Uri.parse('https://go.example.com/?link=https%3A%2F%2Fexample.com%2Fp');
      expect(instance.isStrybokUri(long), isTrue);
      expect(instance.isStrybokUri(Uri.parse('https://$host/product/42')), isTrue);
      expect(instance.isStrybokUri(Uri.parse('https://$host/favicon.ico')), isFalse);
      expect(instance.isStrybokUri(Uri.parse('https://evil.example.com/product/42')), isFalse);

      final link = await instance.resolveUri(Uri.parse('https://$host/product/42?lang=uk&x=1'));
      expect(link.uri, Uri.parse('https://$host/product/42?lang=uk&x=1'));
      expect(api_.resolves.single.url.queryParameters, {'url': 'https://$host/product/42?lang=uk'});
    });

    test('a slug that is also a reserved directory name stays a slug', () async {
      final api_ = Api();
      await sdk(api_).resolveUrl('https://$host/_strybok?id=7');
      expect(api_.resolves.single.url.queryParameters, {'url': 'https://$host/_strybok?id=7'});
    });
  });

  group('without the option', () {
    test('a link is read through Uri.parse and sent exactly as by 0.3.0', () async {
      for (final MapEntry(key: tapped, value: lookup) in {
        'https://$host/%61bc?id=7': 'https://$host/abc',
        'https://$host/x/../invite777': 'https://$host/invite777',
        'https://MyApp.strybok.link:443/invite777?utm_source=a&id=7#f':
            'https://$host/invite777?utm_source=a',
      }.entries) {
        final api_ = Api();
        final source = FakeLinkSource();
        final instance = sdk(api_, parameterLinks: null, source: source);
        await instance.initialize();
        source.emitString(tapped);
        await settle();
        expect(api_.resolves.single.url.queryParameters, {'url': lookup}, reason: tapped);
        expect('${api_.resolves.single.url}', resolveUrlFor(lookup), reason: tapped);
      }
    });

    test('path links and long links are not ours', () async {
      final api_ = Api();
      final source = FakeLinkSource();
      final errors = <StrybokException>[];
      final instance = sdk(api_, parameterLinks: null, source: source, errors: errors);
      await instance.initialize();
      for (final url in [
        'https://$host/product/42?id=7',
        'https://go.example.com/?link=https%3A%2F%2Fexample.com%2Fp',
        'https://$host?id=7',
      ]) {
        source.emitString(url);
        expect(instance.isStrybokUrl(url), isFalse, reason: url);
        await expectLater(instance.resolveUrl(url), throwsA(isA<UnsupportedLinkException>()));
      }
      await settle();
      expect(api_.resolves, isEmpty);
      expect(errors, isEmpty);
    });
  });

  group('deferred links keep the slug rule', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    http.Response deferred(String url, {String? matched}) => http.Response(
      jsonEncode({
        'linkId': 'link_7',
        'appId': 'app_1',
        'routePath': '/promo/42',
        'url': url,
        'deferred': true,
        'matched': ?matched,
      }),
      200,
    );

    InstallReferrerSource referrer() =>
        () async => const InstallReferrerAnswer.referrer('strybok_click=$clickId');

    for (final url in [
      'https://$host/product/42',
      'https://$host/',
      'https://go.example.com/?link=https%3A%2F%2Fexample.com%2Fp',
    ]) {
      test('a redeem answer with the URL $url is refused', () async {
        final api_ = Api()..onRedeem = (_) => deferred(url);
        final instance = sdk(api_, deferredLinks: true, installReferrerSources: [referrer()]);
        final received = <ResolvedDeepLink>[];
        instance.links.listen(received.add);
        await instance.initialize();
        await statusReached(instance, DeferredLinkStatus.failed);
        await settle();
        expect(api_.redeems, hasLength(1));
        expect(received, isEmpty);
      });
    }

    test('a redeem answer with a slug is delivered, with the option set', () async {
      final api_ = Api()..onRedeem = (_) => deferred('https://$host/promo42?id=7');
      final instance = sdk(api_, deferredLinks: true, installReferrerSources: [referrer()]);
      final received = <ResolvedDeepLink>[];
      instance.links.listen(received.add);
      await instance.initialize();
      await statusReached(instance, DeferredLinkStatus.delivered);
      await settle();
      expect(received.single.isDeferred, isTrue);
      expect(received.single.routePath, '/promo/42');
      expect(api_.resolves, isEmpty);
    });

    test('a path link that opened the app supersedes the deferred link', () async {
      final api_ = Api()..onRedeem = (_) => deferred('https://$host/promo42');
      final instance = sdk(
        api_,
        deferredLinks: true,
        installReferrerSources: [referrer()],
        source: FakeLinkSource(initialLinkString: 'https://$host/product/42?id=7'),
      );
      await instance.initialize();
      await statusReached(instance, DeferredLinkStatus.superseded);
      expect(api_.redeems, isEmpty);
      expect(api_.resolves, hasLength(1));
    });

    test('iOS: a pasted link with several segments is notOurs, without a request', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final api_ = Api()..onRedeem = (_) => deferred('https://$host/promo42');
      final instance = sdk(api_, deferredLinks: true);
      expect(
        await instance.redeemPastedLink('https://$host/product/42?strybok_click=$clickId'),
        PastedLinkResult.notOurs,
      );
      expect(api_.redeems, isEmpty);
      expect(
        await instance.redeemPastedLink('https://$host/promo42?strybok_click=$clickId'),
        PastedLinkResult.delivered,
      );
    });

    test('iOS: a pasted link whose answer has several segments fails', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final api_ = Api()..onRedeem = (_) => deferred('https://$host/product/42');
      final instance = sdk(api_, deferredLinks: true);
      final received = <ResolvedDeepLink>[];
      instance.links.listen(received.add);
      expect(
        await instance.redeemPastedLink('https://$host/promo42?strybok_click=$clickId'),
        PastedLinkResult.failed,
      );
      await settle();
      expect(received, isEmpty);
    });

    test('iOS: a match whose answer has several segments fails', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final api_ = Api()
        ..onMatch = (_) => deferred('https://$host/product/42', matched: 'probabilistic');
      final instance = sdk(api_, deferredLinks: true, allowProbabilisticMatching: true);
      final received = <ResolvedDeepLink>[];
      instance.links.listen(received.add);
      await instance.initialize();
      await statusReached(instance, DeferredLinkStatus.failed);
      await settle();
      expect(api_.matches, hasLength(1));
      expect(received, isEmpty);
    });
  });

  group('decoding and encoding', () {
    test('values are decoded strictly as UTF-8 and re-encoded byte by byte', () {
      expect(decodeQueryText('a+b%2Bc'), 'a b+c');
      expect(decodeQueryText('%D0%BA%D0%B8%D1%97%D0%B2'), 'київ');
      expect(decodeQueryText('кий'), 'кий');
      expect(decodeQueryText('%F0%9F%98%80'), '\u{1F600}');
      expect(decodeQueryText('\u{1F600}'), '\u{1F600}');
      // A byte-order mark is a character like any other, also at the start.
      expect(decodeQueryText('%EF%BB%BFx'), '﻿x');
      for (final raw in [
        '%',
        '%4',
        '%zz',
        '%E0%A4',
        '%C0%AE',
        '%ED%A0%80',
        '%F4%90%80%80',
        '%FF',
        'a\uD800b',
      ]) {
        expect(decodeQueryText(raw), isNull, reason: raw);
      }
      expect(encodeQueryValue('AZaz09-._~'), 'AZaz09-._~');
      expect(encodeQueryValue(" +&=/?#%'()!*"), '%20%2B%26%3D%2F%3F%23%25%27%28%29%21%2A');
      expect(encodeQueryValue('к\u{1F600}﻿'), '%D0%BA%F0%9F%98%80%EF%BB%BF');
    });

    test('raw characters, a byte-order mark and an apn without "=" in requests', () async {
      for (final MapEntry(key: tapped, value: lookup) in {
        'https://$host/city?id=київ': 'https://$host/city?id=%D0%BA%D0%B8%D1%97%D0%B2',
        'https://$host/p?id=%EF%BB%BF': 'https://$host/p?id=%EF%BB%BF',
        'https://go.example.com/?link=https%3A%2F%2Fexample.com%2Fp&apn':
            'https://go.example.com/?link=https%3A%2F%2Fexample.com%2Fp&apn=',
      }.entries) {
        final api_ = Api();
        await sdk(api_).resolveUrl(tapped);
        expect(api_.resolves.single.url.queryParameters, {'url': lookup}, reason: tapped);
      }
    });
  });

  group('link sources', () {
    test('the app_links source hands over links exactly as received', () {
      expect(AppLinksSource(), isA<RawLinkSource>());
    });

    test('FakeLinkSource keeps strings as written and parses them for uriStream', () async {
      const raw = 'https://$host/a/../b';
      final source = FakeLinkSource(initialLink: Uri.parse('https://$host/x'));
      expect(await source.getInitialLinkString(), 'https://$host/x');
      source.initialLinkString = raw;
      expect(await source.getInitialLinkString(), raw);
      expect(await source.getInitialLink(), Uri.parse(raw));

      final strings = <String>[];
      final uris = <Uri>[];
      final a = source.stringLinkStream.listen(strings.add);
      final b = source.uriStream.listen(uris.add);
      source.emitString(raw);
      source.emit(Uri.parse('https://$host/c'));
      await settle();
      expect(strings, [raw, 'https://$host/c']);
      expect(uris, [Uri.parse('https://$host/b'), Uri.parse('https://$host/c')]);
      await a.cancel();
      await b.cancel();
    });
  });
}
