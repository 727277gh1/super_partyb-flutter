import 'package:flutter_test/flutter_test.dart';

import 'package:spb_platform/spb_platform.dart';

/// [trayMenuNeedsBringToFront] 的契约测试。
///
/// ## 它防的是什么（2026-11 Windows 真实缺陷）
///
/// 托盘右键菜单曾是「弹出后卡住的列表」：Win32 的 `TrackPopupMenu` 要求
/// 调用窗口处于前台，否则点外面收不回去（整个应用看起来像死机）。
/// `tray_manager` 把修法暴露为 `popUpContextMenu(bringAppToFront:)`，
/// 默认 `false`——不传就是把 bug 原样放进产品。
///
/// ## 为什么必须有这个测试
///
/// 本机无 Windows（AGENTS.md §9），Windows 分支的行为**无法真机验证**。
/// 这条判据是「Windows 分支是否真的对」的唯一自动化保障——若有人把
/// 判据改回「恒 false」或写反方向，这里会红；而它在真实托盘上崩溃的
/// 表现（菜单卡死）只有 Windows 用户报障才会暴露。
///
/// ## 反向验证
///
/// 把判据改成「恒 false」（修复前行为）→ windows 用例失败；
/// 改成「所有平台都 true」→ linux/macos 用例失败（后者会传一个
/// Linux 未实现的参数，且 macOS 无必要）。
void main() {
  group('trayMenuNeedsBringToFront', () {
    test('windows 必须为 true（TrackPopupMenu 前台要求）', () {
      expect(trayMenuNeedsBringToFront(HostPlatform.windows), isTrue);
    });

    test('linux / macos / other 为 false', () {
      expect(trayMenuNeedsBringToFront(HostPlatform.linux), isFalse);
      expect(trayMenuNeedsBringToFront(HostPlatform.macos), isFalse);
      expect(trayMenuNeedsBringToFront(HostPlatform.other), isFalse);
    });
  });
}
