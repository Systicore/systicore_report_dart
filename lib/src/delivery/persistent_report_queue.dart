import 'dart:convert';

import '../storage/reporter_storage.dart';
import '../support/clock.dart';
import '../support/reporter_log.dart';
import 'queued_report.dart';

/// Bounded FIFO of undelivered reports, mirrored to [ReporterStorage] so
/// reports survive an app kill and are replayed on the next start.
///
/// When full, the oldest report is dropped: the newest errors are the most
/// relevant ones after a long offline period.
///
/// Writing stays cheap on the UI isolate: each report is encoded to JSON
/// once, when it is added, and a write only joins those strings. A new
/// report is written right away, so a crash cannot lose it. Removals are
/// written at most once per [removalWriteInterval] and on
/// [persistPending]: losing one only means the report is sent again on the
/// next start, while writing the whole queue after every delivery would
/// rewrite up to a few hundred KB per report while a backlog drains.
class PersistentReportQueue {
  PersistentReportQueue({
    required ReporterStorage storage,
    required this.capacity,
    Clock clock = systemClock,
    this.removalWriteInterval = const Duration(seconds: 2),
  })  : _storage = storage,
        _clock = clock;

  static const String storageKey = 'queue.json';
  static const int _formatVersion = 1;

  final ReporterStorage _storage;
  final Clock _clock;
  final int capacity;
  final Duration removalWriteInterval;
  final List<_QueueEntry> _entries = [];

  Future<void> _pendingWrite = Future<void>.value();
  bool _writeScheduled = false;
  bool _hasUnwrittenRemovals = false;
  DateTime? _lastWriteScheduledAt;

  int get length => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  QueuedReport? get first => _entries.isEmpty ? null : _entries.first.report;

  List<QueuedReport> get reports => List<QueuedReport>.unmodifiable(
        [for (final entry in _entries) entry.report],
      );

  /// Writes the changes not written yet and completes once every change
  /// made so far is stored.
  Future<void> persistPending() {
    if (_hasUnwrittenRemovals) _schedulePersist();
    return _pendingWrite;
  }

  /// Restores the reports a previous run left behind, ahead of anything
  /// queued in this run. Unreadable data is discarded.
  Future<void> load() async {
    try {
      final stored = await _storage.read(storageKey);
      if (stored == null || stored.isEmpty) return;
      _entries.insertAll(0, _decode(stored));
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
    final _QueueEntry entry;
    try {
      entry = _QueueEntry(report);
    } catch (error, stackTrace) {
      // A payload that cannot be encoded could never be sent either.
      ReporterLog.debug(
        'Report is not JSON-encodable, dropped',
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }
    _entries.add(entry);
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
    final lengthBefore = _entries.length;
    _entries.removeWhere((entry) => test(entry.report));
    final removed = lengthBefore - _entries.length;
    if (removed > 0) _persistRemoval();
    return removed;
  }

  int _dropOverflow() {
    final overflow = _entries.length - capacity;
    if (overflow <= 0) return 0;
    _entries.removeRange(0, overflow);
    return overflow;
  }

  void _persistRemoval() {
    if (_writeScheduled) return;
    final lastWriteScheduledAt = _lastWriteScheduledAt;
    final writtenRecently = lastWriteScheduledAt != null &&
        _clock().difference(lastWriteScheduledAt) < removalWriteInterval;
    if (writtenRecently) {
      _hasUnwrittenRemovals = true;
    } else {
      _schedulePersist();
    }
  }

  // Coalesces bursts of changes into one write, and serialises writes so an
  // older snapshot can never land after a newer one. A scheduled write
  // takes its snapshot when it starts, so it covers every change up to then.
  void _schedulePersist() {
    _hasUnwrittenRemovals = false;
    _lastWriteScheduledAt = _clock();
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

  // Same document as jsonEncode({'version': …, 'reports': […]}), built from
  // the entries' cached JSON.
  String _encode() {
    final document = StringBuffer('{"version":$_formatVersion,"reports":[')
      ..writeAll([for (final entry in _entries) entry.json], ',')
      ..write(']}');
    return document.toString();
  }

  static List<_QueueEntry> _decode(String stored) {
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, Object?>) return const [];
    final entries = decoded['reports'];
    if (entries is! List<Object?>) return const [];
    final restored = <_QueueEntry>[];
    for (final entry in entries) {
      if (entry is! Map<String, Object?>) continue;
      try {
        restored.add(_QueueEntry(QueuedReport.fromJson(entry)));
      } catch (_) {
        // A malformed entry must not cost the rest of the queue.
      }
    }
    return restored;
  }
}

/// A queued report with its JSON encoded once.
class _QueueEntry {
  _QueueEntry(this.report) : json = jsonEncode(report.toJson());

  final QueuedReport report;
  final String json;
}
