# Strybok example app

Flutter app with `go_router` showing the full flow: a Strybok link opens `/invite/:code`, on
cold start and while running, and waits for sign-in when the user is signed out.

| File | What it shows |
|---|---|
| `lib/main.dart` | Creating `Strybok` |
| `lib/app.dart` | One `links` subscription, route allowlist, pending link after login |
| `android/app/src/main/AndroidManifest.xml` | `autoVerify` intent filter, Flutter handler disabled |
| `ios/Runner/Runner.entitlements`, `ios/Runner/Info.plist` | Associated Domains, Flutter handler disabled |
| `test/deep_link_test.dart` | Widget tests with simulated links |

## Run the tests

```sh
flutter test
```

## Run on a device

The placeholders use `demo.links.example.com`, which is not a real domain. To see the OS open the
app you need a deployed API and your own application:

1. Replace `demo.links.example.com` in `AndroidManifest.xml` and `Runner.entitlements` with your
   managed hostname.
2. Change the Android `applicationId` and iOS bundle identifier to the ones configured in
   Strybok, and sign with the matching certificate/team.
3. Run:

   ```sh
   flutter run \
     --dart-define=STRYBOK_API=https://<api host> \
     --dart-define=STRYBOK_HOST=<managed hostname>
   ```

4. Follow [`doc/manual-test-plan.md`](../doc/manual-test-plan.md).
