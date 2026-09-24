final RegExp _digitsOnly = RegExp(r'^\d+$');
final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final RegExp _longHex = RegExp(r'^[0-9a-fA-F]{8,}$');
final RegExp _tokenLike = RegExp(r'^[A-Za-z0-9_\-.~]{20,}$');
final RegExp _containsDigit = RegExp(r'\d');

/// The request path with identifier-like segments replaced by `:id` and the
/// query dropped: `GET /api/vault/8812?x=1` → `/api/vault/:id`.
///
/// The report `action` must be a route template, never a raw URL: ids
/// would split one failing endpoint into many groups and can carry
/// personal data.
String pathTemplateOf(Uri uri) {
  final segments = uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .map((segment) => _looksLikeIdentifier(segment) ? ':id' : segment);
  return '/${segments.join('/')}';
}

bool _looksLikeIdentifier(String segment) {
  if (_digitsOnly.hasMatch(segment) || _uuid.hasMatch(segment)) return true;
  if (segment.contains('@')) return true;
  final hasDigit = _containsDigit.hasMatch(segment);
  if (hasDigit && _longHex.hasMatch(segment)) return true;
  return hasDigit && _tokenLike.hasMatch(segment);
}
