import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strybok/strybok.dart';
import 'package:strybok/testing.dart';

const host = 'my-app-123.links.example.com';
const key = 'pk_test_4f9a1c7e2b';
const secretPayload = {'productId': 42, 'note': 'payload-marker-7731'};
final api = Uri.parse('https://api.example.com');

http.Response created({int status = 201, String route = '/product/42'}) => http.Response(
  jsonEncode({
    'linkId': 'link_9',
    'slug': 'aB3dE5fG',
    'routePath': route,
    'url': 'https://$host/aB3dE5fG',
  }),
  status,
);

/// Records every request and answers with [handler].
class Api {
  Api([this.handler]);

  FutureOr<http.Response> Function(http.Request request)? handler;
  final requests = <http.Request>[];

  late final client = MockClient((request) async {
    requests.add(request);
    return await (handler?.call(request) ?? created());
  });
}

Strybok sdk(
  Api api_, {
  String? clientKey = key,
  int maxRetries = 2,
  Duration timeout = const Duration(milliseconds: 60),
  List<StrybokException>? errors,
  FakeLinkSource? source,
  Uri? apiBaseUrl,
  Set<String> allowedHosts = const {host},
}) {
  final instance = Strybok(
    apiBaseUrl: apiBaseUrl ?? api,
    allowedHosts: allowedHosts,
    linkSource: source ?? FakeLinkSource(),
    httpClient: api_.client,
    timeout: timeout,
    maxRetries: maxRetries,
    retryDelay: const Duration(milliseconds: 1),
    onError: errors?.add,
    clientKey: clientKey,
  );
  addTearDown(instance.dispose);
  return instance;
}

/// Runs [call], which must fail, and returns what it threw.
Future<StrybokException> failure(Future<Object?> Function() call) async {
  try {
    await call();
  } on StrybokException catch (error) {
    return error;
  }
  fail('Expected a StrybokException');
}

/// Everything an app could log or show from [error].
String visibleText(StrybokException error) => [
  '$error',
  error.message,
  '${error.uri}',
  if (error is StrybokNetworkException) '${error.cause}',
  if (error is StrybokValidationException) error.issues.join(' '),
].join(' ');

