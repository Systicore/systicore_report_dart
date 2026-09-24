import 'dart:js_interop';

import 'memory_reporter_storage.dart';
import 'reporter_storage.dart';

@JS('localStorage')
external _WebStorage? get _localStorage;

extension type _WebStorage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
}

/// Web: the browser's localStorage. Falls back to memory where storage is
/// blocked (private windows, sandboxed iframes, quota exceeded).
ReporterStorage createPlatformStorage() => LocalStorageReporterStorage();

class LocalStorageReporterStorage implements ReporterStorage {
  static const String _prefix = 'systicore_report.';

  final MemoryReporterStorage _fallback = MemoryReporterStorage();

  @override
  Future<String?> read(String key) async {
    try {
      final storage = _localStorage;
      if (storage == null) return _fallback.read(key);
      return storage.getItem('$_prefix$key');
    } catch (_) {
      return _fallback.read(key);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      final storage = _localStorage;
      if (storage == null) return _fallback.write(key, value);
      storage.setItem('$_prefix$key', value);
    } catch (_) {
      await _fallback.write(key, value);
    }
  }
}
