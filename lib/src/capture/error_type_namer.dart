/// Names the class of a captured error for `error.type`.
///
/// Minified builds (Flutter web release) and obfuscated builds
/// (`--obfuscate`) rename classes, so `runtimeType`
/// yields names like `minified:Ab` that change from build to build. The
/// backend fingerprints `type` first, so such a name would open a new group
/// on every release and break regression detection. In these builds the
/// type is left out, and grouping falls back to the code and the message.
class ErrorTypeNamer {
  /// [runtimeNamesAreReadable] defaults to what this build shows: false when
  /// the compiler renamed classes.
  ErrorTypeNamer({bool? runtimeNamesAreReadable})
      : _runtimeNamesAreReadable =
            runtimeNamesAreReadable ?? _probedNamesAreReadable;

  static const String _minifiedPrefix = 'minified:';

  // A class whose source name is known: when its runtime name differs, this
  // build renames classes. String literals are never renamed.
  static final bool _probedNamesAreReadable =
      _TypeNameProbe().runtimeType.toString() == '_TypeNameProbe';

  final bool _runtimeNamesAreReadable;

  /// The class name of [error], or null when this build's class names are
  /// not stable across releases.
  String? nameOf(Object error) {
    if (!_runtimeNamesAreReadable) return null;
    try {
      final name = error.runtimeType.toString();
      return name.startsWith(_minifiedPrefix) ? null : name;
    } catch (_) {
      // A class may override runtimeType; a broken one must not stop the
      // report.
      return null;
    }
  }
}

class _TypeNameProbe {}
