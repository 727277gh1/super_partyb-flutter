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

  /// [fitOverlayWindowHeight] 的契约测试。
  ///
  /// ## 这个测试防的是什么
  ///
  /// 悬浮窗高度以前是写死的 360（按「chip + 四行输入」的最坏情况算），
  /// 纯文本场景下窗口里 2/3 是空白。改成「按内容贴合」后，换算规则的三个
  /// 边界都是用户可见的：
  /// - 取整方向错了 → 底部按钮被裁掉 0.5px（或闪烁）；
  /// - 没有下限 → 窗口比标题栏还矮，看起来像坏了；
  /// - 没有上限 → 拖入十几个附件后悬浮窗长到盖住半个屏幕；
  /// - NaN 没处理 → `clamp` 原样吐回 NaN，`setSize` 收到 NaN 尺寸。
  group('fitOverlayWindowHeight', () {
    test('向上取整（宁可多 0.4px，也不要裁掉底部按钮）', () {
      // 取值在量程中间，避开上下限的夹取（下限 132 / 上限 480）。
      expect(fitOverlayWindowHeight(150.1), 151);
      expect(fitOverlayWindowHeight(150), 150);
    });

    test('低于下限夹到下限（窗口不会被压得比一行还矮）', () {
      expect(fitOverlayWindowHeight(40), kOverlayMinWindowHeight);
    });

    test('超过上限夹到上限（之后由内容区滚动接管）', () {
      expect(fitOverlayWindowHeight(900), kOverlayMaxWindowHeight);
    });

    test('NaN 不产生 NaN 窗口高度', () {
      expect(fitOverlayWindowHeight(double.nan), kOverlayMinWindowHeight);
      // 无穷大是「内容无界」的退化值：夹到上限，而不是让 setSize 收到 infinity。
      expect(fitOverlayWindowHeight(double.infinity), kOverlayMaxWindowHeight);
    });

    test('量程可以显式覆盖（调用方按平台外框余量放宽）', () {
      expect(fitOverlayWindowHeight(500, max: 800), 500);
      expect(fitOverlayWindowHeight(10, min: 60), 60);
    });
  });
}
