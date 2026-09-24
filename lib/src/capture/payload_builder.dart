import '../config/reporter_config.dart';
import '../support/utf8_truncation.dart';
import 'captured_error.dart';
import 'field_limits.dart';
import 'report_envelope.dart';

/// Turns a [CapturedError] into the JSON body of `POST /api/v1/ingest`
/// (contract v1 §3). Empty optional fields are omitted, never sent blank.
class PayloadBuilder {
  const PayloadBuilder(this._envelope);

  final ReportEnvelope _envelope;

  Map<String, Object?> build(CapturedError captured) {
    final context = _contextOf(captured);
    final environment = _envelope.environment.trim();
    return {
      'error': _errorOf(captured),
      'release': _releaseOf(_envelope.release),
      if (environment.isNotEmpty) 'environment': environment,
      if (_envelope.platform != null) 'platform': _envelope.platform,
      'device': _envelope.device.toJson(),
      if (captured.user != null) 'user': captured.user!.toJson(),
      if (context.isNotEmpty) 'context': context,
    };
  }

  Map<String, Object?> _errorOf(CapturedError captured) {
    final type = truncateOptionalUtf8(captured.type, FieldLimits.typeBytes);
    final code = truncateOptionalUtf8(captured.code, FieldLimits.codeBytes);
    final message =
        truncateOptionalUtf8(captured.message, FieldLimits.messageBytes);
    final trace = truncateOptionalUtf8(captured.trace, FieldLimits.traceBytes);
    final action =
        truncateOptionalUtf8(captured.action, FieldLimits.actionBytes);
    return {
      if (type != null) 'type': type,
      if (code != null) 'code': code,
      if (message != null) 'message': message,
      if (trace != null) 'trace': trace,
      if (action != null) 'action': action,
      'severity': captured.severity.wireName,
    };
  }

  Map<String, Object?> _releaseOf(ReleaseInfo release) {
    final version = release.version;
    final commit = release.commit;
    final buildTime = release.buildTime;
    return {
      if (version != null && version.isNotEmpty) 'version': version,
      if (commit != null && commit.isNotEmpty) 'commit': commit,
      if (buildTime != null && buildTime.isNotEmpty) 'buildTime': buildTime,
    };
  }

  Map<String, Object?> _contextOf(CapturedError captured) {
    final route = truncateOptionalUtf8(captured.route, FieldLimits.routeBytes);
    final requestId =
        truncateOptionalUtf8(captured.requestId, FieldLimits.requestIdBytes);
    final tags = _limitTags(captured.tags);
    return {
      if (route != null) 'route': route,
      if (requestId != null) 'requestId': requestId,
      if (tags.isNotEmpty) 'tags': tags,
      if (captured.breadcrumbs.isNotEmpty)
        'breadcrumbs': [
          for (final breadcrumb in captured.breadcrumbs) breadcrumb.toJson(),
        ],
    };
  }

  Map<String, String> _limitTags(Map<String, String> tags) {
    final limited = <String, String>{};
    for (final entry in tags.entries) {
      if (limited.length >= FieldLimits.maxTags) break;
      final key = truncateUtf8(entry.key.trim(), FieldLimits.tagKeyBytes);
      if (key.isEmpty) continue;
      limited[key] = truncateUtf8(entry.value, FieldLimits.tagValueBytes);
    }
    return limited;
  }
}
