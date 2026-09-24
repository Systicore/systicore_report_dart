import 'memory_reporter_storage.dart';
import 'reporter_storage.dart';

/// Platforms with neither dart:io nor a browser: nothing survives a restart.
ReporterStorage createPlatformStorage() => MemoryReporterStorage();
