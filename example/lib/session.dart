import 'package:flutter/foundation.dart';

/// Minimal fake session: enough to demonstrate keeping a deep link while the
/// user signs in. A real app would restore this from secure storage.
class Session extends ChangeNotifier {
  Session({bool signedIn = false}) : _signedIn = signedIn; // ignore: prefer_initializing_formals

  bool _signedIn;
  String? _pendingRoute;

  bool get signedIn => _signedIn;

  /// Route from a deep link that arrived while signed out.
  String? get pendingRoute => _pendingRoute;

  /// Remembers [route] for after sign-in. Pass `notify: false` when calling
  /// from a router redirect, which must not trigger another refresh.
  void rememberRoute(String route, {bool notify = true}) {
    if (_pendingRoute == route) return;
    _pendingRoute = route;
    if (notify) notifyListeners();
  }

  /// Returns the remembered route once and forgets it.
  String? takePendingRoute() {
    final route = _pendingRoute;
    _pendingRoute = null;
    return route;
  }

  void signIn() {
    _signedIn = true;
    notifyListeners();
  }

  void signOut() {
    _signedIn = false;
    _pendingRoute = null;
    notifyListeners();
  }
}
