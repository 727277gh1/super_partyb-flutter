import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// 记录调用参数的假 use case。
///
/// ## 为什么用「记录 input 列表」而不是记录完整调用
///
/// `QuickCaptureSubmit` 的签名里**只有 `input`**（没有 groupId 参数）——
/// 这正是本任务要用类型钉死的不变量。所以「记录调用参数」这件事本身就只能
/// 记下 input；若将来有人给回调加了 groupId 参数，本文件的 [_calls] 类型
/// 会立刻编译失败，从而把这个契约破坏暴露出来。
class _FakeUseCase {
  _FakeUseCase(this._outcome);

  /// 每次提交收到的 input。
  final calls = <String>[];

  QuickCaptureOutcome _outcome;

  /// 让测试可以中途改变返回值（如「先失败再成功」）。
  set outcome(QuickCaptureOutcome v) => _outcome = v;

  Future<QuickCaptureOutcome> submit(String input) async {
    calls.add(input);
    return _outcome;
  }

  /// 构造一个 queued 结果。
  static QuickCaptureQueued queued({
    String groupId = 'grp_1',
    String turnId = 'turn_1',
  }) => QuickCaptureQueued(
    groupId: groupId,
    turnId: turnId,
    result: QuickCaptureResult(
      turnId: turnId,
      groupId: groupId,
      status: 'queued',
    ),
  );

  /// 构造一个 feedback_recorded 结果（终态，不建 turn）。
  static QuickCaptureFeedbackRecorded feedbackRecorded({
    String groupId = 'grp_1',
  }) => QuickCaptureFeedbackRecorded(
    groupId: groupId,
    result: QuickCaptureResult(
      turnId: '',
      groupId: groupId,
      status: 'feedback_recorded',
    ),
  );

  /// 构造一个未知状态结果。
  static QuickCaptureUnknown unknown({
    String groupId = 'grp_1',
    String status = 'some_future_state',
  }) => QuickCaptureUnknown(
    groupId: groupId,
    result: QuickCaptureResult(turnId: '', groupId: groupId, status: status),
  );
}

/// 抛错的假 use case（测错误分支）。
class _ThrowingUseCase {
  _ThrowingUseCase(this.error);

  final SpbError error;
  final calls = <String>[];

  Future<QuickCaptureOutcome> submit(String input) async {
    calls.add(input);
    throw error;
  }
}

Widget _host(Widget child) => MaterialApp(home: child);

