/// Small key-value text storage for the reporter's own state: the queue of
/// undelivered reports and the install id.
///
/// Implementations may throw; callers treat every failure as "not stored".
abstract interface class ReporterStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}
