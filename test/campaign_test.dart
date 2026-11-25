// Campaign values (SDK contract, "Campaign query"): what of a tapped URL's
// query is sent to resolve, what the resolved link carries, and what
// `app_open` reports.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strybok/src/link_campaign.dart' show campaignQuery;
import 'package:strybok/strybok.dart';
import 'package:strybok/testing.dart';

const host = 'my-app-123.links.example.com';
final api = Uri.parse('https://api.example.com');
const invite = 'https://$host/invite777';

http.Response resolved([Map<String, Object?> extra = const {}]) => http.Response(
  jsonEncode({'linkId': 'link_1', 'appId': 'app_1', 'routePath': '/x', ...extra}),
  200,
);

/// The resolve request for [lookup], built the way the SDK always built it.
String resolveUrlFor(String lookup) =>
    '${api.replace(path: '/v1/public/resolve', queryParameters: {'url': lookup})}';

/// Records requests and answers resolve calls with [onResolve].
class Api {
  Api([this.onResolve]);

  FutureOr<http.Response> Function(http.Request request)? onResolve;
  final resolves = <http.Request>[];
  final eventRequests = <http.Request>[];

  List<Map<String, Object?>> get events => [
    for (final request in eventRequests) jsonDecode(request.body) as Map<String, Object?>,
  ];

  late final client = MockClient((request) async {
    if (request.url.path.endsWith('/v1/public/events')) {
      eventRequests.add(request);
      return http.Response('', 202);
    }
    resolves.add(request);
    return await (onResolve?.call(request) ?? resolved());
  });
}

