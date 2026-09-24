import 'package:flutter/foundation.dart';

/// User attached to a report (`user` in the ingest body). Without a valid
/// Bearer token the backend stores it as claimed, not verified.
@immutable
class ReportUser {
  const ReportUser({required this.id, this.issuer});

  final String id;
  final String? issuer;

  Map<String, Object?> toJson() => {
        'id': id,
        if (issuer != null && issuer!.isNotEmpty) 'issuer': issuer,
      };
}
