# Flutter integration

The `strybok` package receives verified HTTPS links through the
[`app_links`](https://pub.dev/packages/app_links) plugin, asks the Strybok API which in-app
route a link stands for, and hands your app each link exactly once.

> **Status:** early release (0.2.x), published on [pub.dev](https://pub.dev/packages/strybok).
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
  strybok: ^0.2.0
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
| `createLink(route)` | Create a link to share (section 5). Needs `clientKey`.                                        |
| `dispose()`         | Stop listening and release resources.                                                         |

Options: `timeout` (5 s per attempt), `maxRetries` (2; only timeouts, network errors and 5xx are
retried — resolving is an idempotent GET), `retryDelay`, `dedupeWindow`, `reportAppOpens`,
`onError`, `clientKey` (only for `createLink`), plus `linkSource` / `httpClient` for tests.

### Errors

`resolveUri` throws, and `onError` receives, a `StrybokException`:

| Type                                                  | Meaning                                                                                                                                              |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `UnsupportedLinkException`                            | Not `https`, host not in `allowedHosts`, or not a single-slug path. Thrown before any network call. Ignored silently for links arriving from the OS. |
| `LinkNotFoundException`                               | Unknown, disabled or expired link.                                                                                                                   |
| `StrybokTimeoutException` / `StrybokNetworkException` | No answer after all retries (e.g. offline). The app keeps working; the link is simply not opened.                                                    |
| `StrybokServerException`                              | Unexpected status or malformed response.                                                                                                             |

## 5. Create a link to share

A "Share" button can ask Strybok for a short link to the screen the user is looking at:

```dart
final strybok = Strybok(
  apiBaseUrl: Uri.parse('https://api.example.com'),
  allowedHosts: {'my-app-x7k2p9.links.example.com'},
  clientKey: 'pk_…',
);

try {
  final link = await strybok.createLink(
    '/product/42',
    payload: {'productId': 42}, // optional, like title, description and imageUrl
    title: 'Red shoes',
    description: 'Look at these',
    imageUrl: Uri.parse('https://cdn.example.com/shoes.png'),
  );
  share('${link.url}'); // also: link.slug, link.routePath, link.linkId
} on StrybokRateLimitedException catch (error) {
  showMessage('Try again in ${error.retryAfter?.inSeconds ?? 60} s');
} on StrybokException catch (error) {
  showMessage('Could not create the link: ${error.message}');
}
```

Before it works, switch the feature on in the dashboard: open the application, go to **Links
from the app**, enable it and list the **route patterns** the app may create links for (for
example `/product/*`). The dashboard then shows the **publishable key**, which starts with
`pk_`; pass it as `clientKey`. This key is safe to ship in the app because it can only create
links for those patterns. Never put a secret API key (`lb_…`) in an app; `createLink` does not
accept one.

`createLink` runs only when you call it. It is not part of `initialize()`, needs no
`allowedHosts`, and works before or without `initialize()`. Asking again with the same content
returns the same link, so the SDK retries timeouts, network errors and 5xx answers with the
usual `timeout`, `maxRetries` and `retryDelay`.

It throws a `StrybokException`; these errors never go to `onError`:

| Type                                                                             | Meaning                                                                                            | What to do                         |
| -------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ---------------------------------- |
| `StrybokUnauthorizedException`                                                   | No `clientKey`, or the key is wrong, was replaced, or the feature is switched off.                 | Fix the key or the dashboard.      |
| `RouteNotAllowedException`                                                       | The route is not covered by the route patterns. Carries `routePath`.                               | Add a pattern or change the route. |
| `StrybokValidationException`                                                     | The arguments were rejected by the SDK or the server. Carries the server's `message` and `issues`. | Fix the arguments.                 |
| `StrybokRateLimitedException`                                                    | Too many requests, or the daily limit of new links is reached. Carries `retryAfter` when known.    | Let the user try again later.      |
| `StrybokNetworkException` / `StrybokTimeoutException` / `StrybokServerException` | No usable answer after all retries.                                                                | Let the user try again later.      |

Do not put personal data in a route or payload: whoever receives the link can read them. The
full rules are in the [SDK contract](./sdk-contract.md#creating-links).

## 6. Treat routes as untrusted input

`routePath` and `payload` are data from the network. Match the route against routes your app
knows before navigating, and never execute payload contents. The example app only accepts
`/invite/<code>`.

## 7. Links that arrive before sign-in

If a link needs an authenticated user, remember the route and open it after login instead of
dropping it. See [`lib/app.dart`](../example/lib/app.dart) of the example app:
the link listener stores the route in the session while signed out, and the `go_router` redirect
opens it once the user signs in.

## 8. Analytics and privacy

After a link is delivered the SDK sends one best-effort `app_open` event
(`POST /v1/public/events`) containing a random event id, the link id, the platform
(`ios`/`android`) and the SDK version — no device identifiers. It never delays navigation and all
failures are ignored. Disable it with `reportAppOpens: false`.

The dashboard shows these as **App opens**, separate from browser fallbacks counted by the
server. The number is self-reported by the app and is not a count of unique people.

Only the link's host and slug are sent to `resolve`; query parameters and fragments stay on the
device.

## 9. Testing your integration

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
