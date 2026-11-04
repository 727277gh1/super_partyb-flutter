import 'package:flutter_test/flutter_test.dart';

import 'package:spb_platform/spb_platform.dart';

/// [overlayRollbackOrder] 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 「进入悬浮输入窗」在多步窗口改写中途失败时，若不回滚，窗口会停在半改造
/// 状态（720×360、置顶、从任务栏消失），而 `isOverlayModeActive == false` 又
/// 让所有 `exitOverlayMode()` 变成空操作——用户看到「一个卡住的小窗，然后应用
/// 像是退出了」。回滚顺序是本修复的核心判据，而真实实现
/// （`apps/spb_desktop/bootstrap.dart` 的 `PlatformDesktopCapabilities`）需要
/// `window_manager` 才能构造，测试里造不出来（AGENTS.md §6.41 / §6.45 同一
/// 取向）。故顺序判据放在本包做纯逻辑、在这里逐条钉住。
void main() {
  test('逆序回滚（最后改的最先还原）', () {
    expect(
      overlayRollbackOrder(const [
        OverlayWindowAttribute.minimumSize,
        OverlayWindowAttribute.size,
        OverlayWindowAttribute.resizable,
        OverlayWindowAttribute.alwaysOnTop,
        OverlayWindowAttribute.skipTaskbar,
        OverlayWindowAttribute.position,
        OverlayWindowAttribute.visibility,
      ]),
      [
        OverlayWindowAttribute.position,
        OverlayWindowAttribute.skipTaskbar,
        OverlayWindowAttribute.alwaysOnTop,
        OverlayWindowAttribute.resizable,
        OverlayWindowAttribute.size,
        OverlayWindowAttribute.minimumSize,
      ],
    );
  });

  test('剔除 visibility（它没有「之前的值」可还原）', () {
    expect(
      overlayRollbackOrder(const [OverlayWindowAttribute.visibility]),
      isEmpty,
      reason: '只走到 show/focus 就失败时，没有属性需要还原',
    );
    expect(
      overlayRollbackOrder(const [
        OverlayWindowAttribute.alwaysOnTop,
        OverlayWindowAttribute.visibility,
      ]),
      [OverlayWindowAttribute.alwaysOnTop],
    );
  });

  test('只回滚**真的改过**的步骤（部分失败时清单就是前缀）', () {
    // 第 3 步（resizable）失败：前两步成功、已记账。
    expect(
      overlayRollbackOrder(const [
        OverlayWindowAttribute.minimumSize,
        OverlayWindowAttribute.size,
      ]),
      [OverlayWindowAttribute.size, OverlayWindowAttribute.minimumSize],
    );
  });

  test('快照阶段就失败（什么都没改）→ 空计划', () {
    expect(overlayRollbackOrder(const []), isEmpty);
  });

  test('重复记账去重（不重复 setXxx，避免无谓的平台通道往返）', () {
    // 逆序遍历时，重复项保留**最后应用**的那一次位置（那是窗口的最终状态），
    // 后面的重复项跳过。正确代码里不会出现重复，这条只防「将来有人忘了
    // 记账前清空 `_overlayApplied`」。
    expect(
      overlayRollbackOrder(const [
        OverlayWindowAttribute.alwaysOnTop,
        OverlayWindowAttribute.size,
        OverlayWindowAttribute.alwaysOnTop,
      ]),
      [OverlayWindowAttribute.alwaysOnTop, OverlayWindowAttribute.size],
    );
  });

  test('返回值不依赖入参对象（每次调用都是新列表，调用方可以清空自己的记账）', () {
    final applied = [OverlayWindowAttribute.alwaysOnTop];
    final plan = overlayRollbackOrder(applied);
    applied.clear();
    expect(plan, [OverlayWindowAttribute.alwaysOnTop]);
  });
}
