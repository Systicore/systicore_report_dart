import 'dart:math';

import '../storage/reporter_storage.dart';
import '../support/reporter_log.dart';
import '../support/uuid.dart';

/// Random per-installation id, created once and kept in [ReporterStorage].
///
/// It is not derived from any hardware or account identifier, so it cannot
/// be linked to a person; reinstalling the app yields a new id.
class InstallIdRepository {
  InstallIdRepository(this._storage, {Random? random}) : _random = random;

  static const String storageKey = 'install_id';

  final ReporterStorage _storage;
  final Random? _random;

  Future<String> loadOrCreate() async {
    try {
      final stored = (await _storage.read(storageKey))?.trim();
      if (stored != null && isUuidV4(stored)) return stored;
    } catch (error, stackTrace) {
      ReporterLog.debug(
        'Could not read the install id',
        error: error,
        stackTrace: stackTrace,
      );
    }
    final created = generateUuidV4(_random);
    try {
      await _storage.write(storageKey, created);
    } catch (error, stackTrace) {
      ReporterLog.debug(
        'Could not store the install id',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return created;
  }
}
