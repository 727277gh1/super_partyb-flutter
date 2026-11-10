import 'package:flutter_test/flutter_test.dart';

import 'package:spb_platform/spb_platform.dart';

/// [DesktopCapabilities.revealPath] 与 [DesktopCapabilities.openFile] 的契约测试。
///
/// 能力层约定（对齐接口的静默降级哲学）：**返回 bool，不抛异常**。
/// Linux 的真实 spawn（`xdg-open`）由 `PlatformDesktopCapabilities` 在
/// `apps/spb_desktop` 实现，那里无法在无头环境可靠验证（依赖 DISPLAY），
/// 故本包只测「不支持时返回 false 不抛」这条契约。
void main() {
  group('revealPath（在文件管理器中定位目录）', () {
    test('NoopDesktopCapabilities.revealPath 返回 false 不抛异常', () async {
      const caps = NoopDesktopCapabilities();
      // 关键：不抛异常（接口的静默降级哲学），调用方只在 false 时提示一次。
      final ok = await caps.revealPath('/tmp/some-dir');
      expect(ok, isFalse);
    });

    test('NoopDesktopCapabilities.revealPath 对空串/不存在路径也只返回 false', () async {
      const caps = NoopDesktopCapabilities();
      expect(await caps.revealPath(''), isFalse);
      expect(await caps.revealPath('/no/such/path/here'), isFalse);
    });
  });

  group('openFile（用系统默认程序打开文件）', () {
    test('NoopDesktopCapabilities.openFile 返回 false 不抛异常', () async {
      const caps = NoopDesktopCapabilities();
      final ok = await caps.openFile('/tmp/some-file.md');
      expect(ok, isFalse);
    });

    test('NoopDesktopCapabilities.openFile 对空串/不存在路径也只返回 false', () async {
      const caps = NoopDesktopCapabilities();
      expect(await caps.openFile(''), isFalse);
      expect(await caps.openFile('/no/such/file.md'), isFalse);
    });
  });

  test('NoopDesktopCapabilities.isSupported 为 false（揭示为何两个打开方法恒 false）', () {
    const caps = NoopDesktopCapabilities();
    // 移动端注入 Noop：UI 用 isSupported 决定是否展示「打开」入口，
    // 用返回值决定是否提示失败。两者一致由这条断言守护。
    expect(caps.isSupported, isFalse);
  });
}
