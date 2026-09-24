/// Client-side size caps, in UTF-8 bytes.
///
/// They match the backend's truncation caps except for the trace: the
/// grouping only uses the top in-app frames, and every queued report is
/// persisted, so a 16 KB trace keeps a full queue small on disk.
abstract final class FieldLimits {
  static const int typeBytes = 200;
  static const int codeBytes = 100;
  static const int messageBytes = 8 * 1024;
  static const int traceBytes = 16 * 1024;
  static const int actionBytes = 200;
  static const int routeBytes = 500;
  static const int requestIdBytes = 100;
  static const int maxTags = 10;
  static const int tagKeyBytes = 32;
  static const int tagValueBytes = 128;
}
