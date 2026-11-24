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
