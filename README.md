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

- **Early release (0.1.x)**: covered by unit and widget tests; verification on physical devices
  is still pending.
- Deferred deep linking is not supported.

## Install

```sh
flutter pub add strybok
```

## Build and test

In the SDK directory:

```sh
flutter analyze
flutter test
```

## Licence

Apache 2.0, see [LICENSE](./LICENSE).