void main() {
  group('QuickCapturePage 提交', () {
    testWidgets('Enter 提交，回调只收到 input（无法传 groupId）', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await tester.enterText(find.byType(TextField), '帮我查一下日志');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(useCase.calls, ['帮我查一下日志']);
    });

    testWidgets('提交的文本被 trim', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await tester.enterText(find.byType(TextField), '   带空格的输入   ');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(useCase.calls, ['带空格的输入']);
    });

    testWidgets('空输入按 Enter 不提交', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(useCase.calls, isEmpty);
    });

    testWidgets('纯空白输入不提交', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await tester.enterText(find.byType(TextField), '     ');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(useCase.calls, isEmpty);
    });

    testWidgets('点发送按钮也可提交', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await tester.enterText(find.byType(TextField), '按钮提交');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick-capture-submit')));
      await tester.pump();

      expect(useCase.calls, ['按钮提交']);
    });

    testWidgets('发送按钮：空输入时禁用', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('quick-capture-submit')),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('QuickCapturePage queued：交出导航目标但不自己导航', () {
    testWidgets('onQueued 收到服务端判定的 groupId 与 turnId', (tester) async {
      final useCase = _FakeUseCase(
        _FakeUseCase.queued(groupId: 'grp_detected', turnId: 'turn_x'),
      );
      final queued = <QuickCaptureQueued>[];
      await tester.pumpWidget(
        _host(QuickCapturePage(submit: useCase.submit, onQueued: queued.add)),
      );

      await tester.enterText(find.byType(TextField), '无归属输入');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(queued, hasLength(1));
      expect(queued.single.groupId, 'grp_detected');
      expect(queued.single.turnId, 'turn_x');
    });

    testWidgets('成功后清空输入框（可直接打下一句）', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(
        _host(QuickCapturePage(submit: useCase.submit, onQueued: (_) {})),
      );

      await tester.enterText(find.byType(TextField), '发出去');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });

    testWidgets('onQueued 为 null 时仍能成功提交（不崩）', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await tester.enterText(find.byType(TextField), '无人处理导航');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(useCase.calls, hasLength(1));
    });
  });

  group('QuickCapturePage feedback_recorded：终态', () {
    testWidgets('不触发 onQueued（否则会导航到永远没有回答的对话）', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.feedbackRecorded());
      final queued = <QuickCaptureQueued>[];
      await tester.pumpWidget(
        _host(QuickCapturePage(submit: useCase.submit, onQueued: queued.add)),
      );

      await tester.enterText(find.byType(TextField), '反馈#正确');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(useCase.calls, ['反馈#正确']);
      expect(queued, isEmpty, reason: '终态不得导航');
    });

    testWidgets('显示「已记录归属反馈」提示', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.feedbackRecorded());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await tester.enterText(find.byType(TextField), '反馈#正确');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('已记录归属反馈'), findsOneWidget);
    });

    testWidgets('清空输入框（提示是一次性的，用户可继续输入）', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.feedbackRecorded());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await tester.enterText(find.byType(TextField), '反馈#错误');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });
  });

  group('QuickCapturePage 未知状态', () {
    testWidgets('不触发 onQueued 且提示未识别状态（含原始 status）', (tester) async {
      final useCase = _FakeUseCase(
        _FakeUseCase.unknown(status: 'brand_new_state'),
      );
      final queued = <QuickCaptureQueued>[];
      await tester.pumpWidget(
        _host(QuickCapturePage(submit: useCase.submit, onQueued: queued.add)),
      );

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(queued, isEmpty, reason: '未知状态不导航（避免停到错误对话）');
      expect(find.textContaining('brand_new_state'), findsOneWidget);
    });
  });

  group('QuickCapturePage 失败', () {
    testWidgets('显示失败提示且保留输入（便于重试）', (tester) async {
      final useCase = _ThrowingUseCase(const NetworkError('连接超时'));
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await tester.enterText(find.byType(TextField), '会失败的输入');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.textContaining('提交失败'), findsOneWidget);
      expect(find.textContaining('连接超时'), findsOneWidget);
      // 保留输入：清空会让用户重打一遍。
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '会失败的输入',
      );
    });

    testWidgets('失败后不触发 onQueued', (tester) async {
      final useCase = _ThrowingUseCase(const NetworkError('boom'));
      final queued = <QuickCaptureQueued>[];
      await tester.pumpWidget(
        _host(QuickCapturePage(submit: useCase.submit, onQueued: queued.add)),
      );

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(queued, isEmpty);
    });
  });

  group('QuickCapturePage 取消', () {
    testWidgets('Esc 触发 onCancel 且不提交', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      var cancelled = 0;
      await tester.pumpWidget(
        _host(
          QuickCapturePage(submit: useCase.submit, onCancel: () => cancelled++),
        ),
      );

      await tester.enterText(find.byType(TextField), '不想发了');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(cancelled, 1);
      expect(useCase.calls, isEmpty);
    });

    testWidgets('点取消按钮触发 onCancel', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      var cancelled = 0;
      await tester.pumpWidget(
        _host(
          QuickCapturePage(submit: useCase.submit, onCancel: () => cancelled++),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('quick-capture-cancel')));
      await tester.pump();

      expect(cancelled, 1);
    });

    testWidgets('onCancel 为 null 时按 Esc 不崩', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(useCase.calls, isEmpty);
    });
  });

  group('QuickCapturePage 布局契约', () {
    testWidgets('输入框是单行的（对应 132px 窗高）', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.maxLines, 1, reason: '悬浮窗只够一行输入 + 一行提示');
      expect(field.textInputAction, TextInputAction.done);
    });

    testWidgets('默认显示快捷键提示', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      expect(find.text('Enter 提交 · Esc 取消'), findsOneWidget);
    });
  });
}
