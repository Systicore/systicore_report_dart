import 'reporter_storage.dart';

/// Process-lifetime storage: used where no persistent storage exists and in
/// tests.
class MemoryReporterStorage implements ReporterStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}
