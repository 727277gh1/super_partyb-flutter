import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:spb_platform/spb_platform.dart';

/// [MainWindowSize.compute] 的契约测试。
///
/// ## 它防的是什么（2026-10 真实缺陷）
///
/// 主窗口尺寸曾是硬编码的 1180×800 **逻辑像素**。1080p 的 14 寸笔记本在
/// Windows 上默认 150% 缩放，逻辑工作区只有约 680 高——窗口比工作区还高，
/// `center()` 算出负的 y，标题栏（可拖拽区 + 最大化按钮）跑到屏幕外。用户报
/// 「窗口无法移动、也点不到全屏最大化」。
///
/// ⚠️ 与**任务栏无关**：`window_manager.center()` 用的是 `visibleSize`
/// （Windows `rcWork` / Linux `gdk_monitor_get_workarea` / macOS
/// `visibleFrame`），三平台都已排除任务栏与系统栏。缺陷纯粹是「窗口比工作区高」。
///
/// ## 这些用例钉住的是「不会算出出屏的尺寸」
///
/// 判据不是「等于某个数」，而是**结果必须放得进工作区**（除非工作区小到连
/// `minHeight` 都放不下——那时窗口管理器自己钳制，不是本函数的责任）。
void main() {
  /// 常见笔记本 / 显示器的 (工作区宽, 工作区高) 逻辑像素。
  ///
  /// 1080p 物理屏在不同系统缩放下的逻辑工作区高度（已扣掉约 40 逻辑像素的
  /// 任务栏）。150% 那行就是用户报障的环境。
  const workAreas = <String, (double, double)>{
    '1080p @100%（1040 工作区高）': (1920, 1040),
    '1080p @125%（824 工作区高）': (1536, 824),
    '1080p @150%（680 工作区高）← 报障环境': (1280, 680),
    '1080p @175%（577 工作区高）': (1097, 577),
    '1440p @100%（1400 工作区高）': (2560, 1400),
    '4K @200%（1040 工作区高）': (1920, 1040),
    '超宽 3440×1440（1400 工作区高）': (3440, 1400),
  };

  group('MainWindowSize.compute：结果必须放得进工作区', () {
    workAreas.forEach((label, area) {
      test(label, () {
        final (width, height) = MainWindowSize.compute(
          workWidth: area.$1,
          workHeight: area.$2,
          minWidth: WindowSpec.main.minWidth,
          minHeight: WindowSpec.main.minHeight,
        );

        // 核心断言：不超过工作区。高度是报障的直接原因（标题栏出屏），
        // 宽度同理会让左右边缘的窗口控件不可达。
        //
        // ⚠️ 下限是 minHeight/minWidth：工作区小到连最小尺寸都放不下时
        // （如 1080p @175% 的 577 高 < minHeight 600），宁可让窗口略高于
        // 工作区（窗口管理器自己钳制），也不让页面布局溢出——minHeight 就是
        // 为布局定的。故判据是「不超过 max(工作区, min)」。
        expect(
          height,
          lessThanOrEqualTo(
            area.$2 > WindowSpec.main.minHeight
                ? area.$2
                : WindowSpec.main.minHeight,
          ),
          reason:
              '$label 下窗口高 $height 超出可用空间——'
              '居中后 y 为负，标题栏会跑到屏幕外（正是报障现象）',
        );
        expect(
          width,
          lessThanOrEqualTo(
            area.$1 > WindowSpec.main.minWidth
                ? area.$1
                : WindowSpec.main.minWidth,
          ),
          reason: '$label 下窗口宽 $width 超出可用空间',
        );
      });
    });

    test('1080p @150%（报障环境）的窗口真的比改前小', () {
      // 改前硬编码 800，工作区只有 680 → 出屏。这是本缺陷的核心数字。
      final (_, height) = MainWindowSize.compute(
        workWidth: 1280,
        workHeight: 680,
        minWidth: WindowSpec.main.minWidth,
        minHeight: WindowSpec.main.minHeight,
      );
      expect(
        height,
        lessThan(WindowSpec.main.height),
        reason: '必须小于改前的 800，否则标题栏仍会出屏',
      );
      expect(height, lessThanOrEqualTo(680));
    });
  });

  group('MainWindowSize.compute：具体取值', () {
    test('1080p @150%（报障环境）得到 680 高，不再是 800', () {
      final (width, height) = MainWindowSize.compute(
        workWidth: 1280,
        workHeight: 680,
        minWidth: WindowSpec.main.minWidth,
        minHeight: WindowSpec.main.minHeight,
      );
      // 680 * 0.85 = 578，低于 minHeight 600 → 兜底到 600。
      expect(height, 600, reason: '低于 minHeight 时兜底到 minHeight，而不是继续缩');
      expect(width, 1088, reason: '1280 * 0.85 = 1088，未触及 1180 上限');
    });

    test('大屏不无限放大：4K 上宽度封顶 1180', () {
      final (width, height) = MainWindowSize.compute(
        workWidth: 3840,
        workHeight: 2100,
        minWidth: WindowSpec.main.minWidth,
        minHeight: WindowSpec.main.minHeight,
      );
      expect(width, MainWindowSize.maxWidth, reason: '超过上限后只是变宽，可读性下降');
      expect(height, MainWindowSize.maxHeight);
    });

    test('中等屏按比例填充（1440p @100%）', () {
      final (width, height) = MainWindowSize.compute(
        workWidth: 2560,
        workHeight: 1400,
        minWidth: WindowSpec.main.minWidth,
        minHeight: WindowSpec.main.minHeight,
      );
      // 2560*0.85=2176 > 1180 → 封顶；1400*0.85=1190 > 800 → 封顶。
      expect(width, MainWindowSize.maxWidth);
      expect(height, MainWindowSize.maxHeight);
    });

    test('工作区恰好在 fillRatio 边界内时用比例值', () {
      // 900 * 0.85 = 765，介于 minHeight(600) 与 maxHeight(800) 之间。
      final (_, height) = MainWindowSize.compute(
        workWidth: 1000,
        workHeight: 900,
        minWidth: 860,
        minHeight: 600,
      );
      expect(height, closeTo(765, 0.01));
    });
  });

  group('MainWindowSize.compute：显示器信息拿不到时的降级', () {
    // 无 DISPLAY / 平台未实现时 visibleSize 与 size 都可能缺失，调用方会传 0
    // 或负数。此时必须退回规格里的静态值，**不能**算出 0×0 的窗口
    // （那样应用起来是个不可见的点，比出屏更难排查）。
    for (final (w, h) in [
      (0.0, 0.0),
      (-1.0, -1.0),
      (0.0, 1040.0),
      (1920.0, 0.0),
    ]) {
      test('工作区 ($w, $h) → 退回规格值', () {
        final (width, height) = MainWindowSize.compute(
          workWidth: w,
          workHeight: h,
          minWidth: WindowSpec.main.minWidth,
          minHeight: WindowSpec.main.minHeight,
        );
        expect(width, MainWindowSize.maxWidth);
        expect(height, MainWindowSize.maxHeight);
      });
    }
  });

  group('MainWindowSize.compute：小屏宁可略大也不小于 min', () {
    // 工作区小到 fillRatio 后低于 minHeight（例如 640 高的老屏幕）：
    // 此时返回 minHeight（600）——窗口会比「工作区的 85%」大，但仍在工作区内
    // 或仅略微超出，由窗口管理器钳制。**不能**返回更小的值，否则页面布局
    // （minHeight 600 就是为它定的）会溢出。
    test('640 高工作区 → 仍返回 minHeight 600', () {
      final (_, height) = MainWindowSize.compute(
        workWidth: 1024,
        workHeight: 640,
        minWidth: WindowSpec.main.minWidth,
        minHeight: WindowSpec.main.minHeight,
      );
      expect(height, 600);
      expect(height, lessThanOrEqualTo(640), reason: '600 < 640，仍放得下');
    });

    test('500 高工作区（低于 minHeight）→ 返回 minHeight 而非更小', () {
      final (_, height) = MainWindowSize.compute(
        workWidth: 1024,
        workHeight: 500,
        minWidth: 860,
        minHeight: 600,
      );
      expect(height, 600, reason: '宁可让窗口略高于工作区（窗口管理器钳制），也不让布局溢出');
    });
  });

  group('MainWindowSize.fromDisplay：工作区优先于整屏', () {
    // 这条判据写反的后果：用整屏尺寸算居中 → 窗口被推到任务栏底下
    // （Windows 任务栏默认在底部时，窗口底部那排按钮点不到）。
    test('有 visibleSize 时用它，忽略 size', () {
      final (_, height) = MainWindowSize.fromDisplay(
        visibleSize: const Size(1280, 680),
        fullSize: const Size(1280, 720),
      );
      // 680*0.85=578 < minHeight 600 → 600；若错用 720 则 720*0.85=612。
      expect(height, 600, reason: '用工作区 680 算（低于 min 则兜底），而非整屏 720');
    });

    test('visibleSize 缺失时回退 size（部分平台可能不给工作区）', () {
      final (width, height) = MainWindowSize.fromDisplay(
        visibleSize: null,
        fullSize: const Size(1600, 900),
      );
      // 900*0.85 = 765（介于 600 与 800）；若回退失败得 0 则会是 800。
      expect(height, closeTo(765, 0.01));
      expect(width, 1180, reason: '1600*0.85=1360 > 上限 1180');
    });

    test('两者都缺失 → 退回规格值（不抛、不算出 0×0）', () {
      final (width, height) = MainWindowSize.fromDisplay(
        visibleSize: null,
        fullSize: null,
      );
      expect(width, MainWindowSize.maxWidth);
      expect(height, MainWindowSize.maxHeight);
    });

    test('visibleSize 为零尺寸时也走降级（不是当成可用工作区）', () {
      // 某些平台无 DISPLAY 时可能返回 0×0 而不是 null。
      final (width, height) = MainWindowSize.fromDisplay(
        visibleSize: const Size(0, 0),
        fullSize: null,
      );
      expect(width, MainWindowSize.maxWidth);
      expect(height, MainWindowSize.maxHeight);
    });

    test('1080p @150% 的真实字段形态', () {
      // Windows 150% 缩放下 screen_retriever 报的是一对逻辑像素：
      // size 1280×720（整屏）、visibleSize 1280×680（扣掉 40 高任务栏）。
      final (width, height) = MainWindowSize.fromDisplay(
        visibleSize: const Size(1280, 680),
        fullSize: const Size(1280, 720),
        minWidth: WindowSpec.main.minWidth,
        minHeight: WindowSpec.main.minHeight,
      );
      expect(height, 600);
      expect(
        height,
        lessThan(WindowSpec.main.height),
        reason: '改前 800 会出屏，这里必须更小',
      );
      expect(width, lessThanOrEqualTo(1280));
    });
  });

  group('MainWindowSize 常量', () {
    test('fillRatio 在 (0, 1] 内', () {
      expect(MainWindowSize.fillRatio, greaterThan(0));
      expect(MainWindowSize.fillRatio, lessThanOrEqualTo(1));
    });

    test('上限不小于 WindowSpec.main 的规格值', () {
      // 上限若小于 spec，等于把「大屏上的期望尺寸」也一起改小了。
      expect(
        MainWindowSize.maxWidth,
        greaterThanOrEqualTo(WindowSpec.main.width),
      );
      expect(
        MainWindowSize.maxHeight,
        greaterThanOrEqualTo(WindowSpec.main.height),
      );
    });
  });
}
