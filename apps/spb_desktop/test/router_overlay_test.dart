import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_platform/spb_platform.dart';

import 'package:spb_desktop/router.dart';

import 'support/desktop_harness.dart';

/// 悬浮输入窗（`/overlay`）的 router 接线。
///
/// ## 这条用例防的是什么
///
/// 悬浮窗高度曾写死 360（按「附件 chip + 四行输入」的最坏情况算），而默认
/// 状态只有一行输入——窗口里 2/3 是空白（2026-11 报障「快捷对话窗口为什么
/// 有一大片空白」）。修复靠**两条**接线：
///
/// 1. 页面把内容自然高度报上来（`OverlayQuickCapturePage.onContentHeight`）；
/// 2. router 把它转给能力层（`OverlayWindowController.fitOverlayContentHeight`）。
///
/// 页面自己的测试（`overlay_quick_capture_page_test.dart`）只覆盖第 1 条
/// ——它自己传回调，所以 router 忘了转发时它依然全绿。故这里从**路由**进入，
/// 断言能力层真的收到了合理的内容高度。
void main() {
  testWidgets('/overlay 把内容高度转给能力层（悬浮窗据此贴合窗口）', (tester) async {
    final caps = _OverlayCapabilities();
    final h = await pumpApp(tester, capabilities: caps);

    h.router.go(SpbRoutes.overlay);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('overlay-input')), findsOneWidget);
    expect(
      caps.fittedHeights,
      isNotEmpty,
      reason: '没上报内容高度的话，窗口高度只能写死 → 就是「一大片空白」那个缺陷',
    );
    // 默认测试视口 800×600：报的必须是内容高度（约 130），不是视口高度
    // ——报视口高度等于「贴合回它本来的高度」，窗口永远缩不回去。
    expect(
      caps.fittedHeights.last,
      lessThan(400),
      reason: '上报的必须是内容自然高度；报视口高度等于没修',
    );
    expect(caps.fittedHeights.last, greaterThan(0));
  });
}

/// 同时实现 [OverlayWindowController] 的能力桩。
///
/// ## 为什么继承 [FakeDesktopCapabilities] 而不是从零实现
///
/// 只需要多两个方法，其余能力与本用例无关——继承让新增的 `DesktopCapabilities`
/// 方法不会因为本文件而编译失败（与 `_WiringCapabilities` 同一取向）。
class _OverlayCapabilities extends FakeDesktopCapabilities
    implements OverlayWindowController {
  /// 收到的贴合请求（内容高度，按顺序）。
  final fittedHeights = <double>[];

  bool _active = false;

  @override
  bool get isOverlayModeActive => _active;

  @override
  Future<bool> enterOverlayMode(WindowSpec spec) async {
    _active = true;
    return true;
  }

  @override
  Future<void> exitOverlayMode() async => _active = false;

  @override
  Future<void> fitOverlayContentHeight(double contentHeight) async {
    fittedHeights.add(contentHeight);
  }
}
