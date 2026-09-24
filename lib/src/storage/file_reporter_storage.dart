import 'dart:io';

import 'reporter_storage.dart';

/// Stores each key as a file inside one directory.
///
/// Writes go to a temporary file that is then renamed over the target, so a
/// crash in the middle of a write leaves the previous queue intact.
class FileReporterStorage implements ReporterStorage {
  FileReporterStorage(this._directoryProvider);

  final Future<Directory> Function() _directoryProvider;
  Future<Directory>? _directory;

  @override
  Future<String?> read(String key) async {
    final file = await _fileFor(key);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String key, String value) async {
    final file = await _fileFor(key);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(value, flush: true);
    await temporary.rename(file.path);
  }

  Future<File> _fileFor(String key) async {
    final directory = await (_directory ??= _prepareDirectory());
    return File('${directory.path}${Platform.pathSeparator}$key');
  }

  Future<Directory> _prepareDirectory() async {
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    return directory;
  }
}
