import 'package:flutter/foundation.dart';

/// A finished ingest payload waiting for delivery, plus what the sender
/// needs to know about it.
@immutable
class QueuedReport {
  const QueuedReport({
    required this.id,
    required this.createdAt,
    required this.payload,
    this.userId,
  });

  /// Throws [FormatException] or a [TypeError] on malformed input; the
  /// queue skips such entries.
  factory QueuedReport.fromJson(Map<String, Object?> json) {
    return QueuedReport(
      id: json['id']! as String,
      createdAt: DateTime.parse(json['createdAt']! as String),
      userId: json['userId'] as String?,
      payload: Map<String, Object?>.from(
        json['payload']! as Map<String, Object?>,
      ),
    );
  }

  /// Local identity, used to remove exactly this entry after delivery.
  final String id;
  final DateTime createdAt;

  /// User signed in when the error was captured. A Bearer token is only
  /// attached while the same user is still signed in, so a report never
  /// gets attributed to whoever happens to be signed in at replay time.
  final String? userId;

  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {
        'id': id,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (userId != null) 'userId': userId,
        'payload': payload,
      };
}
