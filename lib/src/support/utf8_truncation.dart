import 'dart:convert';

/// Cuts [value] to at most [maxBytes] UTF-8 bytes without splitting a
/// character, mirroring the server-side caps so a report never arrives
/// larger than what the backend would keep.
String truncateUtf8(String value, int maxBytes) {
  // A UTF-16 code unit never needs more than 3 UTF-8 bytes, so short
  // strings skip the encoding round trip.
  if (value.length * 3 <= maxBytes) return value;
  final encoded = utf8.encode(value);
  if (encoded.length <= maxBytes) return value;
  var end = maxBytes;
  while (end > 0 && _isContinuationByte(encoded[end])) {
    end--;
  }
  return utf8.decode(encoded.sublist(0, end));
}

/// Same as [truncateUtf8] but keeps null and turns blank text into null,
/// so optional payload fields are omitted instead of sent empty.
String? truncateOptionalUtf8(String? value, int maxBytes) {
  if (value == null || value.trim().isEmpty) return null;
  return truncateUtf8(value, maxBytes);
}

bool _isContinuationByte(int byte) => (byte & 0xC0) == 0x80;
