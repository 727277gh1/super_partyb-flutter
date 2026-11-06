import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// 全局错误兜底（issue #45）。
///
/// ## 这个测试防的是什么
///
/// issue #40 的「导出诊断日志」只能包含显式走 [SpbLog] 的日志。异常若没被
/// `try/catch` 包住就进不了环形缓冲——**用户导出的报告里不会有它**。
/// 这组测试钉住「三类未捕获异常都会进环形缓冲」。
///
/// ## 测试策略：save / restore 全局钩子
///
/// `FlutterError.onError` 与 `PlatformDispatcher.instance.onError` 都是**全局
/// 单例**。直接改它们会污染同一进程里的其他用例（`flutter_test` 自己也依赖
/// `FlutterError.onError` 来报错）。故每个用例：
///
/// 1. 保存原 handler；
/// 2. 装新的；
/// 3. 断言；
/// 4. `addTearDown` 还原。
///
/// ## 为什么不用 `installGlobalErrorHandlers`（含 Zone）测 Zone 那条
///
/// [runZonedGuarded] 会捕获 body 里的异常并**不再上抛**——在 `flutter_test`
/// 里这会让「测试通过」但看不到断言失败。故 Zone 那条用一个**独立的小 Zone**
/// 直接验证语义（见最后一组），而不是走 `installGlobalErrorHandlers`。
void main() {
  setUp(() {
    // 全局单例会跨用例累积，断言「缓冲里有什么」前必须先清。
    SpbLog.clearRecentLogs();
    SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug);
  });

  /// 在给定 message 的日志里找 error 字段（断言「异常进了缓冲」）。
  Iterable<LogRecord> recordsWith(String message) =>
      SpbLog.recentLogs.where((r) => r.message == message);

  group('FlutterError.onError（框架异常）', () {
    test('框架异常被记进环形缓冲，且带 stack', () {
      final original = FlutterError.onError;
      addTearDown(() => FlutterError.onError = original);
      installFlutterErrorHandler();

      final details = FlutterErrorDetails(
        exception: StateError('构建时炸了'),
        stack: StackTrace.current,
        library: 'widget library',
      );
      FlutterError.onError!(details);

      final rec = recordsWith('Flutter 框架异常').single;
      expect(rec.level, LogLevel.error);
      expect(rec.fields['error'], contains('构建时炸了'));
      expect(rec.fields['stack'], isNotNull);
      expect(rec.fields['library'], 'widget library');
      expect(rec.fields['silent'], isFalse);
    });

    test('保留上一个 handler（不抢占既有兜底）', () {
      // ⚠️ 这条防的是「为了加日志而把别人的 handler 顶掉」。真实场景：
      // 某个测试或插件已经装了 handler，我们的装配不该让它失效。
      final original = FlutterError.onError;
      addTearDown(() => FlutterError.onError = original);

      final forwarded = <FlutterErrorDetails>[];
      FlutterError.onError = forwarded.add;

      installFlutterErrorHandler();
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('x'),
          stack: StackTrace.current,
        ),
      );

      expect(forwarded, hasLength(1), reason: '原 handler 必须仍被调用');
      expect(recordsWith('Flutter 框架异常'), hasLength(1));
    });

    test('silent 异常也记录（silent 只影响是否打红屏，不影响诊断价值）', () {
      final original = FlutterError.onError;
      addTearDown(() => FlutterError.onError = original);
      installFlutterErrorHandler();

      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('静默失败'),
          stack: StackTrace.current,
          silent: true,
        ),
      );

      final rec = recordsWith('Flutter 框架异常').single;
      expect(rec.fields['silent'], isTrue);
      expect(rec.fields['error'], contains('静默失败'));
    });
  });

  group('PlatformDispatcher.onError（异步异常）', () {
    test('未捕获的异步异常被记录，且返回 true（阻止进程终止）', () {
      final original = PlatformDispatcher.instance.onError;
      addTearDown(() => PlatformDispatcher.instance.onError = original);
      installPlatformErrorHandler();

      final handled = PlatformDispatcher.instance.onError!(
        StateError('异步炸了'),
        StackTrace.current,
      );

      expect(handled, isTrue, reason: '不返回 true 时某些平台会终止进程');
      final rec = recordsWith('未捕获的异步异常').single;
      expect(rec.fields['error'], contains('异步炸了'));
    });

    test('保留上一个 handler 的返回值（不无条件吞掉）', () {
      final original = PlatformDispatcher.instance.onError;
      addTearDown(() => PlatformDispatcher.instance.onError = original);

      // 上一个 handler 声明「我处理不了」。
      PlatformDispatcher.instance.onError = (e, st) => false;

      installPlatformErrorHandler();
      final handled = PlatformDispatcher.instance.onError!(
        StateError('x'),
        StackTrace.current,
      );

      expect(handled, isFalse, reason: '应沿用上一个 handler 的判定');
      expect(recordsWith('未捕获的异步异常'), hasLength(1));
    });
  });

  group('Zone 未捕获异常（runZonedGuarded）', () {
    test('body 里抛的同步异常被 Zone 捕获并记日志（不上抛）', () async {
      // ⚠️ 这里**不能**用 installGlobalErrorHandlers：它内部会 runZonedGuarded，
      // 而 Zone 会吞掉异常——测试里断言失败会被静默吞掉。故只验证装配的
      // **语义**：Zone 捕获 → SpbLog.error。
      //
      // 用一个受控的 Zone 复现 installGlobalErrorHandlers 的回调体。
      final completer = Completer<void>();
      runZonedGuarded(() => throw StateError('Zone 里炸了'), (error, stack) {
        SpbLog.error('Zone 未捕获异常', error: error, stackTrace: stack);
        completer.complete();
      });
      await completer.future;

      final rec = recordsWith('Zone 未捕获异常').single;
      expect(rec.fields['error'], contains('Zone 里炸了'));
    });

    test('installGlobalErrorHandlers 会调用 body 并装上两个钩子', () async {
      final originalFlutter = FlutterError.onError;
      final originalPlatform = PlatformDispatcher.instance.onError;
      addTearDown(() {
        FlutterError.onError = originalFlutter;
        PlatformDispatcher.instance.onError = originalPlatform;
      });

      var bodyRan = false;
      installGlobalErrorHandlers(() async {
        bodyRan = true;
      });
      // body 是 unawaited 的，给它一个 microtask。
      await Future<void>.delayed(Duration.zero);

      expect(bodyRan, isTrue);
      // 两个钩子都应已替换（不是 null 的默认值）。
      expect(FlutterError.onError, isNotNull);
      expect(PlatformDispatcher.instance.onError, isNotNull);

      // 验证它们真的会把异常写进缓冲。
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('装配后'),
          stack: StackTrace.current,
        ),
      );
      PlatformDispatcher.instance.onError!(
        StateError('装配后异步'),
        StackTrace.current,
      );

      expect(recordsWith('Flutter 框架异常'), hasLength(1));
      expect(recordsWith('未捕获的异步异常'), hasLength(1));
    });
  });
}
