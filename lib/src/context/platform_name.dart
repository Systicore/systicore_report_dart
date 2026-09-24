import 'package:flutter/foundation.dart';

/// The contract's `platform` value for the running app, or null for a
/// platform the contract has no name for (Fuchsia).
String? currentPlatformName() =>
    platformNameOf(isWeb: kIsWeb, targetPlatform: defaultTargetPlatform);

String? platformNameOf({
  required bool isWeb,
  required TargetPlatform targetPlatform,
}) {
  if (isWeb) return 'web';
  switch (targetPlatform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.linux:
      return 'linux';
    case TargetPlatform.fuchsia:
      return null;
  }
}
