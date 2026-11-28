import 'package:flutter_test/flutter_test.dart';
import 'package:spb_platform/spb_platform.dart';

void main() {
  test('按平台给出可操作的麦克风权限路径', () {
    expect(
      voicePermissionSettingsInstructions(VoicePermissionPlatform.android),
      contains('应用 → PartyB → 权限 → 麦克风'),
    );
    expect(
      voicePermissionSettingsInstructions(VoicePermissionPlatform.ios),
      contains('设置 → PartyB → 麦克风'),
    );
    expect(
      voicePermissionSettingsInstructions(VoicePermissionPlatform.macos),
      contains('隐私与安全性 → 麦克风'),
    );
    expect(
      voicePermissionSettingsInstructions(VoicePermissionPlatform.windows),
      contains('桌面应用访问麦克风'),
    );
    expect(
      voicePermissionSettingsInstructions(VoicePermissionPlatform.linux),
      contains('输入设备'),
    );
    expect(
      voicePermissionSettingsInstructions(VoicePermissionPlatform.other),
      contains('应用权限或隐私设置'),
    );
  });
}
