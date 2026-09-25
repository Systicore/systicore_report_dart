import 'package:flutter/foundation.dart';

/// User attached to a report (`user` in the ingest body). Without a valid
/// Bearer token the backend stores it as claimed, not verified.
@immutable
class ReportUser {
  const ReportUser({required this.id, this.issuer});

  final String id;
  final String? issuer;

  bool get hasIssuer => issuer != null && issuer!.isNotEmpty;

  /// This user, with [fallbackIssuer] as the issuer when it has none.
  ReportUser withFallbackIssuer(String? fallbackIssuer) {
    if (hasIssuer || fallbackIssuer == null || fallbackIssuer.isEmpty) {
      return this;
    }
    return ReportUser(id: id, issuer: fallbackIssuer);
  }

  Map<String, Object?> toJson() => {
        'id': id,
        if (hasIssuer) 'issuer': issuer,
      };
}
