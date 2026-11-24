/// Strybok Flutter SDK.
///
/// Receives verified HTTPS links (iOS Universal Links / Android App Links),
/// resolves them through the Strybok API and delivers every link exactly once.
///
/// Deferred deep linking (restoring a link after the app is installed from a
/// store) is not supported.
library;

export 'src/exceptions.dart';
export 'src/link_bridge.dart';
export 'src/link_source.dart';
export 'src/resolved_deep_link.dart';