void main() {
  group('request', () {
    test('posts all fields with the key header and returns the created link', () async {
      final api_ = Api();
      final link = await sdk(api_).createLink(
        '/product/42',
        payload: {'productId': 42},
        title: 'Red shoes',
        description: 'Look at these',
        imageUrl: Uri.parse('https://cdn.example.com/shoes.png'),
      );

      expect(link.url, Uri.parse('https://$host/aB3dE5fG'));
      expect(link.slug, 'aB3dE5fG');
      expect(link.routePath, '/product/42');
      expect(link.linkId, 'link_9');

      final request = api_.requests.single;
      expect(request.method, 'POST');
      expect('${request.url}', 'https://api.example.com/v1/public/links');
      expect(request.headers['content-type'], 'application/json');
      expect(request.headers['accept'], 'application/json');
      expect(request.headers['x-strybok-key'], key);
      expect(
        request.headers.keys.map((name) => name.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(jsonDecode(request.body), {
        'routePath': '/product/42',
        'payload': {'productId': 42},
        'title': 'Red shoes',
        'description': 'Look at these',
        'imageUrl': 'https://cdn.example.com/shoes.png',
      });
    });

    test('arguments that were not given are omitted, not sent as null', () async {
      final api_ = Api();
      await sdk(api_).createLink('/product/42');
      expect(api_.requests.single.body, '{"routePath":"/product/42"}');

      await sdk(api_).createLink('/product/42', title: 'Red shoes');
      expect(jsonDecode(api_.requests.last.body), {
        'routePath': '/product/42',
        'title': 'Red shoes',
      });
    });

    test('an empty payload object is still sent', () async {
      final api_ = Api();
      await sdk(api_).createLink('/product/42', payload: {});
      expect(jsonDecode(api_.requests.single.body), {'routePath': '/product/42', 'payload': {}});
    });

    test('non-ASCII text is sent as UTF-8', () async {
      final api_ = Api();
      await sdk(api_).createLink('/product/42', title: 'Червоні черевики 👟');
      expect(jsonDecode(utf8.decode(api_.requests.single.bodyBytes)), {
        'routePath': '/product/42',
        'title': 'Червоні черевики 👟',
      });
    });

    test('keeps a path prefix of the API base URL', () async {
      final api_ = Api();
      await sdk(
        api_,
        apiBaseUrl: Uri.parse('https://example.com/strybok/'),
      ).createLink('/product/42');
      expect(api_.requests.single.url.path, '/strybok/v1/public/links');
    });
  });

  group('success', () {
    test('200 (an identical link already existed) is success like 201', () async {
      for (final status in [200, 201]) {
        final api_ = Api((_) => created(status: status));
        final link = await sdk(api_).createLink('/product/42');
        expect(link.url, Uri.parse('https://$host/aB3dE5fG'), reason: '$status');
        expect(api_.requests, hasLength(1));
      }
    });

    test('the returned URL is not checked against allowedHosts', () async {
      final api_ = Api(
        (_) => http.Response(
          '{"linkId":"l","slug":"s","routePath":"/x","url":"https://other.example.net/s"}',
          201,
        ),
      );
      final link = await sdk(api_, allowedHosts: const {}).createLink('/x');
      expect(link.url.host, 'other.example.net');
    });

    test('a success answer that cannot be read is a server error and is not retried', () async {
      for (final status in [200, 201]) {
        for (final body in [
          'not json',
          '',
          '[]',
          'null',
          '{"slug":"s","routePath":"/x","url":"https://$host/s"}',
          '{"linkId":"l","routePath":"/x","url":"https://$host/s"}',
          '{"linkId":"l","slug":"s","url":"https://$host/s"}',
          '{"linkId":"l","slug":"s","routePath":"/x"}',
          '{"linkId":1,"slug":"s","routePath":"/x","url":"https://$host/s"}',
          '{"linkId":"l","slug":null,"routePath":"/x","url":"https://$host/s"}',
          '{"linkId":"l","slug":"s","routePath":"/x","url":"http://$host/s"}',
          '{"linkId":"l","slug":"s","routePath":"/x","url":"myapp://open/s"}',
          '{"linkId":"l","slug":"s","routePath":"/x","url":"https://"}',
          '{"linkId":"l","slug":"s","routePath":"/x","url":42}',
        ]) {
          final api_ = Api((_) => http.Response(body, status));
          final error = await failure(() => sdk(api_).createLink('/x'));
          expect(
            error,
            isA<StrybokServerException>().having((e) => e.statusCode, 'statusCode', status),
            reason: body,
          );
          expect(api_.requests, hasLength(1), reason: 'not retried: $body');
        }
      }
    });
  });

  group('rejections are not retried', () {
    test('401 is StrybokUnauthorizedException', () async {
      final api_ = Api((_) => http.Response('{"error":{"code":"UNAUTHENTICATED"}}', 401));
      final error = await failure(() => sdk(api_).createLink('/product/42'));
      expect(error, isA<StrybokUnauthorizedException>());
      expect(api_.requests, hasLength(1));
    });

    test('403 is RouteNotAllowedException with the route', () async {
      final api_ = Api((_) => http.Response('{"error":{"code":"FORBIDDEN"}}', 403));
      final error = await failure(() => sdk(api_).createLink('/admin/1'));
      expect(
        error,
        isA<RouteNotAllowedException>().having((e) => e.routePath, 'routePath', '/admin/1'),
      );
      expect(api_.requests, hasLength(1));
    });

    test('429 is StrybokRateLimitedException with Retry-After seconds', () async {
      final api_ = Api((_) => http.Response('{}', 429, headers: {'retry-after': '37'}));
      final error = await failure(() => sdk(api_).createLink('/product/42'));
      expect(
        error,
        isA<StrybokRateLimitedException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 37),
        ),
      );
      expect(api_.requests, hasLength(1), reason: '429 is never retried automatically');
    });

    test('429 without a usable Retry-After has no retryAfter', () async {
      for (final headers in [
        <String, String>{},
        {'retry-after': 'Wed, 21 Oct 2026 07:28:00 GMT'},
        {'retry-after': '-5'},
        {'retry-after': ''},
      ]) {
        final api_ = Api((_) => http.Response('{}', 429, headers: headers));
        final error = await failure(() => sdk(api_).createLink('/product/42'));
        expect(
          error,
          isA<StrybokRateLimitedException>().having((e) => e.retryAfter, 'retryAfter', isNull),
          reason: '$headers',
        );
        expect(api_.requests, hasLength(1));
      }
    });

    test('400, 413 and 422 are StrybokValidationException with the server details', () async {
      for (final status in [400, 413, 422]) {
        final api_ = Api(
          (_) => http.Response(
            jsonEncode({
              'error': {
                'code': 'VALIDATION_ERROR',
                'message': 'The request is invalid',
                'details': {
                  'issues': [
                    {'path': 'title', 'message': 'Too long'},
                    {'path': '', 'message': 'Unrecognized key'},
                  ],
                },
              },
            }),
            status,
          ),
        );
        final error = await failure(() => sdk(api_).createLink('/product/42'));
        expect(error, isA<StrybokValidationException>(), reason: '$status');
        error as StrybokValidationException;
        expect(error.message, 'The request is invalid');
        expect(error.issues.map((issue) => (issue.path, issue.message)), [
          ('title', 'Too long'),
          ('', 'Unrecognized key'),
        ]);
        expect(api_.requests, hasLength(1), reason: '$status is not retried');
      }
    });

    test('a validation answer without readable details still has a message', () async {
      for (final body in [
        '',
        'not json',
        '[]',
        '{"error":"nope"}',
        '{"error":{"message":7,"details":{"issues":"x"}}}',
        '{"error":{"details":{"issues":[1,{"path":"a"},null]}}}',
      ]) {
        final api_ = Api((_) => http.Response(body, 422));
        final error = await failure(() => sdk(api_).createLink('/product/42'));
        expect(error, isA<StrybokValidationException>(), reason: body);
        error as StrybokValidationException;
        expect(error.message, isNotEmpty);
        expect(error.issues, isEmpty, reason: body);
      }
    });

    test('other 4xx and unexpected statuses are server errors with the status', () async {
      for (final status in [402, 404, 405, 409, 418, 204, 302]) {
        final api_ = Api((_) => http.Response('{}', status));
        final error = await failure(() => sdk(api_).createLink('/product/42'));
        expect(
          error,
          isA<StrybokServerException>().having((e) => e.statusCode, 'statusCode', status),
        );
        expect(api_.requests, hasLength(1), reason: '$status is not retried');
      }
    });
  });

  group('retries', () {
    test('5xx is retried and then succeeds', () async {
      var calls = 0;
      final api_ = Api((_) => ++calls < 3 ? http.Response('', 503) : created());
      final link = await sdk(api_).createLink('/product/42');
      expect(link.slug, 'aB3dE5fG');
      expect(calls, 3);
    });

    test('5xx after all retries reports the last status', () async {
      var calls = 0;
      final api_ = Api((_) => http.Response('', ++calls == 3 ? 502 : 500));
      final error = await failure(() => sdk(api_).createLink('/product/42'));
      expect(error, isA<StrybokServerException>().having((e) => e.statusCode, 'statusCode', 502));
      expect(api_.requests, hasLength(3), reason: 'one attempt plus maxRetries');
    });

    test('a network failure is retried and then succeeds', () async {
      var calls = 0;
      final api_ = Api((_) {
        if (++calls < 3) throw http.ClientException('connection reset');
        return created();
      });
      await sdk(api_).createLink('/product/42');
      expect(calls, 3);
    });

    test('gives up with StrybokNetworkException after maxRetries', () async {
      final api_ = Api((_) => throw http.ClientException('offline'));
      final error = await failure(() => sdk(api_, maxRetries: 1).createLink('/product/42'));
      expect(error, isA<StrybokNetworkException>());
      expect(api_.requests, hasLength(2));
    });

    test('a timeout is retried and then reported as StrybokTimeoutException', () async {
      final api_ = Api((_) => Completer<http.Response>().future);
      final error = await failure(() => sdk(api_, maxRetries: 1).createLink('/product/42'));
      expect(error, isA<StrybokTimeoutException>());
      expect(error.message, isNot(contains('resolve')));
      expect(api_.requests, hasLength(2));
    });

    test('a timeout is retried and then succeeds', () async {
      var calls = 0;
      final api_ = Api((_) => ++calls == 1 ? Completer<http.Response>().future : created());
      await sdk(api_).createLink('/product/42');
      expect(calls, 2);
    });

    test('maxRetries 0 means a single attempt', () async {
      final api_ = Api((_) => http.Response('', 500));
      await failure(() => sdk(api_, maxRetries: 0).createLink('/product/42'));
      expect(api_.requests, hasLength(1));
    });

    test('every retry sends exactly the same request', () async {
      final api_ = Api((_) => http.Response('', 503));
      await failure(
        () => sdk(api_).createLink(
          '/product/42',
          payload: {
            'b': 1,
            'a': [true, null, 1.5],
            'nested': {'z': 'я', 'y': 2},
          },
          title: 'Red shoes',
          description: 'Look at these',
          imageUrl: Uri.parse('https://cdn.example.com/shoes.png'),
        ),
      );
      expect(api_.requests, hasLength(3));
      final first = api_.requests.first;
      for (final request in api_.requests.skip(1)) {
        expect(request.bodyBytes, first.bodyBytes);
        expect(request.headers, first.headers);
        expect(request.url, first.url);
        expect(request.method, first.method);
      }
    });

    test('waits retryDelay before the first retry and doubles it each time', () async {
      final times = <DateTime>[];
      final client = MockClient((_) async {
        times.add(DateTime.now());
        return http.Response('', 503);
      });
      final instance = Strybok(
        apiBaseUrl: api,
        allowedHosts: {host},
        linkSource: FakeLinkSource(),
        httpClient: client,
        retryDelay: const Duration(milliseconds: 40),
        clientKey: key,
      );
      addTearDown(instance.dispose);
      await failure(() => instance.createLink('/product/42'));
      expect(times, hasLength(3));
      expect(times[1].difference(times[0]), greaterThanOrEqualTo(const Duration(milliseconds: 35)));
      expect(times[2].difference(times[1]), greaterThanOrEqualTo(const Duration(milliseconds: 75)));
    });
  });

  group('checks before any network call', () {
    test('a missing or empty client key is StrybokUnauthorizedException', () async {
      for (final clientKey in [null, '']) {
        final api_ = Api();
        final error = await failure(
          () => sdk(api_, clientKey: clientKey).createLink('/product/42'),
        );
        expect(error, isA<StrybokUnauthorizedException>());
        expect(api_.requests, isEmpty);
      }
    });

    test('a key that cannot be an HTTP header value is refused without leaking it', () async {
      for (final clientKey in ['pk_bad\r\nX-Injected: 1', 'pk bad', '\t\t', 'pk_ключ']) {
        final api_ = Api();
        final error = await failure(
          () => sdk(api_, clientKey: clientKey).createLink('/product/42'),
        );
        expect(error, isA<StrybokUnauthorizedException>());
        expect(visibleText(error), isNot(contains(clientKey)));
        expect(api_.requests, isEmpty);
      }
    });

    test('a route that is not a single-slash path is StrybokValidationException', () async {
      for (final route in [
        '',
        'product/42',
        '//evil.example.com',
        'https://evil.example.com/x',
        ' /product',
        '/${'a' * 512}',
      ]) {
        final api_ = Api();
        final error = await failure(() => sdk(api_).createLink(route));
        expect(error, isA<StrybokValidationException>(), reason: route);
        expect(api_.requests, isEmpty, reason: route);
      }
    });

    test('a route of exactly 512 characters is sent', () async {
      final api_ = Api();
      final route = '/${'a' * 511}';
      await sdk(api_).createLink(route);
      expect(jsonDecode(api_.requests.single.body), {'routePath': route});
    });

    test('a payload that is not JSON is StrybokValidationException', () async {
      for (final payload in <Map<String, Object?>>[
        {'when': DateTime(2026)},
        {'n': double.nan},
        {
          'nested': {1: 'not a string key'},
        },
      ]) {
        final api_ = Api();
        final error = await failure(() => sdk(api_).createLink('/product/42', payload: payload));
        expect(error, isA<StrybokValidationException>());
        expect(api_.requests, isEmpty);
      }
    });

    test('the key is checked before the route', () async {
      final api_ = Api();
      final error = await failure(() => sdk(api_, clientKey: null).createLink('nope'));
      expect(error, isA<StrybokUnauthorizedException>());
    });

    test('other limits are left to the server', () async {
      final api_ = Api();
      await sdk(api_).createLink(
        '/product/42',
        title: 'x' * 500,
        description: 'y' * 1000,
        imageUrl: Uri.parse('http://insecure.example.com/a.png'),
        payload: {'big': 'z' * 8000},
      );
      expect(api_.requests, hasLength(1));
    });
  });

  group('errors never contain the key or the payload', () {
    final answers = <String, FutureOr<http.Response> Function(http.Request)>{
      '401': (_) => http.Response('{"error":{"message":"Authentication is required"}}', 401),
      '403': (_) => http.Response('{"error":{"message":"Route not allowed"}}', 403),
      '429': (_) => http.Response('{}', 429, headers: {'retry-after': '60'}),
      '422': (_) => http.Response(
        '{"error":{"message":"The request is invalid",'
        '"details":{"issues":[{"path":"payload","message":"Too large"}]}}}',
        422,
      ),
      '404': (_) => http.Response('{}', 404),
      '500': (_) => http.Response('{}', 500),
      'malformed': (_) => http.Response('{"nope":true}', 201),
      'network': (_) => throw http.ClientException('connection reset'),
      'timeout': (_) => Completer<http.Response>().future,
    };

    for (final MapEntry(key: name, value: answer) in answers.entries) {
      test(name, () async {
        final api_ = Api(answer);
        final error = await failure(
          () => sdk(api_, maxRetries: 0).createLink('/product/42', payload: secretPayload),
        );
        final text = visibleText(error);
        expect(text, isNot(contains(key)));
        expect(text, isNot(contains('payload-marker-7731')));
        expect(text, isNot(contains('productId')));
        expect(error.uri, isNull);
      });
    }

    test('pre-flight failures', () async {
      final noKey = await failure(
        () => sdk(Api(), clientKey: '').createLink('/product/42', payload: secretPayload),
      );
      final badRoute = await failure(
        () => sdk(Api()).createLink('product', payload: secretPayload),
      );
      final badPayload = await failure(
        () => sdk(Api()).createLink('/p', payload: {'note': 'payload-marker-7731', 'x': Object()}),
      );
      for (final error in [noKey, badRoute, badPayload]) {
        expect(visibleText(error), isNot(contains(key)));
        expect(visibleText(error), isNot(contains('payload-marker-7731')));
      }
    });
  });

  group('independent of the start path', () {
    test('works without initialize and does not touch the link source', () async {
      final api_ = Api();
      final source = FakeLinkSource(initialLink: Uri.parse('https://$host/invite777'));
      final instance = sdk(api_, source: source);

      final link = await instance.createLink('/product/42');

      expect(link.linkId, 'link_9');
      expect(source.hasListener, isFalse, reason: 'createLink must not start link handling');
      expect(api_.requests.single.url.path, '/v1/public/links', reason: 'nothing was resolved');
    });

    test('works with no allowedHosts at all', () async {
      final api_ = Api();
      final link = await sdk(api_, allowedHosts: const {}).createLink('/product/42');
      expect(link.slug, 'aB3dE5fG');
    });

    test('initialize never calls it, with or without a client key', () async {
      final api_ = Api((request) {
        if (request.url.path.endsWith('/v1/public/links')) return created();
        if (request.url.path.endsWith('/v1/public/events')) return http.Response('', 202);
        return http.Response('{"linkId":"l","appId":"a","routePath":"/invite/abc"}', 200);
      });
      final source = FakeLinkSource(initialLink: Uri.parse('https://$host/invite777'));
      final instance = sdk(api_, source: source);

      await instance.initialize();
      expect(await instance.getInitialLink(), isNotNull);
      source.emit(Uri.parse('https://$host/other'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(api_.requests.where((r) => r.url.path.endsWith('/v1/public/links')), isEmpty);
      expect(
        api_.requests.where((r) => r.headers.keys.any((h) => h.toLowerCase() == 'x-strybok-key')),
        isEmpty,
        reason: 'the key is sent with createLink only',
      );
    });

    test('initialize does not wait for a createLink that is still running', () async {
      final pending = Completer<http.Response>();
      final api_ = Api((request) {
        if (request.url.path.endsWith('/v1/public/links')) return pending.future;
        if (request.url.path.endsWith('/v1/public/events')) return http.Response('', 202);
        return http.Response('{"linkId":"l","appId":"a","routePath":"/invite/abc"}', 200);
      });
      final source = FakeLinkSource(initialLink: Uri.parse('https://$host/invite777'));
      final instance = sdk(api_, source: source, timeout: const Duration(seconds: 5));

      final creating = instance.createLink('/product/42');
      await instance.initialize();
      expect((await instance.getInitialLink())?.routePath, '/invite/abc');

      pending.complete(created());
      expect((await creating).linkId, 'link_9');
    });

    test('errors are thrown to the caller, never passed to onError', () async {
      final errors = <StrybokException>[];
      final api_ = Api((_) => http.Response('{}', 403));
      final instance = sdk(api_, errors: errors);
      await instance.initialize();

      await failure(() => instance.createLink('/admin'));
      await failure(() => instance.createLink('not-a-route'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(errors, isEmpty);
    });

    test('after dispose it fails like the rest of the API', () async {
      final api_ = Api();
      final instance = sdk(api_);
      await instance.dispose();
      await expectLater(instance.createLink('/product/42'), throwsStateError);
      expect(api_.requests, isEmpty);
    });
  });
}
