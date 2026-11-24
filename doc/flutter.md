# Flutter integration

The `strybok` package receives verified HTTPS links through the
[`app_links`](https://pub.dev/packages/app_links) plugin, asks the Strybok API which in-app
route a link stands for, and hands your app each link exactly once.

> **Status:** early release (0.1.x), published on [pub.dev](https://pub.dev/packages/strybok).
> Covered by unit and widget tests; not yet verified on physical devices
> (see the [manual test plan](./manual-test-plan.md)).
>
> Deferred deep linking is **not supported**: a link tapped before the app is installed is not
> restored after installation.

## 1. Prerequisites

1. Create an application in Strybok with your iOS and Android identifiers.
2. Read its setup data: `GET /v1/apps/:appId/integration` returns the managed hostname
   (for example `my-app-x7k2p9.links.example.com`) and ready-to-copy snippets.
3. Complete the native setup: [Android](./android.md) and [iOS](./ios.md). Without it the OS
   never delivers links to the app, and the SDK has nothing to receive.

## 2. Add the package

```sh
flutter pub add strybok
```

Or add it to `pubspec.yaml` yourself:

```yaml
dependencies:
  strybok: ^0.1.0
```

The source is at [github.com/strybok/strybok-flutter](https://github.com/strybok/strybok-flutter).

## 3. Disable Flutter's built-in deep link handler

`app_links` and Flutter's own handler would both react to a link, which causes duplicate
navigation. Turn the built-in one off:

`android/app/src/main/AndroidManifest.xml`, inside the main `<activity>`:

```xml
<meta-data android:name="flutter_deeplinking_enabled" android:value="false" />
```

`ios/Runner/Info.plist`:

```xml
<key>FlutterDeepLinkingEnabled</key>
<false/>
```

## 4. Use it

```dart
final strybok = Strybok(
  apiBaseUrl: Uri.parse('https://api.example.com'),
  allowedHosts: {'my-app-x7k2p9.links.example.com'},
  onError: (error) => debugPrint('Link failed: $error'),
);

strybok.links.listen((link) {
  // link.routePath == '/invite/abc123'
  // link.payload['invitationId'] == 'abc123'
  router.go(link.routePath);
});
await strybok.initialize();
```

One subscription covers every case:

| Situation                                 | What happens                                                                                          |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| **Cold start** (app launched by the link) | `initialize()` resolves the launch link. It is kept until you listen to `links`, then delivered once. |
| **Background** (app resumed by the link)  | Delivered on `links`.                                                                                 |
| **Foreground**                            | Delivered on `links`.                                                                                 |

If the platform reports the same tap twice (for example as launch link _and_ on the stream), the
duplicate is dropped (`dedupeWindow`, 2 s by default). The same link tapped again later is a new
delivery.

Prefer to read the launch link yourself? `await strybok.getInitialLink()` returns it at most
once and removes it from `links`, so combining both never navigates twice.

### API

| Member              | Purpose                                                                                       |
| ------------------- | --------------------------------------------------------------------------------------------- |
| `initialize()`      | Start listening; completes after the launch link was handled. Idempotent.                     |
| `links`             | Broadcast stream of `ResolvedDeepLink` (`uri`, `linkId`, `appId`, `routePath`, `payload`).    |
| `getInitialLink()`  | The launch link, if not delivered through `links` yet.                                        |
| `resolveUri(uri)`   | Resolve a URI explicitly (QR scanner, tests). Does not emit on `links` or report an app open. |
| `isStrybokUri(uri)` | Whether a URI is one of this app's links.                                                     |
| `dispose()`         | Stop listening and release resources.                                                         |

Options: `timeout` (5 s per attempt), `maxRetries` (2; only timeouts, network errors and 5xx are
retried — resolving is an idempotent GET), `retryDelay`, `dedupeWindow`, `reportAppOpens`,
`onError`, plus `linkSource` / `httpClient` for tests.

### Errors

`resolveUri` throws, and `onError` receives, a `StrybokException`:

| Type                                                  | Meaning                                                                                                                                              |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `UnsupportedLinkException`                            | Not `https`, host not in `allowedHosts`, or not a single-slug path. Thrown before any network call. Ignored silently for links arriving from the OS. |
| `LinkNotFoundException`                               | Unknown, disabled or expired link.                                                                                                                   |
| `StrybokTimeoutException` / `StrybokNetworkException` | No answer after all retries (e.g. offline). The app keeps working; the link is simply not opened.                                                    |
| `StrybokServerException`                              | Unexpected status or malformed response.                                                                                                             |

## 5. Treat routes as untrusted input

`routePath` and `payload` are data from the network. Match the route against routes your app
knows before navigating, and never execute payload contents. The example app only accepts
`/invite/<code>`.

## 6. Links that arrive before sign-in

If a link needs an authenticated user, remember the route and open it after login instead of
dropping it. See [`lib/app.dart`](../example/lib/app.dart) of the example app:
the link listener stores the route in the session while signed out, and the `go_router` redirect
opens it once the user signs in.

## 7. Analytics and privacy

After a link is delivered the SDK sends one best-effort `app_open` event
(`POST /v1/public/events`) containing a random event id, the link id, the platform
(`ios`/`android`) and the SDK version — no device identifiers. It never delays navigation and all
failures are ignored. Disable it with `reportAppOpens: false`.

The dashboard shows these as **App opens**, separate from browser fallbacks counted by the
server. The number is self-reported by the app and is not a count of unique people.

Only the link's host and slug are sent to `resolve`; query parameters and fragments stay on the
device.

## 8. Testing your integration

`package:strybok/testing.dart` provides `FakeLinkSource` to simulate links:

```dart
final source = FakeLinkSource(initialLink: Uri.parse('https://my-app.links.example.com/abc'));
final strybok = Strybok(
  apiBaseUrl: Uri.parse('https://api.example.com'),
  allowedHosts: {'my-app.links.example.com'},
  linkSource: source,
  httpClient: MockClient((request) async => http.Response('{...}', 200)),
);
source.emit(Uri.parse('https://my-app.links.example.com/other'));
```

The example app's [`test/deep_link_test.dart`](../example/test/deep_link_test.dart)
shows complete widget tests.

## Troubleshooting

| Symptom                                                     | Check                                                                                                                                 |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Link opens the browser/store instead of the app             | Native association is not verified: see the Android and iOS guides. The SDK is not involved yet at this point.                        |
| App opens but nothing happens                               | Host missing from `allowedHosts`; `onError` output; API reachable from the device?                                                    |
| Screen opens twice                                          | Flutter's built-in handler is still enabled (step 3), or you navigate from both `getInitialLink()` and your own `app_links` listener. |
| Works on tap in Notes/Messages, not from Instagram/Telegram | In-app browsers often do not hand links to apps. Users get the fallback page with a manual button.                                    |
