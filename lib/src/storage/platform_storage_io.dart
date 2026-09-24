import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'file_reporter_storage.dart';
import 'reporter_storage.dart';

/// Android, iOS and desktop: files in the app's private support directory.
ReporterStorage createPlatformStorage() {
  return FileReporterStorage(() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return Directory(
      '${supportDirectory.path}${Platform.pathSeparator}systicore_report',
    );
  });
}
