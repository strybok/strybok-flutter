# strybok (Flutter SDK)

[![pub package](https://img.shields.io/pub/v/strybok.svg)](https://pub.dev/packages/strybok) [![pub points](https://img.shields.io/pub/points/strybok.svg)](https://pub.dev/packages/strybok/score) [![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](./LICENSE)

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

It can also create links for a "Share" button:

```dart
final strybok = Strybok(
  apiBaseUrl: Uri.parse('https://api.example.com'),
  allowedHosts: {'my-app-123.links.example.com'},
  clientKey: 'pk_…', // publishable key from the dashboard, never a secret API key
);
final link = await strybok.createLink('/product/42', payload: {'productId': 42});
share('${link.url}');
```

Full guide, native setup and troubleshooting: [`doc/flutter.md`](./doc/flutter.md).
A complete app: [the example app](./example).

- **Early release (0.2.x)**: covered by unit and widget tests; verification on physical devices
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
