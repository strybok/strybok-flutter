# strybok (Flutter SDK)

Receives iOS Universal Links / Android App Links, resolves them through the Strybok API to an
in-app route and payload, and delivers each link exactly once — on cold start, from the
background and in the foreground.

```dart
final strybok = Strybok(
  apiBaseUrl: Uri.parse('https://api.example.com'),
  allowedHosts: {'my-app-123.links.example.com'},
);
strybok.links.listen((link) => router.go(link.routePath));
await strybok.initialize();
```

Full guide, native setup and troubleshooting: [`doc/flutter.md`](./doc/flutter.md).
A complete app: [the example app](./example).

- Not published to pub.dev yet: device verification is still pending.
- Deferred deep linking is not supported.

## Install

In `pubspec.yaml`:

```yaml
dependencies:
  strybok:
    git:
      url: https://github.com/strybok/strybok-flutter.git
      ref: 0.1.0
```

## Build and test

In the SDK directory:

```sh
flutter analyze
flutter test
```

## Licence

Apache 2.0, see [LICENSE](./LICENSE).