Strybok bridge(
  Api api_, {
  FakeLinkSource? source,
  Set<String> allowedHosts = const {host},
  DateTime Function()? clock,
}) {
  final instance = Strybok(
    apiBaseUrl: api,
    allowedHosts: allowedHosts,
    linkSource: source ?? FakeLinkSource(),
    httpClient: api_.client,
    timeout: const Duration(milliseconds: 60),
    retryDelay: const Duration(milliseconds: 1),
    clock: clock,
  );
  addTearDown(instance.dispose);
  return instance;
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('campaignQuery', () {
    test('is empty when there is no query or nothing of ours in it', () {
      for (final query in [
        '',
        '&',
        '&&&',
        '=',
        'utm_source',
        'utm_source=',
        'token=secret',
        'utm=1',
        'utm_id=42&gclid=x&fbclid=y',
        'a=/b/c&d=%2F',
      ]) {
        expect(campaignQuery(query), '', reason: query);
      }
    });

    test('keeps the five keys and nothing else', () {
      const all =
          'utm_source=instagram&utm_medium=social&utm_campaign=spring&utm_term=shoes&utm_content=banner';
      expect(campaignQuery(all), all);
      expect(
        campaignQuery('token=secret&utm_source=a&utm_id=7&utm_sourcex=b&xutm_medium=c&gclid=d'),
        'utm_source=a',
      );
    });

    test('writes the kept pairs in the fixed order, whatever the order in the URL', () {
      expect(
        campaignQuery('utm_content=e&x=1&utm_term=d&utm_campaign=c&utm_medium=b&y=2&utm_source=a'),
        'utm_source=a&utm_medium=b&utm_campaign=c&utm_term=d&utm_content=e',
      );
      expect(campaignQuery('utm_content=e&utm_medium=b'), 'utm_medium=b&utm_content=e');
    });

    test('compares key names exactly, in lower case', () {
      expect(
        campaignQuery('UTM_SOURCE=a&Utm_Medium=b&utm_Campaign=c&utm-term=d&utm_content%20=e'),
        '',
      );
      expect(campaignQuery('UTM_SOURCE=a&utm_source=b'), 'utm_source=b');
    });

    test('takes the first occurrence of a key, even when its value is dropped', () {
      expect(campaignQuery('utm_source=first&utm_source=second'), 'utm_source=first');
      expect(campaignQuery('utm_source=two%20words&utm_source=second'), '');
      expect(campaignQuery('utm_source=&utm_source=second'), '');
      expect(campaignQuery('utm_source&utm_source=second'), '');
      expect(campaignQuery('utm_source=%zz&utm_source=second'), '');
      expect(
        campaignQuery('utm_medium=a&utm_source=b&utm_medium=c&utm_source=d'),
        'utm_source=b&utm_medium=a',
      );
    });

    test('drops values that are empty, too long or outside the allowed characters', () {
      const allowed = 'AZaz09._~-';
      expect(campaignQuery('utm_source=$allowed'), 'utm_source=$allowed');
      expect(campaignQuery('utm_source=${'a' * 64}'), 'utm_source=${'a' * 64}');
      expect(campaignQuery('utm_source=${'a' * 65}'), '');
      for (final value in [
        '',
        'two%20words',
        'two+words',
        'a%2Bb',
        'a@b.c',
        'a%40b.c',
        'a/b',
        'a%2Fb',
        'a%25b',
        'a%26b',
        'a%3Db',
        'a=b',
        'a,b',
        'a:b',
        'a!b',
        '(other)',
        '%22quoted%22',
        "it's",
        '<b>',
        'caf%C3%A9',
        'café',
        '%D0%B2%D0%B5%D1%81%D0%BD%D0%B0',
        'a%00b',
        'a%0Ab',
        '%',
        '%4',
        '%zz',
        '%FF',
        '%C3',
        '\u{1F600}',
      ]) {
        expect(campaignQuery('utm_source=$value&utm_medium=ok'), 'utm_medium=ok', reason: value);
      }
    });

    test('percent-decodes keys and values before checking them', () {
      expect(campaignQuery('utm_source=%69nstagram'), 'utm_source=instagram');
      expect(campaignQuery('utm%5Fsource=a'), 'utm_source=a');
      expect(campaignQuery('utm%5fsource=a'), 'utm_source=a');
      expect(campaignQuery('%75tm_medium=spring%5Fsale%2D1%2E0%7E'), 'utm_medium=spring_sale-1.0~');
      // A `+` is a space, in keys too, so neither side can match.
      expect(campaignQuery('utm_source=a+b&utm+medium=c'), '');
      // An encoded separator is part of the value, not a separator.
      expect(campaignQuery('x=1%26utm_source=a'), '');
      expect(campaignQuery('utm_source=a%26utm_medium=b'), '');
      // A key whose own escape is malformed is not one of ours and does not count as a first one.
      expect(campaignQuery('utm_source%zz=a&utm_source=b'), 'utm_source=b');
    });

    test('splits each part on its first "=" only', () {
      expect(campaignQuery('utm_source=a=b&utm_medium=c'), 'utm_medium=c');
      expect(campaignQuery('=utm_source&utm_medium=c'), 'utm_medium=c');
    });
  });

  group('campaign query sent to resolve', () {
    test('sends the example of the contract exactly as written there', () async {
      final api_ = Api();
      final sdk = bridge(api_, allowedHosts: {'myapp.strybok.link'});
      final tapped = Uri.parse(
        'https://MyApp.strybok.link/invite777?utm_source=instagram&fbclid=abc&utm_medium=two%20words&utm_source=x#top',
      );
      final link = await sdk.resolveUri(tapped);

      expect(link.uri, tapped);
      final request = api_.resolves.single;
      expect(request.url.queryParameters, {
        'url': 'https://myapp.strybok.link/invite777?utm_source=instagram',
      });
      expect(
        '${request.url}',
        'https://api.example.com/v1/public/resolve'
            '?url=https%3A%2F%2Fmyapp.strybok.link%2Finvite777%3Futm_source%3Dinstagram',
      );
    });

    test('sends all five values in the fixed order and nothing else of the URL', () async {
      final api_ = Api();
      await bridge(api_).resolveUri(
        Uri.parse(
          '$invite?utm_content=banner&token=secret&utm_term=shoes&email=a%40b.c'
          '&utm_campaign=spring_sale&gclid=G1&utm_medium=social&utm_id=7&utm_source=instagram#private',
        ),
      );
      final request = api_.resolves.single;
      expect(
        '${request.url}',
        resolveUrlFor(
          '$invite?utm_source=instagram&utm_medium=social'
          '&utm_campaign=spring_sale&utm_term=shoes&utm_content=banner',
        ),
      );
      // One query parameter only: the campaign values travel inside `url`, encoded.
      expect(request.url.queryParameters.keys, ['url']);
      for (final leaked in [
        'secret',
        'token',
        'email',
        'b.c',
        'gclid',
        'G1',
        'utm_id',
        'private',
      ]) {
        expect('${request.url}', isNot(contains(leaked)), reason: leaked);
      }
    });

    test('drops bad values, takes the first of a repeated key and decodes first', () async {
      final cases = {
        'utm_source=first&utm_source=second': '?utm_source=first',
        'utm_source=two%20words&utm_source=second': '',
        'utm_source=a+b&utm_medium=ok': '?utm_medium=ok',
        'utm_source=%69nstagram': '?utm_source=instagram',
        'utm%5Fsource=instagram': '?utm_source=instagram',
        'utm_source=a%40b.c&utm_medium=%D0%B2': '',
        'utm_source=${'a' * 64}': '?utm_source=${'a' * 64}',
        'utm_source=${'a' * 65}': '',
        'utm_source=&utm_medium': '',
        'UTM_SOURCE=a&Utm_Medium=b': '',
        'utm_source=%zz&utm_medium=%': '',
      };
      for (final MapEntry(key: query, value: sent) in cases.entries) {
        final api_ = Api();
        await bridge(api_).resolveUri(Uri.parse('$invite?$query'));
        expect('${api_.resolves.single.url}', resolveUrlFor('$invite$sent'), reason: query);
      }
    });

    test('sends exactly the earlier request when no campaign value is left', () async {
      // What versions before 0.3.0 built.
      final lookup = Uri(scheme: 'https', host: host, path: '/invite777');
      final before = api.replace(path: '/v1/public/resolve', queryParameters: {'url': '$lookup'});
      expect(
        '$before',
        'https://api.example.com/v1/public/resolve?url=https%3A%2F%2F$host%2Finvite777',
      );
      for (final suffix in [
        '',
        '?',
        '#utm_source=instagram',
        '?token=secret#f',
        '?utm_source=two%20words',
        '?utm_id=1&fbclid=2',
        '?#',
      ]) {
        final api_ = Api();
        await bridge(api_).resolveUri(Uri.parse('$invite$suffix'));
        final request = api_.resolves.single;
        expect(request.url, before, reason: suffix);
        expect('${request.url}', '$before', reason: suffix);
        expect(request.method, 'GET', reason: suffix);
        expect(request.headers, {'Accept': 'application/json'}, reason: suffix);
        expect(request.body, isEmpty, reason: suffix);
      }
    });

    test('changes nothing else of the request, and retries send the same one', () async {
      var calls = 0;
      final api_ = Api((_) => ++calls < 3 ? http.Response('', 503) : resolved());
      await bridge(api_).resolveUri(Uri.parse('$invite?utm_source=instagram&x=1'));
      expect(api_.resolves, hasLength(3));
      for (final request in api_.resolves) {
        expect('${request.url}', resolveUrlFor('$invite?utm_source=instagram'));
        expect(request.method, 'GET');
        expect(request.headers, {'Accept': 'application/json'});
        expect(request.body, isEmpty);
      }
    });

    test('a query never makes a foreign URL ours, and errors keep the URI as received', () async {
      final api_ = Api((_) => http.Response('', 404));
      final sdk = bridge(api_);
      const query = '?utm_source=instagram';
      for (final url in [
        'https://evil.example.com/invite777',
        'https://$host.evil.example.com/invite777',
        'http://$host/invite777',
        'https://user@$host/invite777',
        'https://user:pw@$host/invite777',
        'https://$host:8443/invite777',
        'https://$host/a/b',
        'https://$host/invite777/',
        'https://$host/a.b',
        'https://$host/',
        'https://$host',
      ]) {
        for (final uri in [Uri.parse(url), Uri.parse('$url$query')]) {
          expect(sdk.isStrybokUri(uri), isFalse, reason: '$uri');
          await expectLater(
            sdk.resolveUri(uri),
            throwsA(isA<UnsupportedLinkException>().having((e) => e.uri, 'uri', uri)),
          );
        }
      }
      // What looks like an authority inside the query is only text.
      expect(sdk.isStrybokUri(Uri.parse('https://evil.example.com/abc?utm_source=$host')), isFalse);
      expect(sdk.isStrybokUri(Uri.parse('$invite$query')), isTrue);
      expect(sdk.isStrybokUri(Uri.parse('$invite?utm_source=x@evil.example.com:8443/y')), isTrue);
      expect(api_.resolves, isEmpty);

      final tapped = Uri.parse('$invite?utm_source=instagram&token=secret');
      await expectLater(
        sdk.resolveUri(tapped),
        throwsA(isA<LinkNotFoundException>().having((e) => e.uri, 'uri', tapped)),
      );
    });
  });

  group('campaign of a resolved link', () {
    test('is what the server sent', () async {
      final api_ = Api(
        (_) => resolved({
          'campaign': {'source': 'instagram', 'medium': 'social', 'campaign': 'spring'},
        }),
      );
      final link = await bridge(api_).resolveUri(Uri.parse('$invite?utm_source=instagram'));
      expect(
        link.campaign,
        const LinkCampaign(source: 'instagram', medium: 'social', campaign: 'spring'),
      );
      expect(link.campaign.source, 'instagram');
      expect(link.campaign.term, isNull);
      expect(link.campaign.content, isNull);
      expect(link.campaign.isEmpty, isFalse);
      expect(link.campaign.isNotEmpty, isTrue);
    });

    test('keeps all five fields', () async {
      const campaign = {'source': 'a', 'medium': 'b', 'campaign': 'c', 'term': 'd', 'content': 'e'};
      final link = await bridge(
        Api((_) => resolved({'campaign': campaign})),
      ).resolveUri(Uri.parse(invite));
      expect(link.campaign.toJson(), campaign);
      expect(link.campaign.toJson().keys, ['source', 'medium', 'campaign', 'term', 'content']);
    });

    test('comes from the answer, not from the URL', () async {
      final api_ = Api(
        (_) => resolved({
          'campaign': {'source': 'newsletter'},
        }),
      );
      final link = await bridge(
        api_,
      ).resolveUri(Uri.parse('$invite?utm_source=instagram&utm_medium=social'));
      expect(link.campaign, const LinkCampaign(source: 'newsletter'));

      final none = await bridge(
        Api((_) => resolved()),
      ).resolveUri(Uri.parse('$invite?utm_source=instagram'));
      expect(none.campaign.isEmpty, isTrue);
    });

    test('is empty, never null, when missing or not an object', () async {
      final none = await bridge(Api((_) => resolved())).resolveUri(Uri.parse(invite));
      expect(none.campaign, const LinkCampaign());
      for (final Object? campaign in [
        null,
        'instagram',
        42,
        true,
        <Object?>[],
        ['instagram'],
        <String, Object?>{},
      ]) {
        final api_ = Api((_) => resolved({'campaign': campaign}));
        final link = await bridge(api_).resolveUri(Uri.parse(invite));
        expect(link.campaign, const LinkCampaign(), reason: '$campaign');
        expect(link.campaign.isEmpty, isTrue, reason: '$campaign');
        expect(link.campaign.toJson(), isEmpty, reason: '$campaign');
        expect(link.routePath, '/x');
      }
    });

    test('ignores fields that are not strings and keys it does not know', () async {
      final api_ = Api(
        (_) => resolved({
          'campaign': {
            'source': 'instagram',
            'medium': 7,
            'campaign': null,
            'term': {'a': 1},
            'content': ['x'],
            'id': 'ignored',
            'utm_source': 'ignored',
            'Source': 'ignored',
          },
        }),
      );
      final link = await bridge(api_).resolveUri(Uri.parse(invite));
      expect(link.campaign, const LinkCampaign(source: 'instagram'));
      expect(link.campaign.toJson(), {'source': 'instagram'});
    });

    test('a malformed answer is still an error, with or without campaign', () async {
      final api_ = Api(
        (_) => http.Response(
          jsonEncode({
            'linkId': 'l',
            'campaign': {'source': 'a'},
          }),
          200,
        ),
      );
      await expectLater(
        bridge(api_).resolveUri(Uri.parse(invite)),
        throwsA(isA<StrybokServerException>()),
      );
    });

    test('is delivered on the stream and by getInitialLink', () async {
      final api_ = Api(
        (_) => resolved({
          'campaign': {'source': 'instagram'},
        }),
      );
      final source = FakeLinkSource(initialLink: Uri.parse('$invite?utm_source=instagram'));
      final sdk = bridge(api_, source: source);
      expect((await sdk.getInitialLink())?.campaign, const LinkCampaign(source: 'instagram'));

      final received = <ResolvedDeepLink>[];
      sdk.links.listen(received.add);
      source.emit(Uri.parse('https://$host/other?utm_source=instagram'));
      await settle();
      expect(received.map((link) => link.campaign), [const LinkCampaign(source: 'instagram')]);
    });
  });

  group('LinkCampaign', () {
    test('is a value: empty by default, equal by content', () {
      const empty = LinkCampaign();
      expect(empty.isEmpty, isTrue);
      expect(empty.isNotEmpty, isFalse);
      expect(empty.toJson(), isEmpty);
      expect(const LinkCampaign(term: 'x').isEmpty, isFalse);
      expect(
        const LinkCampaign(source: 'a', content: 'b'),
        const LinkCampaign(source: 'a', content: 'b'),
      );
      expect(const LinkCampaign(source: 'a').hashCode, const LinkCampaign(source: 'a').hashCode);
      expect(const LinkCampaign(source: 'a'), isNot(const LinkCampaign(medium: 'a')));
      expect('${const LinkCampaign(source: 'a')}', 'LinkCampaign({source: a})');
    });

    test('a link built without a campaign has an empty one', () {
      final link = ResolvedDeepLink(
        uri: Uri.parse(invite),
        linkId: 'l',
        appId: 'a',
        routePath: '/x',
        payload: const {},
      );
      expect(link.campaign, const LinkCampaign());
    });
  });

  group('campaign in app_open events', () {
    Future<http.Request> eventFor(Map<String, Object?> answer, [String url = invite]) async {
      final api_ = Api((_) => resolved(answer));
      final source = FakeLinkSource();
      final sdk = bridge(api_, source: source);
      sdk.links.listen((_) {});
      await sdk.initialize();
      source.emit(Uri.parse(url));
      await settle();
      return api_.eventRequests.single;
    }

    test('reports the campaign exactly as resolve returned it', () async {
      final request = await eventFor(
        {
          'campaign': {'source': 'instagram', 'medium': 'social', 'id': 'x', 'term': 5},
        },
        // The URL says something else: it is never the source of the reported values.
        '$invite?utm_source=facebook&utm_term=shoes&utm_content=banner',
      );
      final event = jsonDecode(request.body) as Map<String, Object?>;
      expect(
        event.keys,
        unorderedEquals(['eventId', 'linkId', 'type', 'platform', 'sdkVersion', 'campaign']),
      );
      expect(event['campaign'], {'source': 'instagram', 'medium': 'social'});
      expect(event['linkId'], 'link_1');
      expect(event['type'], 'app_open');
      expect(event['sdkVersion'], strybokSdkVersion);
      expect(request.method, 'POST');
      expect('${request.url}', 'https://api.example.com/v1/public/events');
      expect(request.headers['Content-Type'], startsWith('application/json'));
    });

    test('reports all five fields when resolve returned them', () async {
      const campaign = {'source': 'a', 'medium': 'b', 'campaign': 'c', 'term': 'd', 'content': 'e'};
      final request = await eventFor({'campaign': campaign});
      expect((jsonDecode(request.body) as Map<String, Object?>)['campaign'], campaign);
    });

    test('omits campaign when resolve returned none, whatever the URL says', () async {
      for (final answer in <Map<String, Object?>>[
        {},
        {'campaign': <String, Object?>{}},
        {'campaign': null},
        {
          'campaign': {'source': 1},
        },
      ]) {
        final request = await eventFor(answer, '$invite?utm_source=instagram');
        final event = jsonDecode(request.body) as Map<String, Object?>;
        expect(
          event.keys,
          unorderedEquals(['eventId', 'linkId', 'type', 'platform', 'sdkVersion']),
          reason: '$answer',
        );
      }
    });
  });

  group('duplicates and campaign queries', () {
    test('the same slug with different campaign values is two links', () async {
      final api_ = Api((request) {
        final lookup = request.url.queryParameters['url']!;
        final source = lookup.contains('utm_source=') ? lookup.split('utm_source=')[1] : 'none';
        return resolved({
          'campaign': {'source': source},
        });
      });
      final source = FakeLinkSource();
      final sdk = bridge(api_, source: source);
      final received = <ResolvedDeepLink>[];
      sdk.links.listen(received.add);
      await sdk.initialize();

      source.emit(Uri.parse('$invite?utm_source=instagram'));
      source.emit(Uri.parse('$invite?utm_source=facebook'));
      source.emit(Uri.parse(invite));
      await settle();
      expect(
        received.map((link) => link.campaign.source),
        unorderedEquals(['instagram', 'facebook', 'none']),
      );
      expect(api_.resolves, hasLength(3));
      expect(
        api_.events.map((event) => (event['campaign']! as Map)['source']),
        unorderedEquals(['instagram', 'facebook', 'none']),
      );
    });

    test('compares the URI as received, not the lookup', () async {
      final now = DateTime(2026);
      final api_ = Api();
      final source = FakeLinkSource();
      final sdk = bridge(api_, source: source, clock: () => now);
      final received = <ResolvedDeepLink>[];
      sdk.links.listen(received.add);
      await sdk.initialize();

      // The identical string is one tap.
      source.emit(Uri.parse('$invite?utm_source=instagram&x=1'));
      source.emit(Uri.parse('$invite?utm_source=instagram&x=1'));
      await settle();
      expect(received, hasLength(1));

      // Different strings are different links, even when they send the same lookup.
      source.emit(Uri.parse('$invite?utm_source=instagram&x=2'));
      source.emit(Uri.parse('$invite?x=2&utm_source=instagram'));
      await settle();
      expect(
        received.map((link) => '${link.uri}'),
        unorderedEquals([
          '$invite?utm_source=instagram&x=1',
          '$invite?utm_source=instagram&x=2',
          '$invite?x=2&utm_source=instagram',
        ]),
      );
      expect(api_.resolves.map((request) => '${request.url}').toSet(), hasLength(1));
      expect(api_.eventRequests, hasLength(3));
    });

    test('a launch link replayed on the stream with its query is delivered once', () async {
      final api_ = Api(
        (_) => resolved({
          'campaign': {'source': 'instagram'},
        }),
      );
      final source = FakeLinkSource(
        initialLink: Uri.parse('$invite?utm_source=instagram'),
        replayInitialLinkOnStream: true,
      );
      final sdk = bridge(api_, source: source);
      final received = <ResolvedDeepLink>[];
      sdk.links.listen(received.add);
      await sdk.initialize();
      await settle();
      expect(received, hasLength(1));
      expect(api_.resolves, hasLength(1));
      expect(api_.eventRequests, hasLength(1));
    });
  });
}
