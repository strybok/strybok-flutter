# Flutter integration

The `strybok` package receives verified HTTPS links through the
[`app_links`](https://pub.dev/packages/app_links) plugin, asks the Strybok API which in-app
route a link stands for, and hands your app each link exactly once.

> **Status:** early release (0.x), published on [pub.dev](https://pub.dev/packages/strybok). This
> guide describes 0.4.0, which may be newer than the version on pub.dev.
> Covered by unit and widget tests; not yet verified on physical devices
> (see the [manual test plan](./manual-test-plan.md)).
>
> Links without an API call (path links and Firebase long links) are **optional and off by
> default** (the `parameterLinks` option, new in 0.4.0) and unit-tested only. See
> [Links without an API call](#links-without-an-api-call-optional).
>
> Deferred links (a link tapped before the app is installed, restored after installation) are
> **optional and off by default**, and the package has no native code for them: on Android your
> app supplies the store's install referrer, on iOS the only ways are a link the person pastes
> or opt-in probabilistic matching. None of it has run on a device. See
> [Deferred links](#deferred-links-optional).

## 1. Prerequisites

1. Create an application in Strybok with your iOS and Android identifiers.
2. Read its setup data: `GET /v1/apps/:appId/integration` returns the managed hostname
   (for example `my-app-x7k2p9.links.example.com`) and ready-to-copy snippets.
   If the application has an active [custom domain](./ios.md#custom-domain-optional), the same answer lists it in `allowedHosts`: declare it in the entitlement and the intent filter next to the managed hostname and pass both to `allowedHosts`.
3. Complete the native setup: [Android](./android.md) and [iOS](./ios.md). Without it the OS
   never delivers links to the app, and the SDK has nothing to receive.

## 2. Add the package

```sh
flutter pub add strybok
```

Or add it to `pubspec.yaml` yourself:

```yaml
dependencies:
  strybok: ^0.4.0
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

### Campaign values

Every `ResolvedDeepLink` has `campaign`: a `LinkCampaign` with the nullable strings `source`,
`medium`, `campaign`, `term` and `content`. It is never `null` itself; a value that is not set is
`null`, and `campaign.isEmpty` is true when there are none. `campaign.toJson()` gives the values
that are set as a `Map<String, String>`.

```dart
strybok.links.listen((link) {
  analytics.logEvent('link_opened', {
    'source': ?link.campaign.source, // 'instagram', or left out
    'campaign': ?link.campaign.campaign,
  });
  router.go(link.routePath);
});
```

- **Where the values come from.** A link can have default values, set per link in the dashboard
  ("Campaign (optional)" in the link form). The `utm_source`, `utm_medium`, `utm_campaign`,
  `utm_term` and `utm_content` parameters of the URL that was tapped override them one by one:
  if the link's default source is `newsletter`,
  `https://my-app-x7k2p9.links.example.com/invite777?utm_source=instagram` arrives with the source
  `instagram` and the link's other defaults. A parameter can replace a default but
  not clear it.
- **Which values are accepted.** 1–64 characters of letters, digits, `.`, `_`, `~` and `-`.
  Anything else (a space, `+`, letters outside ASCII) is dropped as if the parameter were absent,
  without an error: write `spring_sale`, not `spring sale`.
- **They are untrusted labels.** Whoever shares a link can put any `utm_*` values on it. Use them
  for attribution, never to grant anything or to decide what the user may see.
- **What is sent.** Of the tapped URL's query only these five parameters are sent when resolving,
  and the resolved values are reported with the `app_open` event (section "Analytics and
  privacy"); every other parameter and the fragment stay on the device. In the dashboard, a link's analytics has a "Campaigns" breakdown of opens
  by source, medium and campaign.

### API

| Member              | Purpose                                                                                                |
| ------------------- | ------------------------------------------------------------------------------------------------------ |
| `initialize()`      | Start listening; completes after the launch link was handled. Idempotent.                              |
| `links`             | Broadcast stream of `ResolvedDeepLink` (`uri`, `linkId`, `appId`, `routePath`, `payload`, `campaign`). |
| `getInitialLink()`  | The launch link, if not delivered through `links` yet.                                                 |
| `resolveUri(uri)`   | Resolve a URI explicitly (QR scanner, tests). Does not emit on `links` or report an app open.          |
| `resolveUrl(url)`   | The same for a URL string exactly as received; prefer it with `parameterLinks`.                        |
| `isStrybokUri(uri)` | Whether a URI is one of this app's links. `isStrybokUrl(url)` takes a string.                          |
| `createLink(route)` | Create a link to share (section 5). Needs `clientKey`.                                                 |
| `dispose()`         | Stop listening and release resources.                                                                  |

Every `ResolvedDeepLink` also has `isDeferred` and `isProbabilisticMatch`, both `false` unless
you use [deferred links](#deferred-links-optional), which add `deferredLinkStatus`,
`deferredLinkStatusChanges`, `enableDeferredLinks()`, `redeemPastedLink(text)` and
`skipPastedLink()`.

Options: `timeout` (5 s per attempt), `maxRetries` (2; only timeouts, network errors and 5xx are
retried — resolving is an idempotent GET), `retryDelay`, `dedupeWindow`, `reportAppOpens`,
`onError`, `clientKey` (only for `createLink`), `parameterLinks` (see
[Links without an API call](#links-without-an-api-call-optional)), plus `linkSource` /
`httpClient` for tests. The deferred-link options are listed in
[their section](#deferred-links-optional).

### Errors

`resolveUri` throws, and `onError` receives, a `StrybokException`:

| Type                                                  | Meaning                                                                                                                                                                                                            |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `UnsupportedLinkException`                            | Not `https`, host not in `allowedHosts`, or not a single-slug path (with `parameterLinks`: neither a route path nor a long link). Thrown before any network call. Ignored silently for links arriving from the OS. |
| `LinkNotFoundException`                               | Unknown, disabled or expired link.                                                                                                                                                                                 |
| `StrybokTimeoutException` / `StrybokNetworkException` | No answer after all retries (e.g. offline). The app keeps working; the link is simply not opened.                                                                                                                  |
| `StrybokServerException`                              | Unexpected status or malformed response.                                                                                                                                                                           |

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

`routePath`, `payload` and `campaign` are data from the network. Match the route against routes
your app knows before navigating, never execute payload contents, and treat campaign values as
labels only. The example app only accepts `/invite/<code>`.

## 7. Links that arrive before sign-in

If a link needs an authenticated user, remember the route and open it after login instead of
dropping it. See [`lib/app.dart`](../example/lib/app.dart) of the example app:
the link listener stores the route in the session while signed out, and the `go_router` redirect
opens it once the user signs in.

## 8. Analytics and privacy

After a link is delivered the SDK sends one best-effort `app_open` event
(`POST /v1/public/events`) containing a random event id, the link id, the platform
(`ios`/`android`), the SDK version and the link's campaign values when it has any — no device
identifiers. It never delays navigation and all
failures are ignored. Disable it with `reportAppOpens: false`.

The dashboard shows these as **App opens**, separate from browser fallbacks counted by the
server. The number is self-reported by the app and is not a count of unique people.

Only the link's host and slug are sent to `resolve`, plus the five `utm_*` campaign parameters of
the tapped URL when their value passes the character rule
([Campaign values](#campaign-values)). Every other query parameter and the fragment stay on the
device. With `parameterLinks`, `resolve` also gets the path of a path link and the values of the
payload keys you configured, or for a Firebase long link the deep link's scheme, host and path,
its values of those keys and the `apn` and `ibi` parameters
([Links without an API call](#links-without-an-api-call-optional)). Do not configure keys that
carry personal data.

With `deferredLinks` on, the SDK also sends what [Deferred links](#deferred-links-optional)
describes: on Android the code found in the referrer your app passed in, with the package name;
on iOS the code of a pasted link with the bundle id — and, only with
`allowProbabilisticMatching`, the bundle id, device family and language, which the server
combines with the IP address of the connection.

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

`emit` takes a `Uri`, which `Uri.parse` has already rewritten. To hand over a URL exactly as
written — to test `parameterLinks` with `https://my-app.links.example.com/a/../b`, say — use
`source.emitString(url)` and `FakeLinkSource(initialLinkString: url)`.

The example app's [`test/deep_link_test.dart`](../example/test/deep_link_test.dart)
shows complete widget tests.

## Links without an API call (optional)

The owner of the application can let addresses of its hosts open a route of the app without
creating a link first (dashboard: **Setup → Links without an API call**, off by default):
**path links** such as `https://my-app-x7k2p9.links.example.com/product/42?id=7`, and **Firebase
long links** `https://my-app-x7k2p9.links.example.com/?link=https://example.com/product/42&apn=…`.
The SDK delivers them only with the `parameterLinks` option, new in 0.4.0. Without it, and in
earlier versions, a path of several segments and a long link are dropped without a request, and
a one-segment path is delivered without its payload.

Copy the keys from `parameterLinks` of the integration guide (`GET /v1/apps/:appId/integration`,
shown on the dashboard's setup screen). It is `null` while both kinds are off; then leave the
option out.

```dart
final strybok = Strybok(
  apiBaseUrl: Uri.parse('https://api.example.com'),
  allowedHosts: {'my-app-x7k2p9.links.example.com'},
  parameterLinks: const ParameterLinks(payloadKeys: ['id', 'lang']),
);

strybok.links.listen((link) {
  // Tapped: https://my-app-x7k2p9.links.example.com/product/42?id=7&lang=uk
  // link.routePath == '/product/42' and link.payload == {'id': '7', 'lang': 'uk'},
  // as the server read them.
  router.go(link.routePath);
});
```

- **What arrives.** A link like any other, on `links` or from `getInitialLink()`, with the route
  and payload the server read — never the tapped path. Treat them as untrusted, as for every
  link. The `app_open` event carries the `linkId` the server returned.
- **What is sent.** The path exactly as received, the first value of each payload key (kept when
  it is 1–256 characters without control characters) and the `utm_*` values; for a long link the
  deep link's scheme, host and path with its own values of the payload keys, plus `apn` and
  `ibi`. Nothing else of the query — not `afl`, `ifl`, `ofl`, `st`, `sd`, `si` or `isi` — and
  never the fragment.
- **Which addresses count.** Any address of `allowedHosts` whose path is a valid route (no `//`,
  no `.` or `..` segment, not `/favicon.ico`, `/robots.txt` or anything under `/.well-known/`) is
  resolved. Whether a route is allowed is the server's decision, so `onError` gets a
  `LinkNotFoundException` for an address that is no link, a typo for example.
- **The keys are compiled in.** Installed builds keep sending the keys they know, and the server
  ignores keys it no longer allows: a key the owner adds reaches users with your next release.
  An invalid list — more than 20 keys, a key twice, a key that is not 1–40 characters of
  `A–Z a–z 0–9 _ . -`, starts with `utm_` or is `st`, `sd`, `si` or `strybok_click` — makes the
  constructor throw an `ArgumentError`.
- **Links exactly as received.** The rules read a link as the platform received it:
  `AppLinksSource`, the default, hands over the platform's strings. A `Uri` has already been
  rewritten by `Uri.parse`, which removes `.` and `..` segments and changes escapes, so
  `resolveUri(uri)` and a `LinkSource` of your own that only has `Uri`s read the link as
  `Uri.parse` left it. Implement `RawLinkSource` (`getInitialLinkString()`, `stringLinkStream`)
  in such a source, and pass URLs from elsewhere to `resolveUrl(url)`.
- **Deferred links do not change.** They exist only for links created in advance, so a restored
  link, and a pasted one on iOS, still has a single slug.

The exact rules are in the
[SDK contract](./sdk-contract.md#links-without-an-api-call). This is covered by unit tests
against the shared test vectors of the contract only; it has not run on a device or against the
production API.

## Deferred links (optional)

A deferred link is one that was tapped **before** the app was installed and is restored on the
first launch. It is off by default, the two platforms have nothing in common, and **nothing in
this section has run on a device**. Read [Android](./android.md#links-tapped-before-the-app-is-installed-deferred-links)
and [iOS](./ios.md#links-tapped-before-the-app-is-installed) first: they explain the dashboard
settings and what each option costs your users. The exact behaviour is in the SDK contract
([Android](./sdk-contract.md#deferred-links-optional-android),
[iOS](./sdk-contract.md#deferred-links-on-ios-optional)).

**What this package does and does not do.** `strybok` is pure Dart. It ships **no native code
and no store integration**: it does not read the install referrer and it never reads the
clipboard. Your app supplies those pieces, and the package runs the rest — the once-per-install
state, the request, and delivery through `links`:

| Your app supplies                                 | Platform | Why                                                                                      |
| ------------------------------------------------- | -------- | ---------------------------------------------------------------------------------------- |
| `deferredLinkStore`                               | both     | Where the two values `attempts` and `done` are kept. Without it the feature stays off.   |
| `androidPackageName`                              | Android  | The application ID; the server checks it. Without it the feature stays off on Android.   |
| `installReferrerSources`                          | Android  | Functions that ask a store for its install referrer.                                     |
| `iosBundleId`                                     | iOS      | The bundle identifier; the server checks it. Without it the feature stays off on iOS.    |
| The pasted text, through `redeemPastedLink(text)` | iOS      | The link the person copied and pasted.                                                   |
| `deviceFamily`, `locale`                          | iOS      | Only for probabilistic matching (`allowProbabilisticMatching`), which we advise against. |

### The store

`shared_preferences` is not a dependency of `strybok`, so the adapter is yours (about ten lines).
The SDK writes only the keys `strybok.deferred.attempts` and `strybok.deferred.done`, and never
the referrer, the pasted text or the code in them:

```dart
// Your app's code. Needs `flutter pub add shared_preferences`.
class PrefsDeferredLinkStore implements DeferredLinkStore {
  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String key, String value) async {
    final saved = await (await SharedPreferences.getInstance()).setString(key, value);
    if (!saved) throw StateError('not saved');
  }
}
```

The store must survive a restart and be removed with the app's data. Do not pass one that keeps
the values in memory (`InMemoryDeferredLinkStore` from `package:strybok/testing.dart` is for
tests): the check would run again on every launch.

### Android: the install referrer

```dart
final strybok = Strybok(
  apiBaseUrl: Uri.parse('https://api.example.com'),
  allowedHosts: {'my-app-x7k2p9.links.example.com'},
  deferredLinks: true, // or call strybok.enableDeferredLinks() after your consent screen
  deferredLinkStore: PrefsDeferredLinkStore(),
  androidPackageName: 'com.example.app', // or PackageInfo.packageName from package_info_plus
  installReferrerSources: [playInstallReferrer],
);
strybok.links.listen((link) => router.go(link.routePath)); // link.isDeferred tells them apart
await strybok.initialize(); // never waits for the check
```

A source is a function that returns exactly one of `InstallReferrerAnswer.referrer(string)` (the
raw referrer, exactly as the store returned it, even when empty),
`InstallReferrerAnswer.unavailableForNow` (the store could not be asked; a later launch tries
again) or `InstallReferrerAnswer.unavailable` (asking again is pointless). The SDK waits at most
10 seconds for each and treats a thrown error as "unavailable for now".

There is no first-party Flutter plugin for the Play Install Referrer library and we do not
recommend a particular community plugin; any plugin that returns the raw referrer string fits.
Without one, this is the glue — **your app's code, written from Google's documentation and not
run on a device**. Add `implementation("com.android.installreferrer:installreferrer:2.2")` to
`android/app/build.gradle(.kts)`, then:

```kotlin
// android/app/src/main/kotlin/…/MainActivity.kt — your app's code, not part of the SDK.
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerClient.InstallReferrerResponse
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app/install_referrer")
      .setMethodCallHandler { call, result ->
        if (call.method != "get") return@setMethodCallHandler result.notImplemented()
        val client = InstallReferrerClient.newBuilder(this).build()
        var answered = false
        fun answer(value: Any) { // "later", "never" or mapOf("referrer" to …)
          if (answered) return
          answered = true
          runCatching { client.endConnection() } // always release the connection
          result.success(value)
        }
        runCatching {
          client.startConnection(object : InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(code: Int) {
              when (code) {
                InstallReferrerResponse.OK -> answer(
                  runCatching { mapOf("referrer" to client.installReferrer.installReferrer) }
                    .getOrDefault("later"), // a remote exception
                )
                InstallReferrerResponse.SERVICE_UNAVAILABLE,
                InstallReferrerResponse.SERVICE_DISCONNECTED -> answer("later")
                else -> answer("never") // FEATURE_NOT_SUPPORTED, DEVELOPER_ERROR
              }
            }

            override fun onInstallReferrerServiceDisconnected() = answer("later")
          })
        }.onFailure { answer("later") }
      }
  }
}
```

```dart
// Your app's code.
const _referrerChannel = MethodChannel('app/install_referrer');

Future<InstallReferrerAnswer> playInstallReferrer() async {
  try {
    final answer = await _referrerChannel.invokeMethod<Object?>('get');
    if (answer case {'referrer': final String referrer}) {
      return InstallReferrerAnswer.referrer(referrer);
    }
    return answer == 'never'
        ? InstallReferrerAnswer.unavailable
        : InstallReferrerAnswer.unavailableForNow;
  } on MissingPluginException {
    return InstallReferrerAnswer.unavailable; // the native side is not in this build
  } catch (_) {
    return InstallReferrerAnswer.unavailableForNow;
  }
}
```

Pass the referrer string through unchanged and do not log it. The SDK looks only for its own
`strybok_click` value in it and sends that code, the package name and the SDK version — nothing
else of the referrer, and nothing about the device.

**Huawei AppGallery and Samsung Galaxy Store.** You can add sources for them in the same list
(a source whose store did not install the app returns no code and the next one is asked), but
you write them yourself, and those two flows are **unverified even in the native Android SDK**:
how the stores treat our value was never tried. The store URLs, the libraries and the mapping of
their answers are in the
[contract](./sdk-contract.md#sources-shipped-with-the-android-sdk).

Whether your users must consent before the app reads the referrer is your decision (Huawei
requires consent for its referrer). Leave `deferredLinks` off and call
`strybok.enableDeferredLinks()` after your consent screen; it runs the check once.

### iOS, option A: the person pastes the link

Needs **Copy and paste the link** switched on for the application
([iOS guide](./ios.md#option-copy-and-paste-the-link-iosdeferredclipboard)). The page before the
App Store offers to copy the link; in your app the person pastes it, and you hand the text over:

```dart
final strybok = Strybok(
  apiBaseUrl: Uri.parse('https://api.example.com'),
  allowedHosts: {'my-app-x7k2p9.links.example.com'},
  deferredLinks: true,
  deferredLinkStore: PrefsDeferredLinkStore(),
  iosBundleId: 'com.example.app',
);

// When the person pasted something in your onboarding:
final result = await strybok.redeemPastedLink(pastedText);
// delivered (the link arrives on `links`, isDeferred: true), notOurs, notFound,
// alreadyHandled, disabled, or failed (after a network failure they can paste again).
```

**The paste step is yours, and Flutter has no widget for Apple's paste button.** The SDK only
takes a string. Your choices, honestly:

- Apple's `UIPasteControl` (iOS 16 or later) shows no permission alert, because tapping it is
  the person's consent. Flutter does not wrap it: you need a platform view or a small native
  screen of your own that hosts the control and sends the pasted string to Dart.
- A text field in which the person uses the system **Paste** menu, and a "Continue" button that
  passes the field's text. No native code and no alert, but more effort for the person.
- A button of your own that calls `Clipboard.getData`. Since iOS 16 the system then asks "Allow
  Paste?" every time, which many people decline.

Do not read the clipboard at launch or without a tap. Say on the screen what the button does,
and describe the step in your App Review notes. Text that is not a copied link of your app is
dropped without a request (`notOurs`) — not stored, not logged, not sent. Of a link of yours
only the code in it is sent.

What this option costs: **every** iOS visitor without the app gets an extra page and an extra
tap before the App Store; it works only if the person taps copy there **and** pastes in your
app; it replaces what was on their clipboard; the code works once, for 24 hours.

### iOS, option B (not recommended): probabilistic matching

Off unless you set `allowProbabilisticMatching: true` **and** the owner enabled matching for the
application **and** for the link ([iOS guide](./ios.md#option-not-recommended-probabilistic-matching-iosdeferredmatching)).
On the first launch the SDK then asks the server whether exactly one recent tap came from the
same network address, device family and language. Read the costs before you switch it on:

- **Apple forbids it.** This is fingerprinting in the terms of the App Store Review Guidelines
  and the Apple Developer Program License Agreement, with or without the user's consent. The
  App Review and legal risk is the app owner's, not Strybok's.
- **A match is a guess and can be another person's link** on a shared network (Wi-Fi, office,
  carrier NAT). Check `link.isProbabilisticMatch`: such a link must never by itself sign anyone
  in, accept an invitation, apply a personal discount or show personal content.
- **It often cannot work:** not with iCloud Private Relay or a VPN, not after a change of
  network, not after the owner's time window.
- **It changes your privacy obligations.** The server processes the IP address. Your privacy
  policy and App Store privacy labels must cover it, and you may need consent.
- It applies only to links the owner allowed one by one, and **nobody knows how accurate it is**.

```dart
final strybok = Strybok(
  // … as for option A, plus:
  allowProbabilisticMatching: true,
  // Your app's code: 'iphone', 'ipad' or 'ipod'. For example from device_info_plus:
  deviceFamily: () async {
    final model = (await DeviceInfoPlugin().iosInfo).model.toLowerCase();
    return model.startsWith('ipad') ? 'ipad' : model.startsWith('ipod') ? 'ipod' : 'iphone';
  },
  // The first preferred language as a tag such as en-GB.
  locale: () => PlatformDispatcher.instance.locale.toLanguageTag(),
);
```

Those two values, the bundle id and the SDK version are all that is sent; do not add anything
else to them. If a callback is missing, throws or returns something else, nothing is sent and
the check ends (`unavailable`).

If both iOS options are on, pass `pasteboardMayContainLink` only if you have native code that
answers it with `UIPasteboard.general.detectPatterns(for: [.probableWebURL])` (which reads no
content). When it answers `true` the SDK waits (`awaitingPaste`) until you call
`redeemPastedLink` or, when the person moves on without pasting, `skipPastedLink()`. Without
that callback matching starts right after `initialize()`.

### What to expect

- A restored link arrives on `links` like any other, with `isDeferred: true`, typically a
  moment after the first screen is shown. `getInitialLink()` never returns it, no `app_open` is
  reported for it, and nothing about the check ever goes to `onError`.
- If a normal link opens the app in the same launch, that link wins and the deferred one is
  dropped. A pasted link is the exception: it is always delivered.
- It happens at most once per installation: the SDK tries on up to three launches, then stops.
- `strybok.deferredLinkStatus` (and the stream `deferredLinkStatusChanges`) says where the
  check stands, for you and for QA:

| Status           | Meaning                                                                                                              |
| ---------------- | -------------------------------------------------------------------------------------------------------------------- |
| `disabled`       | `deferredLinks` is off, or the store or the platform's identifier is missing, or this is neither Android nor iOS.    |
| `pending`        | Not started yet, or this launch could not finish (store or network not reachable); a later launch tries again.       |
| `checking`       | Running now.                                                                                                         |
| `notFirstLaunch` | Finished in an earlier launch.                                                                                       |
| `unavailable`    | Android: no source, or none can ever answer. iOS: matching is off (only a paste can restore a link) or not possible. |
| `noReferrer`     | The store's referrer has no code of ours — the usual result of an ordinary install.                                  |
| `notFound`       | The server refused the code: unknown, older than 24 hours, already used, or another app's.                           |
| `superseded`     | A normal link arrived first.                                                                                         |
| `delivered`      | The link was handed to `links`.                                                                                      |
| `failed`         | Three launches could not finish the check, or the server's answer was unusable.                                      |
| `awaitingPaste`  | iOS matching only: waiting for `redeemPastedLink` or `skipPastedLink()`.                                             |

Without native access the SDK cannot tell an update from a fresh install, so a person who
updates to the first version of your app with this feature is also checked once; the server
refuses codes older than 24 hours.

## Troubleshooting

| Symptom                                                     | Check                                                                                                                                 |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Link opens the browser/store instead of the app             | Native association is not verified: see the Android and iOS guides. The SDK is not involved yet at this point.                        |
| App opens but nothing happens                               | Host missing from `allowedHosts`; `onError` output; API reachable from the device?                                                    |
| Screen opens twice                                          | Flutter's built-in handler is still enabled (step 3), or you navigate from both `getInitialLink()` and your own `app_links` listener. |
| Works on tap in Notes/Messages, not from Instagram/Telegram | In-app browsers often do not hand links to apps. Users get the fallback page with a manual button.                                    |
