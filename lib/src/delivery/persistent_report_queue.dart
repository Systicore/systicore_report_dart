import 'dart:convert';

import '../storage/reporter_storage.dart';
import '../support/reporter_log.dart';
import 'queued_report.dart';

/// Bounded FIFO of undelivered reports, mirrored to [ReporterStorage] so
/// reports survive an app kill and are replayed on the next start.
///
/// When full, the oldest report is dropped: the newest errors are the most
/// relevant ones after a long offline period.
class PersistentReportQueue {
  PersistentReportQueue({
    required ReporterStorage storage,
    required this.capacity,
  }) : _storage = storage;

  static const String storageKey = 'queue.json';
  static const int _formatVersion = 1;

  final ReporterStorage _storage;
  final int capacity;
  final List<QueuedReport> _reports = [];

  Future<void> _pendingWrite = Future<void>.value();
  bool _writeScheduled = false;

  int get length => _reports.length;

  bool get isEmpty => _reports.isEmpty;

  QueuedReport? get first => _reports.isEmpty ? null : _reports.first;

  List<QueuedReport> get reports => List<QueuedReport>.unmodifiable(_reports);

  /// Completes once every change made so far has been written.
  Future<void> get persisted => _pendingWrite;

  /// Restores the reports a previous run left behind, ahead of anything
  /// queued in this run. Unreadable data is discarded.
  Future<void> load() async {
    try {
      final stored = await _storage.read(storageKey);
      if (stored == null || stored.isEmpty) return;
      _reports.insertAll(0, _decode(stored));
      if (_dropOverflow() > 0) _schedulePersist();
    } catch (error, stackTrace) {
      ReporterLog.debug(
        'Could not restore the report queue',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void add(QueuedReport report) {
    _reports.add(report);
    final dropped = _dropOverflow();
    if (dropped > 0) {
      ReporterLog.debug('Report queue full, dropped $dropped oldest report(s)');
    }
    _schedulePersist();
  }

  void remove(String id) {
    removeWhere((report) => report.id == id);
  }

  /// Removes matching reports and returns how many were removed.
  int removeWhere(bool Function(QueuedReport report) test) {
    final lengthBefore = _reports.length;
    _reports.removeWhere(test);
    final removed = lengthBefore - _reports.length;
    if (removed > 0) _schedulePersist();
    return removed;
  }

  int _dropOverflow() {
    final overflow = _reports.length - capacity;
    if (overflow <= 0) return 0;
    _reports.removeRange(0, overflow);
    return overflow;
  }

  // Coalesces bursts of changes into one write, and serialises writes so an
  // older snapshot can never land after a newer one.
  void _schedulePersist() {
    if (_writeScheduled) return;
    _writeScheduled = true;
    _pendingWrite = _pendingWrite.then((_) => _writeSnapshot());
  }

  Future<void> _writeSnapshot() async {
    _writeScheduled = false;
    try {
      await _storage.write(storageKey, _encode());
    } catch (error, stackTrace) {
      ReporterLog.debug(
        'Could not persist the report queue',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  String _encode() => jsonEncode({
        'version': _formatVersion,
        'reports': [for (final report in _reports) report.toJson()],
      });

  static List<QueuedReport> _decode(String stored) {
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, Object?>) return const [];
    final entries = decoded['reports'];
    if (entries is! List<Object?>) return const [];
    final restored = <QueuedReport>[];
    for (final entry in entries) {
      if (entry is! Map<String, Object?>) continue;
      try {
        restored.add(QueuedReport.fromJson(entry));
      } catch (_) {
        // A malformed entry must not cost the rest of the queue.
      }
    }
    return restored;
  }
}
