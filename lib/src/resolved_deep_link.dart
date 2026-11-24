import 'package:flutter/foundation.dart';

/// A link resolved by the Strybok API.
///
/// [routePath] and [payload] are plain data chosen by whoever created the link.
/// Treat them like any other untrusted input: map them onto routes your app
/// already knows, never execute them.
@immutable
class ResolvedDeepLink {
  const ResolvedDeepLink({
    required this.uri,
    required this.linkId,
    required this.appId,
    required this.routePath,
    required this.payload,
  });

  /// The full URL that opened the app.
  final Uri uri;
  final String linkId;
  final String appId;

  /// In-app route, always starting with `/` (for example `/invite/abc123`).
  final String routePath;

  /// Decoded JSON object attached to the link; empty when none was set.
  final Map<String, Object?> payload;

  @override
  String toString() => 'ResolvedDeepLink($routePath, linkId: $linkId)';
}
