# systicore_report

Error reporting for Flutter apps into the Systicore reports backend. It sends
framework errors, uncaught errors, failed HTTP calls and manual reports to
`POST {REPORTS_URL}/api/v1/ingest`, identified by the component's public
ingest key (`pk_…`). It follows the shared error-reporting contract v1, §3
and §8.

- Every call is fire-and-forget. The reporter never throws into the app and
  never waits on the network on the UI path.
- With `REPORTS_ENABLED=false`, or with an empty URL or key, every call is a
  no-op.
- Reports are sent whether or not a user is signed in. When a Systicore
  access token is available, the backend marks the user as verified.
- Undelivered reports are kept in a persistent queue and sent again on the
  next start.

## Install

The package is not published to pub.dev. Add it as a git dependency pinned
to a tag:

```yaml
dependencies:
  systicore_report:
    git:
      url: https://github.com/Systicore/systicore_report_dart.git
      ref: v0.1.0
```

Requirements: Dart `>=3.5.0 <4.0.0` (Flutter 3.24+). The dependency
constraints are wide on purpose, so the package resolves next to what the
apps already pin: `dio ^5.7.0`, `device_info_plus >=11 <13`,
`package_info_plus >=8 <10` and `path_provider ^2.1.0`.

## Configuration (dart-defines)

