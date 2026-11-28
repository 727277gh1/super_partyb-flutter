import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_desktop/bootstrap.dart';

/// `window_manager` 的平台通道名（与插件内部的 `const MethodChannel('window_manager')` 一致）。
const _windowManagerChannel = MethodChannel('window_manager');

/// 主窗口「关窗 → 隐藏到托盘」的接线守卫。
///
/// ## 为什么这组用例必须存在（2026-11 真实报障）
///
/// 用户报「点窗口关闭按钮，应用直接退出了，托盘里也找不到」。
///
/// 根因不在 `onWindowClose`（它一直在调 `windowManager.hide()`），而在
/// **`preventClose` 从未被打开**：`window_manager` 的 `close` 事件是
/// **通知**而不是**拦截**，三平台原生侧都是「先派发事件，再看
/// `isPreventClose()` 决定要不要继续关闭」——
///
/// - Windows：`WM_CLOSE` 分支 `if (IsPreventClose()) return -1;`，否则落到
///   `DefWindowProc` **销毁窗口** → 消息循环退出 → 进程结束；
/// - Linux：GTK `delete_event` 回调 `return plugin->_is_prevent_close;`，
///   返回 false 即销毁窗口；
/// - macOS：`windowShouldClose` 返回 `isPreventClose()`。
///
/// 而事件是**异步**投递到 Dart 的：等 `onWindowClose` 里的 `hide()` 跑到时，
/// 原生侧早已把窗口销毁。故「关窗即隐藏」此前**从未真正生效过**——用户看到
/// 的就是「点关闭 = 退出」。
///
/// 这类缺陷**没有任何编译期或行为级信号**（`hide()` 调用确实发生了、返回值
/// 也确实正常），只有把「通道上到底发了什么」钉住才拦得住。这与 §6.33 /
/// §6.37 是同一失败模式：**绿不代表对**。
///
/// ## 为什么能直接构造 `PlatformDesktopCapabilities`
///
/// 它的构造函数只存三个资源路径，不碰平台通道；真正会调通道的是各方法本身。
/// 故「构造 + 调一个方法 + 断言通道调用」是可行且最贴近生产路径的验证方式
/// （`bootstrap.dart` 的其余部分确实无法在无头环境构造，见 AGENTS.md §6.57）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(_windowManagerChannel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_windowManagerChannel, null);
  });

  /// 通道上是否出现过某个方法调用。
  bool sawMethod(String name) => calls.any((c) => c.method == name);

  /// 取出某个方法调用的参数（后出现的覆盖先出现的）。
  Object? argsOf(String name) {
    Object? found;
    for (final call in calls) {
      if (call.method == name) found = call.arguments;
    }
    return found;
  }

  group('关窗即隐藏：必须真正拦截关闭（2026-11）', () {
    test('setHideOnClose(true) 打开 preventClose', () async {
      final caps = PlatformDesktopCapabilities();
      await caps.setHideOnClose(true);

      expect(sawMethod('setPreventClose'), isTrue);
      expect(
        argsOf('setPreventClose'),
        containsPair('isPreventClose', true),
        reason: '不打开 preventClose，原生侧会在 Dart 收到事件之前销毁窗口',
      );
    });

    test('setHideOnClose(false) 关闭 preventClose（托盘不可用时要允许退出）', () async {
      final caps = PlatformDesktopCapabilities();
      await caps.setHideOnClose(false);

      expect(argsOf('setPreventClose'), containsPair('isPreventClose', false));
    });

    test('onWindowClose：启用时隐藏窗口，且不销毁它', () async {
      final caps = PlatformDesktopCapabilities();
      await caps.setHideOnClose(true);
      calls.clear();

      caps.onWindowClose();
      await Future<void>.delayed(Duration.zero);

      expect(sawMethod('hide'), isTrue);
      // 关窗路径**绝不**能调 destroy（那是「真正退出」，只该由托盘「退出」走）。
      expect(sawMethod('destroy'), isFalse);
    });

    test('onWindowClose：未启用时不做任何窗口操作（让原生按默认行为退出）', () async {
      final caps = PlatformDesktopCapabilities();
      await caps.setHideOnClose(false);
      calls.clear();

      caps.onWindowClose();
      await Future<void>.delayed(Duration.zero);

      expect(sawMethod('hide'), isFalse);
      expect(sawMethod('destroy'), isFalse);
    });

    test('通道不可用时不抛（降级为「关窗即退出」，应用仍可用）', () async {
      messenger.setMockMethodCallHandler(_windowManagerChannel, (call) async {
        throw MissingPluginException('window_manager 不可用');
      });

      final caps = PlatformDesktopCapabilities();
      await expectLater(caps.setHideOnClose(true), completes);
    });

    test('quit() 先关 preventClose 再 destroy（否则 macOS 上退不出去）', () async {
      final caps = PlatformDesktopCapabilities();
      await caps.setHideOnClose(true);
      calls.clear();

      await caps.quit();

      // macOS 的 `destroy()` 是 `NSApp.terminate(nil)`，AppKit 在终止序列里
      // 会逐个窗口问 `windowShouldClose:`——返回 NO 就**取消终止**。故必须先
      // 把 preventClose 关掉，否则托盘「退出」在 macOS 上是死按钮。
      final preventIdx = calls.indexWhere((c) => c.method == 'setPreventClose');
      final destroyIdx = calls.indexWhere((c) => c.method == 'destroy');
      expect(preventIdx, isNonNegative);
      expect(destroyIdx, isNonNegative);
      expect(preventIdx, lessThan(destroyIdx));
      expect(
        calls[preventIdx].arguments,
        containsPair('isPreventClose', false),
      );
    });
  });
}
