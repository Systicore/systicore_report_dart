// dart:io is missing on the web and would not even compile there. The
// browser adapter reports every network failure as connectionError itself.
export 'network_failure_cause_stub.dart'
    if (dart.library.io) 'network_failure_cause_io.dart';
