// Picks the storage backend at compile time: dart:io is missing on the web
// and would not even compile there.
export 'platform_storage_stub.dart'
    if (dart.library.io) 'platform_storage_io.dart'
    if (dart.library.js_interop) 'platform_storage_web.dart';
