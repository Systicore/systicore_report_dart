import 'dart:math';

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Random RFC 4122 version 4 UUID. Implemented here instead of pulling in
/// `package:uuid` because this is the only place the package needs one.
String generateUuidV4([Random? random]) {
  final source = random ?? _secureRandomOrFallback();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0'));
  final digits = hex.join();
  return '${digits.substring(0, 8)}-${digits.substring(8, 12)}-'
      '${digits.substring(12, 16)}-${digits.substring(16, 20)}-'
      '${digits.substring(20)}';
}

bool isUuidV4(String value) => _uuidPattern.hasMatch(value);

Random _secureRandomOrFallback() {
  try {
    return Random.secure();
  } on UnsupportedError {
    return Random();
  }
}
