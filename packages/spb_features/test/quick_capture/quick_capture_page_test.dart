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
  ///
  /// [matchedTitle] / [createdGroup] 是服务端的**归属判定产出**（调用方没给
  /// group_id，归属完全由服务端分类链决定），页面据此展示「这条消息去了哪」。
  static QuickCaptureQueued queued({
    String groupId = 'grp_1',
    String turnId = 'turn_1',
    String? matchedTitle,
    bool createdGroup = false,
  }) => QuickCaptureQueued(
    groupId: groupId,
    turnId: turnId,
    result: QuickCaptureResult(
      turnId: turnId,
      groupId: groupId,
      status: 'queued',
      matchedTitle: matchedTitle,
      createdGroup: createdGroup,
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

  group('QuickCapturePage queued：展示服务端归属判定结果', () {
    /// 提交一句话并等页面稳定。
    Future<void> submit(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    testWidgets('matched_title 非空 → 展示「已归入「<title>」」', (tester) async {
      // ## 这个用例防的是什么
      //
      // `matched_title` 是服务端「静默切组」时唯一的解释来源：调用方没指定
      // 归属，服务端把消息判给了**另一个**既有对话。不展示的话用户在原对话
      // 里等回答，永远等不到，也找不到消息去哪了（webapp 为此专门弹 toast）。
      final useCase = _FakeUseCase(_FakeUseCase.queued(matchedTitle: '日志排查'));
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await submit(tester, '帮我看看这个报错');

      expect(find.text('已归入「日志排查」'), findsOneWidget);
    });

    testWidgets('created_group=true → 展示「已新建对话」', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued(createdGroup: true));
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await submit(tester, '一个全新话题');

      expect(find.text('已新建对话'), findsOneWidget);
    });

    testWidgets('两者皆有 → 合并成一行展示（状态行只有一行）', (tester) async {
      // 悬浮窗高 132px，状态行只有一行（见 _buildStatusLine）：两条信息必须
      // 合并，否则后者会把前者挤出可视区。
      final useCase = _FakeUseCase(
        _FakeUseCase.queued(matchedTitle: '日志排查', createdGroup: true),
      );
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await submit(tester, 'x');

      expect(find.text('已归入「日志排查」，已新建对话'), findsOneWidget);
    });

    testWidgets('两者皆无 → 不渲染空壳提示（回到快捷键说明）', (tester) async {
      // 落到既有对话、且服务端没回标题时两个字段都是空的。此时渲染一条只有
      // 图标没有信息的提示会让用户以为出了错。
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      await submit(tester, 'x');

      expect(find.text('已归入「」'), findsNothing);
      expect(find.text('已新建对话'), findsNothing);
      expect(
        find.text('Enter 提交 · Esc 取消'),
        findsOneWidget,
        reason: '无可展示信息时状态行应回到快捷键说明，而不是留一个空壳',
      );
    });

    testWidgets('展示归属提示不影响交出导航目标', (tester) async {
      // 展示与导航是两件事：页面既要让用户看到判定结果，也要把 groupId 交给
      // 上层去导航（回归保护，防止改动时把 onQueued 一并去掉）。
      final useCase = _FakeUseCase(
        _FakeUseCase.queued(groupId: 'grp_detected', matchedTitle: '日志排查'),
      );
      final queued = <QuickCaptureQueued>[];
      await tester.pumpWidget(
        _host(QuickCapturePage(submit: useCase.submit, onQueued: queued.add)),
      );

      await submit(tester, 'x');

      expect(queued, hasLength(1));
      expect(queued.single.groupId, 'grp_detected');
      expect(find.text('已归入「日志排查」'), findsOneWidget);
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

  group('QuickCapturePage 路由预览（只预览 agent，不预览 group）', () {
    /// 构造一个带候选的预览结果（与真实服务端响应同形）。
    RoutingPreview preview({
      String agentId = 'ag_1',
      String routeSource = 'fallback',
      List<RoutingCandidate> candidates = const [
        RoutingCandidate(agentId: 'ag_1', name: '通用助手'),
      ],
    }) => RoutingPreview(
      resolvedAgentId: agentId,
      routeSource: routeSource,
      candidates: candidates,
    );

    testWidgets('点「预览」触发注入回调，并把输入传给它', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      final asked = <String>[];
      await tester.pumpWidget(
        _host(
          QuickCapturePage(
            submit: useCase.submit,
            previewRouting: (input) async {
              asked.add(input);
              return preview();
            },
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '帮我查日志');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick-capture-preview')));
      await tester.pumpAndSettle();

      expect(asked, ['帮我查日志']);
      // 预览**不**提交（它是只读查询）。
      expect(useCase.calls, isEmpty);
    });

    testWidgets('展示结果：agent 名字 + 标注「兜底默认」', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(
        _host(
          QuickCapturePage(
            submit: useCase.submit,
            previewRouting: (input) async => preview(),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick-capture-preview')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('quick-capture-preview-result')),
        findsOneWidget,
      );
      // 文案必须是「将使用 agent」+「兜底默认」——服务端响应里**没有**
      // group_id，写成「将发送到某对话」就是编造。
      expect(find.textContaining('将使用 agent：通用助手'), findsOneWidget);
      expect(find.textContaining('兜底默认'), findsOneWidget);
    });

    testWidgets('候选里找不到 id 时退回显示 id（不假装有名字）', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(
        _host(
          QuickCapturePage(
            submit: useCase.submit,
            // 候选为空：服务端只给了 id。
            previewRouting: (input) async =>
                preview(agentId: 'ag_unknown', candidates: const []),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick-capture-preview')));
      await tester.pumpAndSettle();

      expect(find.textContaining('ag_unknown'), findsOneWidget);
    });

    testWidgets('空输入点预览：不调回调，给出提示', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      var asked = 0;
      await tester.pumpWidget(
        _host(
          QuickCapturePage(
            submit: useCase.submit,
            previewRouting: (input) async {
              asked++;
              return preview();
            },
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('quick-capture-preview')));
      await tester.pumpAndSettle();

      expect(asked, 0, reason: '空输入没必要发请求');
      expect(find.textContaining('先输入内容'), findsOneWidget);
    });

    testWidgets('改输入后旧预览失效（不显示过时结果）', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(
        _host(
          QuickCapturePage(
            submit: useCase.submit,
            previewRouting: (input) async => preview(),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '第一句');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick-capture-preview')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('quick-capture-preview-result')),
        findsOneWidget,
      );

      // 改内容：旧结果对应的是「第一句」，留着会误导。
      await tester.enterText(find.byType(TextField), '完全不同的第二句');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('quick-capture-preview-result')),
        findsNothing,
        reason: '输入变化后旧预览必须失效',
      );
    });

    testWidgets('未接线时不显示「预览」入口', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(_host(QuickCapturePage(submit: useCase.submit)));

      expect(find.byKey(const ValueKey('quick-capture-preview')), findsNothing);
      // 原有提示不受影响。
      expect(find.text('Enter 提交 · Esc 取消'), findsOneWidget);
    });

    testWidgets('预览失败展示错误且不崩溃', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(
        _host(
          QuickCapturePage(
            submit: useCase.submit,
            previewRouting: (input) async => throw const NetworkError('连不上'),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick-capture-preview')));
      await tester.pumpAndSettle();

      expect(find.textContaining('预览失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('布局契约：预览入口不额外占一行（132px 窗高）', (tester) async {
      final useCase = _FakeUseCase(_FakeUseCase.queued());
      await tester.pumpWidget(
        _host(
          QuickCapturePage(
            submit: useCase.submit,
            previewRouting: (input) async => preview(),
          ),
        ),
      );

      // 预览结果复用状态行（见 _buildStatusLine）：输入框仍是单行，
      // 且预览前后都没有溢出异常。
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.maxLines, 1);

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick-capture-preview')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
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
