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

/// A [LinkSource] that can also hand over every link as the exact string the
/// platform received. The SDK then reads only these strings.
///
/// It matters with `parameterLinks`: whether a URL is a link of this app and
/// the path that is sent are read from the URL as received, and a [Uri] has
/// already been rewritten by `Uri.parse` (it removes `.` and `..` segments and
/// changes escapes). [AppLinksSource] and `FakeLinkSource` implement it.
abstract interface class RawLinkSource implements LinkSource {
  /// The link that launched the app, exactly as received, or `null`.
  Future<String?> getInitialLinkString();

  /// Links received while the app is running, exactly as received. Like
  /// [uriStream] it may replay the initial link.
  Stream<String> get stringLinkStream;
}

/// [LinkSource] backed by the `app_links` plugin.
class AppLinksSource implements RawLinkSource {
  AppLinksSource([AppLinks? appLinks]) : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;

  @override
  Future<Uri?> getInitialLink() => _appLinks.getInitialLink();

  @override
  Stream<Uri> get uriStream => _appLinks.uriLinkStream;

  @override
  Future<String?> getInitialLinkString() => _appLinks.getInitialLinkString();

  @override
  Stream<String> get stringLinkStream => _appLinks.stringLinkStream;
}
