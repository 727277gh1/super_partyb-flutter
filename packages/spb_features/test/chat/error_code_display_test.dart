import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// `ErrorCodeIcon` token → `IconData` 的映射（`error_code_display.dart`）。
///
/// ## 这组用例守的是什么
///
/// 映射的失败形态不是崩溃，而是**静默等价**：把新 code 落进 `generic`，它就与
/// 「未知 code」长得一模一样——服务端明明给了分类，用户却看不出差异，而没有任何
/// 测试会红。故这里对 `ErrorCodes.all` 做全覆盖断言。
void main() {
  group('errorCodeIcon', () {
    test('闭集内每个 code 都有专属图标（不落到 generic）', () {
      for (final code in ErrorCodes.all) {
        expect(
          errorCodeIcon(code),
          isNot(Icons.error_outline),
          reason: 'code=$code 落进 generic 就与未知 code 无法区分',
        );
      }
    });

    test('未知 / 缺失 code 走通用兜底图标', () {
      for (final code in [null, '', 'brand_new_code']) {
        expect(errorCodeIcon(code), Icons.error_outline, reason: '$code');
      }
    });

    test('同类共享图标：两档超时是同一件事的不同刻度', () {
      expect(
        errorCodeIcon(ErrorCodes.timeoutInactivity),
        errorCodeIcon(ErrorCodes.timeoutHard),
        reason: '给用户不同图标只会让人以为图标 = 错误名，而用户不记忆图标语义',
      );
    });

    test('OOM 与限流不同图标（用户该做的事不同：调小任务 vs 稍后重试）', () {
      expect(
        errorCodeIcon(ErrorCodes.oomKill),
        isNot(errorCodeIcon(ErrorCodes.upstreamRateLimited)),
      );
    });
  });

  group('errorCodeLabel', () {
    test('闭集内每个 code 都有短徽标', () {
      for (final code in ErrorCodes.all) {
        final label = errorCodeLabel(code);
        expect(label, isNotNull, reason: code);
        expect(label, isNotEmpty, reason: code);
        // 徽标是「哪一类失败」，不是一句话话术：正文永远取服务端 message。
        expect(label!.length, lessThanOrEqualTo(8), reason: '$code 的徽标过长');
      }
    });

    test('未知 / 缺失 code 不给徽标（不猜分类）', () {
      for (final code in [null, '', 'brand_new_code']) {
        expect(errorCodeLabel(code), isNull, reason: '$code');
      }
    });
  });
}
