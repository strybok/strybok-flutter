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

Every link also has `campaign`: the link's campaign values with the `utm_*` parameters of the
tapped URL on top (`source`, `medium`, `campaign`, `term`, `content`; each `null` when not set).
They are labels chosen by whoever shared the link, so use them for attribution only:

```dart
strybok.links.listen((link) {
  analytics.logEvent('link_opened', {'source': ?link.campaign.source});
  router.go(link.routePath);
});
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

- **Early release (0.x)**: covered by unit and widget tests; verification on physical devices
  is still pending.
- Deferred links (restoring a link tapped before the app was installed) are optional, off by
  default and not run on a device yet; see below.

## Deferred links (optional)

The package is pure Dart: it has **no native code and no store integration**, and it never
reads the clipboard. Your app supplies the missing pieces and the package does the rest (once
per installation, delivery through `links` with `isDeferred: true`, never through
`getInitialLink()`, nothing to `onError`).

```dart
final strybok = Strybok(
  apiBaseUrl: Uri.parse('https://api.example.com'),
  allowedHosts: {'my-app-123.links.example.com'},
  deferredLinks: true, // or strybok.enableDeferredLinks() after a consent screen
  deferredLinkStore: myStore, // your DeferredLinkStore, e.g. on shared_preferences; required
  // Android: your functions that return the store's raw install referrer.
  androidPackageName: 'com.example.app',
  installReferrerSources: [playInstallReferrer],
  // iOS: there is no install referrer.
  iosBundleId: 'com.example.app',
);

// iOS: the text the person pasted with your paste button.
final result = await strybok.redeemPastedLink(pastedText);
```

- **Android:** a source returns `InstallReferrerAnswer.referrer(string)`, `.unavailableForNow`
  or `.unavailable`. The guide has the Kotlin and Dart glue for Google Play. Huawei AppGallery
  and Samsung Galaxy Store are unverified, even in the native Android SDK.
- **iOS, pasted link:** costs every visitor without the app an extra page and tap, and works
  only if the person copies there and pastes in your app. Flutter has no widget for Apple's
  paste button; the guide lists the choices.
- **iOS, probabilistic matching** (`allowProbabilisticMatching`, plus the `deviceFamily` and
  `locale` callbacks): off by default and not recommended. Apple's rules forbid it and the App
  Review and legal risk is the app owner's; a match can be another person's link on a shared
  network; it fails with Private Relay or a VPN; it affects your privacy policy and labels; its
  accuracy is unknown. Check `link.isProbabilisticMatch` and never let such a link sign anyone
  in, accept an invitation or show personal content.
- Without `deferredLinkStore`, or without the identifier of the platform, the status stays
  `DeferredLinkStatus.disabled`. `strybok.deferredLinkStatus` says where the check stands.

Details, costs and the app-side code:
[`doc/flutter.md`](./doc/flutter.md#deferred-links-optional),
[Android](./doc/android.md), [iOS](./doc/ios.md).

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
