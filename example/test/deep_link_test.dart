import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strybok/strybok.dart';
import 'package:strybok/testing.dart';
import 'package:strybok_example/app.dart';
import 'package:strybok_example/session.dart';

const host = 'demo.links.example.com';
final invite = Uri.parse('https://$host/invite777');

/// Fake API: maps slugs to routes like the real resolve endpoint would.
class FakeApi {
  final routes = {'invite777': '/invite/abc123', 'other999': '/invite/zzz999', 'admin': '/admin'};
  int resolveCalls = 0;

  late final client = MockClient((request) async {
    if (request.url.path == '/v1/public/events') return http.Response('', 202);
    resolveCalls++;
    final slug = Uri.parse(request.url.queryParameters['url']!).path.substring(1);
    final route = routes[slug];
    if (route == null) return http.Response('{}', 404);
    return http.Response(
      jsonEncode({'linkId': 'link_$slug', 'appId': 'app_demo', 'routePath': route, 'payload': {}}),
      200,
    );
  });
}

/// Counts pages pushed onto the navigator to prove a link navigates once.
Future<({FakeApi api, FakeLinkSource source, Session session})> pumpApp(
  WidgetTester tester, {
  Uri? initialLink,
  bool signedIn = true,
  bool replayInitial = false,
}) async {
  final api = FakeApi();
  final source = FakeLinkSource(initialLink: initialLink, replayInitialLinkOnStream: replayInitial);
  final session = Session(signedIn: signedIn);
  final strybok = Strybok(
    apiBaseUrl: Uri.parse('https://api.example.com'),
    allowedHosts: {host},
    linkSource: source,
    httpClient: api.client,
  );
  addTearDown(strybok.dispose);
  await tester.pumpWidget(ExampleApp(strybok: strybok, session: session));
  await tester.pumpAndSettle();
  return (api: api, source: source, session: session);
}

void main() {
  testWidgets('cold start with a link opens the invite screen once', (tester) async {
    final app = await pumpApp(tester, initialLink: invite, replayInitial: true);

    expect(find.text('Invitation code: abc123'), findsOneWidget);
    expect(app.api.resolveCalls, 1, reason: 'the replayed launch link must be de-duplicated');
  });

  testWidgets('a link received while running navigates to its screen', (tester) async {
    final app = await pumpApp(tester);
    expect(find.text('Home'), findsOneWidget);

    app.source.emit(invite);
    await tester.pumpAndSettle();
    expect(find.text('Invitation code: abc123'), findsOneWidget);

    app.source.emit(Uri.parse('https://$host/other999'));
    await tester.pumpAndSettle();
    expect(find.text('Invitation code: zzz999'), findsOneWidget);
    expect(find.text('Invitation code: abc123'), findsNothing);
    expect(app.api.resolveCalls, 2);
  });

  testWidgets('a duplicate delivery of the same tap does not navigate twice', (tester) async {
    final app = await pumpApp(tester);
    app.source.emit(invite);
    app.source.emit(invite);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite-code')), findsOneWidget);
    expect(app.api.resolveCalls, 1);
  });

  testWidgets('signed out: the link is kept and opened after signing in', (tester) async {
    final app = await pumpApp(tester, initialLink: invite, signedIn: false);

    expect(find.text('Sign in to open your link.'), findsOneWidget);
    expect(find.byKey(const Key('invite-code')), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Invitation code: abc123'), findsOneWidget);
    expect(app.session.pendingRoute, isNull);
    expect(app.api.resolveCalls, 1);
  });

  testWidgets('signed out without a link lands on home after signing in', (tester) async {
    await pumpApp(tester, signedIn: false);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('foreign hosts, unknown links and unknown routes do not navigate', (tester) async {
    final app = await pumpApp(tester);

    app.source.emit(Uri.parse('https://evil.example.com/invite777'));
    app.source.emit(Uri.parse('https://$host/missing1'));
    app.source.emit(Uri.parse('https://$host/admin')); // resolves, but is not a known route
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);
    expect(find.byKey(const Key('invite-code')), findsNothing);
    expect(app.api.resolveCalls, 2, reason: 'the foreign host is never sent to the API');
  });
}
