import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_desktop/bootstrap.dart';
import 'package:spb_platform/spb_platform.dart';

/// `window_manager` 的平台通道名（与插件内部的 `const MethodChannel('window_manager')` 一致）。
const _windowManagerChannel = MethodChannel('window_manager');

/// `screen_retriever` 的平台通道名。
///
/// 必须一起 mock：`enterOverlayMode` 要按鼠标所在显示器算位置，而
/// `window_manager.center()` 内部也会查显示器（`calcWindowPosition`）。
/// 不 mock 时抛 `MissingPluginException` → 位置步骤失败 → 整轮回滚，
/// 用例就测不到「进入成功」的路径了。
const _screenRetrieverChannel = MethodChannel(
  'dev.leanflutter.plugins/screen_retriever',
);

/// 悬浮输入窗的「不打扰」契约：进入时隐藏、显示单独一步、退出按进入前的可见性收尾。
///
/// ## 为什么必须钉在通道层（2026-11 真实报障）
///
/// 用户报：按 `Alt+Space` 时**先看到主窗口被缩小、跳到左上角，然后才变成快捷
/// 窗口**；关掉快捷窗口后**原先的主窗口自己弹出来**，把正在用的应用顶掉。
///
/// 这两个症状都不是「逻辑错了」，而是**顺序/取舍错了**：
///
/// 1. `PlatformDesktopCapabilities.showWindow()` 先 `show()` 主窗口，然后
///    `enterOverlayMode()` 在**可见**窗口上逐步改尺寸/置顶/去任务栏/移动——
///    每一步都立刻重绘，用户看到的就是「缩小 → 跳位」的动画；
/// 2. `exitOverlayMode()` **无条件** `show() + focus()`，于是「从别的应用按
///    `Alt+Space` 记一笔」变成了「切换到一个全尺寸的应用窗口」。
///
/// 这两点都不会抛异常、也不会让任何页面级测试变红（窗口层在 widget 测试里
/// 是假的），只有把「通道上按什么顺序发了什么」钉住才拦得住。与
/// `window_close_test.dart`（关窗即隐藏从未生效）是同一失败模式。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;

  /// 进入前的窗口状态，由各用例覆写。
  late bool wasVisible;
  late bool wasMinimized;

  setUp(() {
    calls = [];
    wasVisible = true;
    wasMinimized = false;
    messenger.setMockMethodCallHandler(_windowManagerChannel, (call) async {
      calls.add(call);
      return switch (call.method) {
        // 键名是 `x`/`y`（`window_manager` 用 `Rect.fromLTWH(resultData['x'],
        // ...)` 读回），写成 left/top 会得到 null → 快照阶段就抛异常。
        'getBounds' => <String, Object?>{
          'x': 100.0,
          'y': 80.0,
          'width': 1180.0,
          'height': 800.0,
        },
        'isVisible' => wasVisible,
        'isMinimized' => wasMinimized,
        'isAlwaysOnTop' => false,
        'isSkipTaskbar' => false,
        'isResizable' => true,
        _ => true,
      };
    });

    messenger.setMockMethodCallHandler(_screenRetrieverChannel, (call) async {
      return <String, Object?>{
        'id': 'display-1',
        'name': 'test',
        'size': <String, Object?>{'width': 1920.0, 'height': 1080.0},
        'visiblePosition': <String, Object?>{'dx': 0.0, 'dy': 0.0},
        'visibleSize': <String, Object?>{'width': 1920.0, 'height': 1040.0},
        'scaleFactor': 1.0,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_windowManagerChannel, null);
    messenger.setMockMethodCallHandler(_screenRetrieverChannel, null);
  });

  List<String> methodNames() => calls.map((c) => c.method).toList();

  int indexOfMethod(String name) => methodNames().indexOf(name);

  group('进入悬浮模式：先隐藏，再见人（消除「主窗口缩小」的中间态）', () {
    test('hide 必须发生在任何改尺寸/位置之前', () async {
      final caps = PlatformDesktopCapabilities();
      calls.clear();

      await caps.enterOverlayMode(WindowSpec.quickCaptureWithAttachments);

      final hideAt = indexOfMethod('hide');
      expect(hideAt, greaterThanOrEqualTo(0), reason: '进入时必须先隐藏窗口');
      for (final method in [
        'setSize',
        'setMinimumSize',
        'center',
        'setPosition',
      ]) {
        final at = indexOfMethod(method);
        if (at < 0) continue;
        expect(
          hideAt,
          lessThan(at),
          reason: '`$method` 在可见窗口上执行会逐帧演给用户看（缩小/跳位）',
        );
      }
    });

    test('进入阶段**不**显示窗口（显示交给 revealOverlayMode）', () async {
      final caps = PlatformDesktopCapabilities();
      calls.clear();

      await caps.enterOverlayMode(WindowSpec.quickCaptureWithAttachments);

      // 此时窗口里的页面还是主界面：显示出来就是「主界面被压成小窗」那一帧。
      expect(indexOfMethod('show'), -1);
      expect(indexOfMethod('focus'), -1);
    });
  });

  group('showWindow(quickCapture)：快捷键/托盘入口也不先闪一下主窗口', () {
    test('未处于悬浮模式时不先 show（进入流程自己负责显示）', () async {
      final caps = PlatformDesktopCapabilities();
      calls.clear();

      await caps.showWindow(WindowRole.quickCapture);

      expect(
        indexOfMethod('show'),
        -1,
        reason: '先 show 再进悬浮模式 = 用户看到全尺寸主窗口被压成小窗（报障原话）',
      );
    });

    test('已处于悬浮模式时仍然 show + focus（再按一次 Alt+Space 要能看到它）', () async {
      final caps = PlatformDesktopCapabilities();
      await caps.enterOverlayMode(WindowSpec.quickCaptureWithAttachments);
      await caps.revealOverlayMode();
      calls.clear();

      await caps.showWindow(WindowRole.quickCapture);

      expect(indexOfMethod('show'), greaterThanOrEqualTo(0));
      expect(indexOfMethod('focus'), greaterThanOrEqualTo(0));
    });
  });

  group('revealOverlayMode：页面布局完成之后才显示', () {
    test('显示 + 聚焦', () async {
      final caps = PlatformDesktopCapabilities();
      await caps.enterOverlayMode(WindowSpec.quickCaptureWithAttachments);
      calls.clear();

      await caps.revealOverlayMode();

      expect(indexOfMethod('show'), greaterThanOrEqualTo(0));
      expect(indexOfMethod('focus'), greaterThanOrEqualTo(0));
    });

    test('未处于悬浮模式时为空操作（进入失败后调用安全）', () async {
      final caps = PlatformDesktopCapabilities();
      calls.clear();

      await caps.revealOverlayMode();

      expect(methodNames(), isEmpty);
    });
  });

  group('退出悬浮模式：回到进入前的可见性，不抢焦点', () {
    test('进入前主窗口在托盘里 → 保持隐藏（不 show、不 focus）', () async {
      wasVisible = false;
      final caps = PlatformDesktopCapabilities();
      await caps.enterOverlayMode(WindowSpec.quickCaptureWithAttachments);
      calls.clear();

      await caps.exitOverlayMode();

      expect(
        indexOfMethod('show'),
        -1,
        reason: '主窗口原本在托盘里，弹出来等于把「快速记一笔」变成「切换应用」',
      );
      expect(indexOfMethod('focus'), -1);
      // 悬浮窗本身必须先消失，否则用户看到的是一块小置顶窗留在屏幕上。
      expect(indexOfMethod('hide'), greaterThanOrEqualTo(0));
      // 尺寸仍要还原：下次用户从托盘打开主窗口时应该是原尺寸。
      expect(indexOfMethod('setBounds'), greaterThanOrEqualTo(0));
    });

    test('进入前主窗口可见 → 还原尺寸并显示', () async {
      wasVisible = true;
      wasMinimized = false;
      final caps = PlatformDesktopCapabilities();
      await caps.enterOverlayMode(WindowSpec.quickCaptureWithAttachments);
      calls.clear();

      await caps.exitOverlayMode();

      expect(indexOfMethod('show'), greaterThanOrEqualTo(0));
      expect(indexOfMethod('focus'), greaterThanOrEqualTo(0));
      expect(indexOfMethod('minimize'), -1);
    });

    test('进入前主窗口最小化 → 还原成最小化，不摆到前台', () async {
      wasVisible = true;
      wasMinimized = true;
      final caps = PlatformDesktopCapabilities();
      await caps.enterOverlayMode(WindowSpec.quickCaptureWithAttachments);
      calls.clear();

      await caps.exitOverlayMode();

      expect(indexOfMethod('minimize'), greaterThanOrEqualTo(0));
      expect(indexOfMethod('show'), -1, reason: '用户本来把窗口收起来了，退出时展开到前台同样是打断');
    });

    test('showMainWindow: true → 无视进入前状态，强制显示（托盘「设置…」用）', () async {
      wasVisible = false;
      final caps = PlatformDesktopCapabilities();
      await caps.enterOverlayMode(WindowSpec.quickCaptureWithAttachments);
      calls.clear();

      await caps.exitOverlayMode(showMainWindow: true);

      expect(
        indexOfMethod('show'),
        greaterThanOrEqualTo(0),
        reason: '用户明确要求看某个页面，不显示就是「点了没反应」',
      );
      expect(indexOfMethod('focus'), greaterThanOrEqualTo(0));
    });

    test('未进入过时为空操作（可重复调用）', () async {
      final caps = PlatformDesktopCapabilities();
      calls.clear();

      await caps.exitOverlayMode();

      expect(methodNames(), isEmpty);
    });
  });
}
