import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strybok/strybok.dart';
import 'package:strybok/testing.dart';

const host = 'my-app-123.links.example.com';
final api = Uri.parse('https://api.example.com');
final invite = Uri.parse('https://$host/invite777');

http.Response ok({String route = '/invite/abc123', String linkId = 'link_1'}) => http.Response(
  jsonEncode({
    'linkId': linkId,
    'appId': 'app_1',
    'routePath': route,
    'payload': {'invitationId': 'abc123'},
  }),
  200,
);

/// Records requests and answers resolve calls with [onResolve].
class Api {
  Api([this.onResolve]);

  FutureOr<http.Response> Function(http.Request request)? onResolve;
  final resolves = <http.Request>[];
  final events = <Map<String, Object?>>[];
  FutureOr<http.Response> Function()? onEvent;

  late final client = MockClient((request) async {
    if (request.url.path.endsWith('/v1/public/events')) {
      events.add(jsonDecode(request.body) as Map<String, Object?>);
      return await (onEvent?.call() ?? http.Response('', 202));
    }
    resolves.add(request);
    return await (onResolve?.call(request) ?? ok());
  });
}

Strybok bridge(
  Api api_, {
  FakeLinkSource? source,
  List<StrybokException>? errors,
  DateTime Function()? clock,
  int maxRetries = 2,
  Duration timeout = const Duration(milliseconds: 60),
  bool reportAppOpens = true,
}) {
  final instance = Strybok(
    apiBaseUrl: api,
    allowedHosts: {host},
    linkSource: source ?? FakeLinkSource(),
    httpClient: api_.client,
    timeout: timeout,
    maxRetries: maxRetries,
    retryDelay: const Duration(milliseconds: 1),
    reportAppOpens: reportAppOpens,
    onError: errors?.add,
    clock: clock,
  );
  addTearDown(instance.dispose);
  return instance;
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('host allowlist and parsing', () {
    final sdk = Strybok(apiBaseUrl: api, allowedHosts: {'My-App-123.Links.Example.com'});

    test('accepts https links on an allowed host with a single slug', () {
      expect(sdk.isStrybokUri(invite), isTrue);
      expect(
        sdk.isStrybokUri(Uri.parse('https://MY-APP-123.links.example.com/AbC_7-x')),
        isTrue,
      );
      expect(sdk.isStrybokUri(Uri.parse('https://$host/abc?utm=1#frag')), isTrue);
    });

    test('rejects everything else', () {
      for (final uri in [
        'http://$host/invite777',
        'myapp://$host/invite777',
        'https://evil.example.com/invite777',
        'https://$host.evil.example.com/invite777',
        'https://evil-$host/invite777',
        'https://user:pw@$host/invite777',
        'https://$host:8443/invite777',
        'https://$host/',
        'https://$host/a/b',
        'https://$host/.well-known/assetlinks.json',
        'https://$host/a%2Fb',
      ]) {
        expect(sdk.isStrybokUri(Uri.parse(uri)), isFalse, reason: uri);
      }
    });

    test('resolveUri refuses foreign links without any network call', () async {
      final api_ = Api();
      final sdk = bridge(api_);
      await expectLater(
        sdk.resolveUri(Uri.parse('https://evil.example.com/invite777')),
        throwsA(isA<UnsupportedLinkException>()),
      );
      expect(api_.resolves, isEmpty);
    });
  });

  group('resolveUri', () {
    test('returns route and payload and sends only host and slug to the API', () async {
      final api_ = Api();
      final link = await bridge(
        api_,
      ).resolveUri(Uri.parse('https://$host/invite777?token=secret#f'));

      expect(link.routePath, '/invite/abc123');
      expect(link.payload, {'invitationId': 'abc123'});
      expect(link.linkId, 'link_1');
      expect(link.uri.queryParameters['token'], 'secret');

      final request = api_.resolves.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/public/resolve');
      expect(request.url.queryParameters, {'url': 'https://$host/invite777'});
      expect(api_.events, isEmpty, reason: 'explicit resolution is not an app open');
    });

    test('keeps a path prefix of the API base URL', () async {
      final api_ = Api();
      final sdk = Strybok(
        apiBaseUrl: Uri.parse('https://example.com/strybok/'),
        allowedHosts: {host},
        linkSource: FakeLinkSource(),
        httpClient: api_.client,
      );
      await sdk.resolveUri(invite);
      expect(api_.resolves.single.url.path, '/strybok/v1/public/resolve');
    });

    test('404 becomes LinkNotFoundException and is not retried', () async {
      final api_ = Api((_) => http.Response('{"error":{"code":"LINK_NOT_FOUND"}}', 404));
      await expectLater(bridge(api_).resolveUri(invite), throwsA(isA<LinkNotFoundException>()));
      expect(api_.resolves, hasLength(1));
    });

    test('other client errors are not retried', () async {
      final api_ = Api((_) => http.Response('{}', 422));
      await expectLater(
        bridge(api_).resolveUri(invite),
        throwsA(isA<StrybokServerException>().having((e) => e.statusCode, 'statusCode', 422)),
      );
      expect(api_.resolves, hasLength(1));
    });

    test('retries network errors and then succeeds', () async {
      var calls = 0;
      final api_ = Api((_) {
        calls++;
        if (calls < 3) throw http.ClientException('connection reset');
        return ok();
      });
      final link = await bridge(api_).resolveUri(invite);
      expect(link.routePath, '/invite/abc123');
      expect(calls, 3);
    });

    test('gives up with a network exception after maxRetries', () async {
      final api_ = Api((_) => throw http.ClientException('offline'));
      await expectLater(
        bridge(api_, maxRetries: 1).resolveUri(invite),
        throwsA(isA<StrybokNetworkException>()),
      );
      expect(api_.resolves, hasLength(2));
    });

    test('retries 5xx responses', () async {
      var calls = 0;
      final api_ = Api((_) => ++calls == 1 ? http.Response('', 503) : ok());
      await bridge(api_).resolveUri(invite);
      expect(calls, 2);
    });

    test('times out with a typed exception', () async {
      final api_ = Api((_) => Completer<http.Response>().future);
      await expectLater(
        bridge(api_, maxRetries: 1).resolveUri(invite),
        throwsA(isA<StrybokTimeoutException>()),
      );
      expect(api_.resolves, hasLength(2));
    });

    test('rejects malformed or unsafe responses', () async {
      for (final body in [
        'not json',
        '[]',
        '{"linkId":"l","appId":"a"}',
        '{"linkId":"l","appId":"a","routePath":"https://evil.example.com"}',
        '{"linkId":"l","appId":"a","routePath":"//evil.example.com"}',
        '{"linkId":1,"appId":"a","routePath":"/x"}',
      ]) {
        final api_ = Api((_) => http.Response(body, 200));
        await expectLater(
          bridge(api_).resolveUri(invite),
          throwsA(isA<StrybokServerException>()),
          reason: body,
        );
      }
    });
  });

  group('cold start', () {
    test('delivers the launch link once, even if the listener attaches late', () async {
      final api_ = Api();
      final sdk = bridge(api_, source: FakeLinkSource(initialLink: invite));
      await sdk.initialize();

      final received = <ResolvedDeepLink>[];
      sdk.links.listen(received.add);
      await settle();

      expect(received.map((l) => l.routePath), ['/invite/abc123']);
      expect(api_.resolves, hasLength(1));
    });

    test('de-duplicates a launch link that is replayed on the stream', () async {
      final api_ = Api();
      final sdk = bridge(
        api_,
        source: FakeLinkSource(initialLink: invite, replayInitialLinkOnStream: true),
      );
      final received = <ResolvedDeepLink>[];
      sdk.links.listen(received.add);
      await sdk.initialize();
      await settle();

      expect(received, hasLength(1));
      expect(api_.resolves, hasLength(1));
      expect(api_.events, hasLength(1));
    });

    test('getInitialLink consumes the launch link so the stream does not repeat it', () async {
      final sdk = bridge(Api(), source: FakeLinkSource(initialLink: invite));
      final initial = await sdk.getInitialLink();
      expect(initial?.routePath, '/invite/abc123');
      expect(await sdk.getInitialLink(), isNull);

      final received = <ResolvedDeepLink>[];
      sdk.links.listen(received.add);
      await settle();
      expect(received, isEmpty);
    });

    test('getInitialLink returns null once the stream already delivered it', () async {
      final sdk = bridge(Api(), source: FakeLinkSource(initialLink: invite));
      final received = <ResolvedDeepLink>[];
      sdk.links.listen(received.add);
      await sdk.initialize();
      await settle();
      expect(received, hasLength(1));
      expect(await sdk.getInitialLink(), isNull);
    });

    test('no launch link, foreign launch link and repeated initialize are harmless', () async {
      final api_ = Api();
      final source = FakeLinkSource(initialLink: Uri.parse('https://other.example.com/x'));
      final errors = <StrybokException>[];
      final sdk = bridge(api_, source: source, errors: errors);
      await Future.wait([sdk.initialize(), sdk.initialize()]);
      expect(await sdk.getInitialLink(), isNull);
      expect(api_.resolves, isEmpty);
      expect(errors, isEmpty);
    });

    test('a failing launch link is reported through onError and initialize completes', () async {
      final errors = <StrybokException>[];
      final sdk = bridge(
        Api((_) => http.Response('', 404)),
        source: FakeLinkSource(initialLink: invite),
        errors: errors,
      );
      await sdk.initialize();
      expect(errors.single, isA<LinkNotFoundException>());
      expect(errors.single.uri, invite);
      expect(await sdk.getInitialLink(), isNull);
    });
  });

  group('running app', () {
    test('delivers each foreground link exactly once', () async {
      final api_ = Api((request) {
        final slug = Uri.parse(request.url.queryParameters['url']!).path.substring(1);
        return ok(route: '/p/$slug', linkId: 'link_$slug');
      });
      final source = FakeLinkSource();
      final sdk = bridge(api_, source: source);
      final received = <String>[];
      sdk.links.listen((link) => received.add(link.routePath));
      await sdk.initialize();

      source.emit(Uri.parse('https://$host/first'));
      source.emit(Uri.parse('https://$host/second'));
      source.emit(Uri.parse('https://evil.example.com/third'));
      await settle();

      expect(received, unorderedEquals(['/p/first', '/p/second']));
      expect(api_.resolves, hasLength(2));
    });

    test('drops an immediate duplicate but honours the same link tapped again later', () async {
      var now = DateTime(2026);
      final source = FakeLinkSource();
      final api_ = Api();
      final sdk = bridge(api_, source: source, clock: () => now);
      final received = <ResolvedDeepLink>[];
      sdk.links.listen(received.add);
      await sdk.initialize();

      source.emit(invite);
      source.emit(invite);
      await settle();
      expect(received, hasLength(1));

      // App paused, user taps the same link again a minute later (resume).
      now = now.add(const Duration(minutes: 1));
      source.emit(invite);
      await settle();
      expect(received, hasLength(2));
      expect(api_.resolves, hasLength(2));
    });

    test('multiple listeners each see a link once', () async {
      final source = FakeLinkSource();
      final sdk = bridge(Api(), source: source);
      final a = <ResolvedDeepLink>[];
      final b = <ResolvedDeepLink>[];
      sdk.links.listen(a.add);
      sdk.links.listen(b.add);
      await sdk.initialize();
      source.emit(invite);
      await settle();
      expect(a, hasLength(1));
      expect(b, hasLength(1));
    });

    test('errors go to onError and the stream keeps working', () async {
      var fail = true;
      final errors = <StrybokException>[];
      final source = FakeLinkSource();
      final sdk = bridge(
        Api((_) => fail ? throw http.ClientException('offline') : ok()),
        source: source,
        errors: errors,
        maxRetries: 0,
      );
      final received = <ResolvedDeepLink>[];
      sdk.links.listen(received.add);
      await sdk.initialize();

      source.emit(Uri.parse('https://$host/offline1'));
      await settle();
      expect(errors.single, isA<StrybokNetworkException>());
      expect(received, isEmpty);

      fail = false;
      source.emit(Uri.parse('https://$host/online1'));
      await settle();
      expect(received, hasLength(1));
    });
  });

  group('app_open events', () {
    test('sends one minimal best-effort event per delivered link', () async {
      final api_ = Api();
      final source = FakeLinkSource();
      final sdk = bridge(api_, source: source);
      sdk.links.listen((_) {});
      await sdk.initialize();
      source.emit(invite);
      await settle();

      final event = api_.events.single;
      expect(event.keys, unorderedEquals(['eventId', 'linkId', 'type', 'platform', 'sdkVersion']));
      expect(event['type'], 'app_open');
      expect(event['linkId'], 'link_1');
      expect(
        event['eventId'],
        matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
    });

    test('a slow or failing events endpoint never delays or breaks delivery', () async {
      for (final onEvent in <FutureOr<http.Response> Function()>[
        () => Completer<http.Response>().future,
        () => throw http.ClientException('down'),
        () => http.Response('', 500),
      ]) {
        final api_ = Api()..onEvent = onEvent;
        final source = FakeLinkSource();
        final errors = <StrybokException>[];
        final sdk = bridge(api_, source: source, errors: errors);
        final received = <ResolvedDeepLink>[];
        sdk.links.listen(received.add);
        await sdk.initialize();
        source.emit(invite);
        await settle();
        expect(received, hasLength(1));
        expect(errors, isEmpty);
      }
    });

    test('can be turned off', () async {
      final api_ = Api();
      final source = FakeLinkSource(initialLink: invite);
      final sdk = bridge(api_, source: source, reportAppOpens: false);
      await sdk.initialize();
      await settle();
      expect(api_.events, isEmpty);
    });
  });

  group('dispose', () {
    test('stops delivery, closes the stream and rejects further use', () async {
      final api_ = Api();
      final source = FakeLinkSource();
      final sdk = bridge(api_, source: source);
      final received = <ResolvedDeepLink>[];
      var done = false;
      sdk.links.listen(received.add, onDone: () => done = true);
      await sdk.initialize();
      expect(source.hasListener, isTrue);

      await sdk.dispose();
      await sdk.dispose(); // idempotent
      expect(source.hasListener, isFalse);
      expect(done, isTrue);

      source.emit(invite);
      await settle();
      expect(received, isEmpty);
      expect(api_.resolves, isEmpty);
      expect(() => sdk.resolveUri(invite), throwsStateError);
      expect(sdk.initialize, throwsStateError);
    });

    test('a link still resolving when disposed is not delivered', () async {
      final pending = Completer<http.Response>();
      final source = FakeLinkSource();
      final errors = <StrybokException>[];
      final sdk = bridge(
        Api((_) => pending.future),
        source: source,
        errors: errors,
        timeout: const Duration(seconds: 5),
      );
      final received = <ResolvedDeepLink>[];
      sdk.links.listen(received.add);
      await sdk.initialize();
      source.emit(invite);
      await settle();

      await sdk.dispose();
      pending.complete(ok());
      await settle();
      expect(received, isEmpty);
      expect(errors, isEmpty);
    });
  });
}
