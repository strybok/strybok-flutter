import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:strybok/strybok.dart';

import 'session.dart';

/// Routes a deep link may open. `routePath` comes from the network, so it is
/// matched against known routes instead of being trusted blindly.
final RegExp _deepLinkRoutes = RegExp(r'^/invite/[A-Za-z0-9_-]{1,64}$');

GoRouter buildRouter(Session session) => GoRouter(
  initialLocation: '/',
  refreshListenable: session,
  redirect: (context, state) {
    final atLogin = state.matchedLocation == '/login';
    if (!session.signedIn) {
      if (atLogin) return null;
      // Keep where the user was heading (e.g. a cold-start deep link).
      if (state.matchedLocation != '/') {
        session.rememberRoute(state.uri.toString(), notify: false);
      }
      return '/login';
    }
    if (atLogin) return session.takePendingRoute() ?? '/';
    return null;
  },
  routes: [
    GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
    GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
    GoRoute(
      path: '/invite/:code',
      builder: (_, state) => InviteScreen(code: state.pathParameters['code']!),
    ),
  ],
);

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key, required this.strybok, required this.session});

  final Strybok strybok;
  final Session session;

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  late final GoRouter _router = buildRouter(widget.session);
  StreamSubscription<ResolvedDeepLink>? _links;

  @override
  void initState() {
    super.initState();
    // One subscription for cold start, background and foreground links: the SDK
    // keeps the launch link until we listen and never delivers a link twice.
    _links = widget.strybok.links.listen(_open);
    unawaited(widget.strybok.initialize());
  }

  void _open(ResolvedDeepLink link) {
    if (!_deepLinkRoutes.hasMatch(link.routePath)) return;
    if (widget.session.signedIn) {
      _router.go(link.routePath);
    } else {
      // Not signed in yet: remember the route; the redirect opens it after login.
      widget.session.rememberRoute(link.routePath);
      _router.go('/login');
    }
  }

  @override
  void dispose() {
    unawaited(_links?.cancel());
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Strybok example',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    routerConfig: _router,
    builder: (context, child) => SessionScope(session: widget.session, child: child!),
  );
}

class SessionScope extends InheritedNotifier<Session> {
  const SessionScope({super.key, required Session session, required super.child})
    : super(notifier: session);

  static Session of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SessionScope>()!.notifier!;
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Home'),
      actions: [
        TextButton(onPressed: SessionScope.of(context).signOut, child: const Text('Sign out')),
      ],
    ),
    body: const Center(child: Text('Open a Strybok link to see an invitation.')),
  );
}

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (session.pendingRoute != null)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text('Sign in to open your link.'),
              ),
            FilledButton(onPressed: session.signIn, child: const Text('Sign in')),
          ],
        ),
      ),
    );
  }
}

class InviteScreen extends StatelessWidget {
  const InviteScreen({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Invitation')),
    body: Center(child: Text('Invitation code: $code', key: const Key('invite-code'))),
  );
}
