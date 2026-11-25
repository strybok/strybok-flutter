## 0.3.0

- Campaign values. `ResolvedDeepLink.campaign` is a `LinkCampaign` with the nullable strings
  `source`, `medium`, `campaign`, `term` and `content` (plus `isEmpty`, `isNotEmpty` and
  `toJson()`). It is never `null` and is empty when the link has none. The values are the link's
  defaults, overridden by the `utm_*` parameters of the URL that was tapped; treat them as
  untrusted labels.
- Resolving now sends the five `utm_*` parameters of the tapped URL (`utm_source`, `utm_medium`,
  `utm_campaign`, `utm_term`, `utm_content`) when their value is 1–64 characters of
  `A-Z a-z 0-9 . _ ~ -`. Every other query parameter and the fragment are still never sent, and
  a URL without such a parameter produces exactly the request of 0.2.0.
- The `app_open` event carries the `campaign` that resolving returned; it is left out when empty.
- Deferred links (optional, off by default; nothing of it has run on a device). The package
  stays pure Dart, with no native code, no store integration and no new dependency — the app
  supplies the platform pieces:
  - New options `deferredLinks`, `deferredLinkStore` (a `DeferredLinkStore` for the two values
    `attempts` and `done`; without it the feature stays `disabled`), `installReferrerSources`
    and `androidPackageName` (Android), `iosBundleId`, `allowProbabilisticMatching`,
    `deviceFamily`, `locale` and `pasteboardMayContainLink` (iOS).
  - Android: an `InstallReferrerSource` is a function of the app that returns the store's raw
    install referrer as an `InstallReferrerAnswer` (`referrer(string)`, `unavailableForNow` or
    `unavailable`). The SDK finds its click id in it and redeems it once.
  - iOS: `redeemPastedLink(text)` takes a link the person pasted (the SDK never reads the
    clipboard) and returns a `PastedLinkResult`; `skipPastedLink()`. Probabilistic matching
    runs only with `allowProbabilisticMatching`; Apple's rules forbid it, see the guide.
  - `deferredLinkStatus`, `deferredLinkStatusChanges` (`DeferredLinkStatus`) and
    `enableDeferredLinks()`, to switch the feature on after a consent screen.
  - `ResolvedDeepLink.isDeferred` and `ResolvedDeepLink.isProbabilisticMatch`, `false` for
    every link that arrived the normal way. A deferred link is delivered through `links`, never
    by `getInitialLink()`, sends no `app_open`, and a failed check never reaches `onError`.
  - `InMemoryDeferredLinkStore` in `package:strybok/testing.dart`, for tests only.
- Not source-breaking: the new constructor parameters of `Strybok` and `ResolvedDeepLink` are
  optional.

## 0.2.0

- `createLink(routePath, {payload, title, description, imageUrl})` asks the service for a short
  link to a screen of the app (a "Share" button) and returns a `CreatedLink` (`url`, `slug`,
  `routePath`, `linkId`). It needs the new `clientKey` option: the application's publishable key
  (`pk_…`) from the dashboard, never a secret API key.
- New exceptions, thrown by `createLink` only: `StrybokUnauthorizedException`,
  `RouteNotAllowedException`, `StrybokRateLimitedException` (with `retryAfter`) and
  `StrybokValidationException` (with the server's `issues`). They extend the sealed
  `StrybokException`, so an exhaustive `switch` over it needs the new cases.
- `timeout`, `maxRetries` and `retryDelay` apply to `createLink` as well.

## 0.1.0

- Initial version: `Strybok` with `initialize`, `links`, `getInitialLink`, `resolveUri`,
  `dispose`; host allowlist; duplicate-delivery protection; timeout and retry; typed exceptions;
  best-effort `app_open` events; `FakeLinkSource` test helper.
