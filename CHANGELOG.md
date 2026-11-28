## 0.4.0

- Links without an API call, optional and off by default: the new `parameterLinks` option
  (`ParameterLinks(payloadKeys: [...])`) delivers path links such as
  `https://<host>/product/42?id=7` and Firebase long links `https://<host>/?link=…` that the
  owner switched on for the application. The keys come from `parameterLinks` of the integration
  guide (`GET /v1/apps/:appId/integration`, shown on the dashboard's setup screen). With it:
  - a route path and a long link are links of the app too, besides a single slug; an empty path
    is the root; reserved paths such as `/favicon.ico` or `/.well-known/…` never are;
  - resolving sends the path as received, the first value of each configured key (1–256
    characters without control characters, re-encoded) and the `utm_*` values; for a long link
    the deep link's scheme, host and path with its values of the keys, plus `apn` and `ibi`.
    Nothing else of the query and never the fragment;
  - the delivered link has the route and payload the server read, never the tapped path, and
    `app_open` carries the `linkId` the server returned;
  - any address of the hosts that is a valid route is resolved, so `onError` gets a
    `LinkNotFoundException` for one that is no link.
- An invalid list of keys (more than 20, a key twice, a key that is not 1–40 characters of
  `A–Z a–z 0–9 _ . -`, starts with `utm_` in any case, or is `st`, `sd`, `si` or `strybok_click`)
  makes the `Strybok` constructor throw an `ArgumentError`.
- The rules read a link exactly as the platform received it, because `Uri.parse` removes dot
  segments and rewrites escapes. New `RawLinkSource`: a `LinkSource` that also hands over strings
  (`getInitialLinkString()`, `stringLinkStream`). `AppLinksSource` implements it with the string
  API of `app_links`, and `FakeLinkSource` with the new `initialLinkString` and `emitString`.
  New `resolveUrl(String)` and `isStrybokUrl(String)` next to `resolveUri` and `isStrybokUri`. A
  `LinkSource` of your own that only has `Uri`s keeps working; with the option its links are read
  as `Uri.parse` left them.
- Unchanged without the option: the same links are accepted and every request is the one 0.3.0
  sent (a link is still read through `Uri.parse` then). Deferred links keep the single-slug rule
  with the option as well: the URL of a redeem or match answer and a pasted link must have one
  slug segment.
- Not source-breaking: the new constructor parameter is optional and `LinkSource` is unchanged.
- Covered by unit tests only, against the shared test vectors of the SDK contract (77 tapped
  URLs, 19 configurations) and a stub transport. Never run on a device or against the production
  API.

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
