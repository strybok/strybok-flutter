/// Build-time configuration. Override with `--dart-define`, for example:
///
/// ```sh
/// flutter run \
///   --dart-define=STRYBOK_API=https://api.example.com \
///   --dart-define=STRYBOK_HOST=my-app-123.links.example.com
/// ```
///
/// The host must be the same one declared in `AndroidManifest.xml` and in the
/// iOS Associated Domains entitlement.
abstract final class AppConfig {
  static const apiBaseUrl = String.fromEnvironment(
    'STRYBOK_API',
    defaultValue: 'https://api.example.com',
  );
  static const linkHost = String.fromEnvironment(
    'STRYBOK_HOST',
    defaultValue: 'demo.links.example.com',
  );
}
