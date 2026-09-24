import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../support/utf8_truncation.dart';

/// Kind of event a breadcrumb records.
enum BreadcrumbCategory { http, nav, ui, log }

/// One step the app took before an error, sent in `context.breadcrumbs`.
@immutable
class Breadcrumb {
  Breadcrumb({
    required this.timestamp,
    required this.category,
    required String message,
  }) : message = truncateUtf8(message, maxMessageBytes);

  static const int maxMessageBytes = 200;

  final DateTime timestamp;
  final BreadcrumbCategory category;
  final String message;

  Map<String, Object?> toJson() => {
        'ts': timestamp.toUtc().toIso8601String(),
        'category': category.name,
        'message': message,
      };
}

/// Ring buffer of the most recent breadcrumbs.
class BreadcrumbTrail {
  BreadcrumbTrail({this.capacity = defaultCapacity});

  static const int defaultCapacity = 20;

  final int capacity;
  final Queue<Breadcrumb> _entries = Queue<Breadcrumb>();

  void add(Breadcrumb breadcrumb) {
    _entries.addLast(breadcrumb);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
  }

  /// Copy of the trail, oldest first, as it looked when an error happened.
  List<Breadcrumb> snapshot() => List<Breadcrumb>.unmodifiable(_entries);

  void clear() => _entries.clear();
}
