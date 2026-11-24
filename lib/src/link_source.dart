import 'package:app_links/app_links.dart';

/// Where incoming link URIs come from. The default implementation wraps the
/// `app_links` plugin; tests and custom integrations can provide their own.
abstract interface class LinkSource {
  /// The link that launched the app (cold start), or `null`.
  Future<Uri?> getInitialLink();

  /// Links received while the app is running. Implementations may also replay
  /// the initial link here; the SDK de-duplicates it.
  Stream<Uri> get uriStream;
}

/// [LinkSource] backed by the `app_links` plugin.
class AppLinksSource implements LinkSource {
  AppLinksSource([AppLinks? appLinks]) : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;

  @override
  Future<Uri?> getInitialLink() => _appLinks.getInitialLink();

  @override
  Stream<Uri> get uriStream => _appLinks.uriLinkStream;
}
