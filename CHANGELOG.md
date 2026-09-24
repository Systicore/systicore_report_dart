# Changelog

## 0.1.0

First release: extracted from the `ErrorReporter` / `ReportAPI` /
`DeviceInfoService` copies in passguard_mobile and spike_mobile, moved onto
the keyed ingest API (`POST /api/v1/ingest`, contract v1).

- `SysticoreReporter` with `init`, `report` (old call shape),
  `captureException`, `setUser`, `setRoute`, `addBreadcrumb`, `flush`.
- `installHandlers()` for `FlutterError.onError` and
  `PlatformDispatcher.instance.onError`, and `runGuarded` for
  `runZonedGuarded`.
- `ReportingInterceptor` for Dio: 5xx, connection errors and timeouts.
- Persistent queue (max 50), buffering before `init`, client-side dedup and
  rate limit, 401/403 circuit breaker, `Retry-After`, exponential backoff.
- Random install id; web-safe device info without the Windows computer name.
