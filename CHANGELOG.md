# Changelog

## 0.2.0

Fixes and additive options from the first round of app integrations
(conduo, passguard, reverba and spike mobile). Apps on 0.1.0 compile
unchanged.

Fixes:

- An error object is reported once. A `DioException` that
  `ReportingInterceptor` had reported was reported again, as `UNHANDLED`
  at `error` severity, when the app let it escape to the zone or
  `PlatformDispatcher` handler; the same held for an error passed to
  `captureException` and then rethrown. The reporter now remembers the
  errors it reported for a minute (in an `Expando`, so nothing is kept
  alive), and the global handlers skip them. An explicit
  `captureException` call is still judged on its own, as in 0.1.0, so the
  same error object captured under another code or action is sent.
- A request retried with `dio.fetch` inside an interceptor (a 401 refresh
  retry) was observed by both chains: its breadcrumb was recorded twice,
  and only the duplicate filter kept a second report out.
  `ReportingInterceptor` now observes each `DioException` and `Response`
  once, across `Dio` instances and for `copyWith` copies that keep the
  response.
- Connections that break after they were opened are reported. dio's IO
  adapter reports a later `SocketException`, an `HttpException`
  ("Connection closed before full header was received" before dio 5.10)
  and a failed TLS handshake as `DioExceptionType.unknown`, which the
  interceptor dropped. They are now `HTTP_CONNECTION_ERROR` warnings, like
  `connectionError`. Other `unknown` errors stay unreported, including a
  `RedirectException` (a redirect loop or too many redirects), which is
  an `HttpException` but not a broken connection.

Added:

- `ReporterConfig.userIssuer` (also on `fromDartDefines`): sent as
  `user.issuer` with the ids from `userIdProvider` and with `setUser`
  calls that name no issuer.
- `SysticoreReporter.markReported(error)` and `isReported(error)`, for
  errors an app reports with `report` and then rethrows.
- `runGuarded(appMain, zoneSpecification:, zoneValues:)`, passed on to
  `runZonedGuarded`.
- `package:systicore_report/testing.dart`: `ReporterDependencies`, the
  transport, storage and device seams, `RecordingIngestTransport` and
  `FixedDeviceContextLoader`, for app tests without `src/` imports.

## 0.1.0

First release: extracted from the `ErrorReporter` / `ReportAPI` /
`DeviceInfoService` copies in passguard_mobile and spike_mobile, moved onto
the keyed ingest API (`POST /api/v1/ingest`, contract v1.1).

- `SysticoreReporter` with `init`, `report` (old call shape),
  `captureException`, `setUser`, `setRoute`, `addBreadcrumb`, `flush`.
- `installHandlers()` for `FlutterError.onError` and
  `PlatformDispatcher.instance.onError`, and `runGuarded` for
  `runZonedGuarded`.
- `ReportingInterceptor` for Dio: 5xx, connection errors and timeouts.
- Persistent queue (max 50), buffering before `init`, client-side dedup and
  rate limit, 401/403 circuit breaker, `Retry-After`, exponential backoff.
  New reports are written right away; removals after delivery are batched
  (at most every 2 s and when a delivery run ends), and each report is
  JSON-encoded only once.
- `error.type` is left out in minified (web release) and obfuscated builds,
  whose class names change with every build.
- Random install id; web-safe device info without the Windows computer name.
- Only a public `scpk_` ingest key is accepted. A secret `scsk_` key, or
  any other key, leaves reporting off like an empty key.