| Define            | Meaning                                                                 | Default         |
|-------------------|-------------------------------------------------------------------------|-----------------|
| `REPORTS_ENABLED` | Master switch. Keep it off in dev and local builds.                      | `false`         |
| `REPORTS_URL`     | Reports backend base URL, e.g. `https://reports.systicore.hu`            | empty = off     |
| `REPORTS_KEY`     | The component's public ingest key (`pk_live_…` / `pk_test_…`)            | empty = off     |
| `GIT_SHA`         | Commit the build was made from → `release.commit`                         | not sent        |
| `APP_VERSION`     | Release version → `release.version`                                       | PackageInfo `version+buildNumber` |
| `ENV`             | `production` / `development` / … (informational; the key's environment wins) | `development` |

```sh
flutter build apk --release \
  --dart-define=REPORTS_ENABLED=true \
  --dart-define=REPORTS_URL=https://reports.systicore.hu \
  --dart-define=REPORTS_KEY=$REPORTS_KEY \
  --dart-define=GIT_SHA=$(git rev-parse --short HEAD) \
  --dart-define=APP_VERSION=1.4.2+17 \
  --dart-define=ENV=production
```

`ReporterConfig.fromDartDefines(...)` reads all of these. You can also
build a `ReporterConfig` yourself, for example from an existing `AppConfig`
class. Keys never go into the repository: the `pk_` key comes from the
build or CI environment.

## main.dart

```dart
import 'package:flutter/material.dart';
import 'package:systicore_report/systicore_report.dart';

void main() {
  final reporter = SysticoreReporter.instance;
  reporter.runGuarded(() async {
    // Binding, init and runApp must run in the same (guarded) zone.
    WidgetsFlutterBinding.ensureInitialized();
    await reporter.init(
      ReporterConfig.fromDartDefines(
        source: 'passguard_mobile',
        // Return the token and user id the app already holds in memory.
        accessTokenProvider: () async => api.accessToken,
        userIdProvider: () => sessions.activeUserId,
      ),
    );
    reporter.installHandlers();
    runApp(const App());
  });
}
```

- `runGuarded` wraps `runZonedGuarded` and reports errors that escape the
  zone. When reporting is disabled, the error is passed on to the
  surrounding zone instead of being swallowed.
- `installHandlers()` chains `FlutterError.onError` (the previous handler
  still runs, so debug builds keep printing errors) and
  `PlatformDispatcher.instance.onError`. The latter returns `true` only
  after the reporter (or the previous handler) has taken the error over.
  Install other crash tools first, or chain them yourself: whatever sets
  these handlers last wins.
- Errors captured before `init` completes are buffered, up to 50, and sent
  once `init` knows the release and device.
- `init` must run after `WidgetsFlutterBinding.ensureInitialized()`.
  Otherwise the platform plugins are not available yet, and the device info
  and the persistent queue quietly fall back to empty.

## Dio

```dart
final dio = Dio(BaseOptions(baseUrl: config.apiUrl))
  ..interceptors.add(AuthInterceptor(...))
  // Last, so it sees the outcome after the app's own retry/refresh logic.
  ..interceptors.add(ReportingInterceptor());
```

`ReportingInterceptor` only observes. Every response and error is passed on
unchanged.

- Status `>= 500` is reported as `error` with code `HTTP_<status>`.
- Connection errors and timeouts are reported as `warning`. They are
  visible in the admin UI but never open a GitHub issue.
- 4xx answers, cancellations and certificate errors are not reported.
- Requests to the reports host itself are ignored.
- The action is a route template (`GET /api/vault/:id`): the query string
  is dropped, and numeric, UUID, hex, token-like and e-mail path segments
  become `:id`.
- The `x-request-id` response header, if present, is sent as
  `context.requestId`.
- Every finished request is also recorded as an `http` breadcrumb.

If an app already reports some HTTP failures by hand, pick one of the two
paths per client. The client-side duplicate filter does not merge a manual
report with an interceptor report, because their codes differ.

## Manual reports

```dart
final reporter = SysticoreReporter.instance;

// Same call shape as the apps' former ErrorReporter.report.
reporter.report(
  code: 'VAULT_SYNC_FAILED',
  message: 'Vault sync failed',   // no response bodies, no personal data
  trace: stackTrace.toString(),
  action: 'VaultSync',            // an operation or a route template, never a URL with ids
  severity: ReportSeverity.error, // warning | error | critical
);

try {
  await sync();
} catch (error, stackTrace) {
  reporter.captureException(error, stackTrace, action: 'VaultSync', tags: {'feature': 'vault'});
}

reporter.setUser('42', issuer: 'https://auth.systicore.hu'); // overrides userIdProvider; null clears
reporter.setRoute('/vault/:id');                              // sent as context.route
reporter.addBreadcrumb('opened vault', category: BreadcrumbCategory.nav);
await reporter.flush();                                       // e.g. when the app goes to the background
```

## Delivery rules

| Backend answer         | Client behaviour                                                        |
|------------------------|--------------------------------------------------------------------------|
| 2xx (202)              | Done; the next queued report is sent right away.                        |
| 400, 413, other 4xx    | Dropped (permanent).                                                    |
| 401, 403               | Dropped. Nothing is sent for 5 minutes (circuit breaker).                 |
| 429                    | Kept. Nothing is sent before `Retry-After` has passed (1 s to 1 h, default 60 s). |
| 5xx, 408, network      | Kept. Retried with exponential backoff: 5 s doubling to 5 min, ±20 % jitter. |

- **Queue.** At most `maxQueue` (default 50) reports wait for delivery. The
  oldest one is dropped first. The queue is written after every change and
  replayed on `init`. Reports older than 72 hours are dropped unsent.
- **Client-side throttling.** The same error (type/code, message with
  digits collapsed, action and first stack frame) is sent at most once per
  60 s. At most 30 reports per minute are accepted.
- **Size caps (UTF-8 bytes, never splitting a character).**
  - type 200, code 100, message 8 KB, trace 16 KB, action 200;
  - route 500, requestId 100;
  - at most 10 tags (key 32, value 128);
  - at most 20 breadcrumbs (message 200).

  The trace is capped below the server's 32 KB: grouping only uses the top
  frames, and every queued report is stored on disk.

## Privacy

- `device.installId` is a random UUID created on first start. It is not
  derived from hardware or account ids, and a reinstall creates a new one.
- Device info is brand, model, OS version and API level only. The Windows
  computer name and the Linux machine id are never read.
- The Bearer token is attached only while the user who was signed in when
  the error was captured is still signed in. A queued report replayed after
  an account switch or a sign-out is sent without it, so it is never
  attributed to the wrong person. Without a user id (no `userIdProvider`
  and no `setUser`), no token is sent.
- Keep messages free of response bodies and personal data. The backend
  scrubs e-mails, tokens and similar data, but the less that leaves the
  device, the better.

## Why a file, not shared_preferences

The queue is stored as a JSON file in the app's support directory
(`path_provider` plus `dart:io`, written atomically through a temp file and
a rename). There are three reasons:

1. **No new native plugin.** All four consuming apps already depend on
   `path_provider ^2.1.5`. `shared_preferences` would add a new federated
   plugin (Android, iOS/macOS, Windows, Linux, web) to every app.
2. **Size.** A full queue of 50 reports with traces can reach a few hundred
   KB. On Android and iOS, SharedPreferences and NSUserDefaults load
   everything into memory at startup, and they are not meant for data of
   this size.
3. **Crash safety.** A crash in the middle of a write leaves the previous
   queue intact.

On the web, `dart:io` does not exist. A conditional import switches to the
browser's `localStorage`, and falls back to memory where storage is
blocked. Flutter web sends the key in the `X-Systicore-Key` header, so the
browser makes a CORS preflight, which the ingest route answers.

## Development

```sh
flutter pub get
flutter analyze   # zero issues expected
flutter test
```

Compatibility with the lowest allowed versions was checked with
`flutter pub downgrade` (dio 5.7.0, device_info_plus 11.0.0,
package_info_plus 8.0.2, path_provider 2.1.0). A temporary
`dependency_overrides: platform: ^3.1.0` was needed for that check: the
transitive `platform 3.0.0` that a full downgrade picks does not compile on
Dart 3. Normal resolution never picks it.

Releases are git tags (`v0.1.0`, …). Bump `version` in `pubspec.yaml`, add a
`CHANGELOG.md` entry, and tag.
