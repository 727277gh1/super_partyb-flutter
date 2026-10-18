import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// [AutoSchedulesPanel] 的渲染与交互测试（issue #13）。
///
/// ## 这个测试防的是什么
///
/// 1. **「停用全部」在无可撤销项时仍可点**：服务端停用谓词是
///    `enabled=1 AND run_count < max_runs`，一个次数已用尽的行不会被撤销。
///    若按裸 `enabled` 判可点，用户点下去得到「已停用 0 条」，看起来像坏了。
/// 2. **停用后不回读列表**：面板会停在旧的「待触发」状态，用户以为没生效而
///    反复点。故用**真实用例 + mock 传输**做一条端到端断言。
/// 3. **未注入回调却渲染了停用按钮**：禁用按钮会让用户以为「本端支持但暂时
///    不可用」，而真相是这一端没装配该能力。
/// 4. **加载失败静默成空列表**：用户会以为「确实没有排程」，而真相是请求失败。
/// 5. **切换对话时残留上一个 group 的排程**：那些行的 `meta.group_id` 指向
///    别的对话，会让用户以为在停本对话的续跑。
void main() {
  /// Go `ChatTurnSchedule` 的真实 JSON 形状（sqlc camelCase tag）。
  Map<String, dynamic> scheduleJson({
    String id = 'sch_1',
    String groupId = 'grp_1',
    String triggerReason = 'goal_gate',
    String message = '继续推进目标',
    bool enabled = true,
    int runCount = 0,
    int maxRuns = 5,
    Object? nextRunAt = const {'Time': '2026-10-04T09:00:00Z', 'Valid': true},
    Object? lastErrorJson,
  }) => {
    'id': id,
    'agentId': 'agt_1',
    'sessionId': 'sess_1',
    'agentType': 'pigo',
    'triggerReason': triggerReason,
    'triggerStatus': const {'String': 'pending', 'Valid': true},
    'message': message,
    'policyJson': '{"meta":{"group_id":"$groupId"}}',
    'dedupeKey': 'goal_gate:$groupId:t_1',
    'enabled': enabled,
    'runCount': runCount,
    'maxRuns': maxRuns,
    'nextRunAt': nextRunAt,
    'lastRunAt': const {'Time': '0001-01-01T00:00:00Z', 'Valid': false},
    'lastErrorJson': lastErrorJson,
    'createdAt': '2026-10-04T08:00:00Z',
    'updatedAt': '2026-10-04T08:30:00Z',
  };

  late List<ChatTurnSchedule> items;
  late int loadCalls;
  late int stopCalls;

  void useStubs({List<ChatTurnSchedule>? initial}) {
    items = initial ?? const [];
    loadCalls = 0;
    stopCalls = 0;
  }

  /// 泵入面板。
  ///
  /// 用两次 `pump()` 而非 `pumpAndSettle()`：首帧会显示
  /// [CircularProgressIndicator]（无限动画），`pumpAndSettle` 会一直等到超时。
  Future<void> pumpPanel(
    WidgetTester tester, {
    bool wireStopAll = true,
    bool busy = false,
    Object? reloadToken = 'grp_1',
    List<ChatTurnSchedule>? stopReturns,
    AutoSchedulesFailure? loadFailure,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AutoSchedulesPanel(
            load: () async {
              loadCalls++;
              if (loadFailure != null) throw loadFailure;
              return items;
            },
            onStopAll: wireStopAll
                ? () async {
                    stopCalls++;
                    items = stopReturns ?? items;
                    return items;
                  }
                : null,
            busy: busy,
            reloadToken: reloadToken,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  ChatTurnSchedule pending(String id) =>
      ChatTurnSchedule.fromJson(scheduleJson(id: id));

  ChatTurnSchedule disabled(String id) =>
      ChatTurnSchedule.fromJson(scheduleJson(id: id, enabled: false));

  ChatTurnSchedule exhausted(String id) =>
      ChatTurnSchedule.fromJson(scheduleJson(id: id, runCount: 5, maxRuns: 5));

  group('渲染', () {
    testWidgets('展示 triggerReason / message / 轮次 / 下次触发', (tester) async {
      useStubs(initial: [pending('sch_1')]);
      await pumpPanel(tester);

      expect(find.text('继续推进目标'), findsOneWidget);
      expect(
        find.text('goal_gate'),
        findsOneWidget,
        reason: 'triggerReason 用 wire 值：与 dedupe_key LIKE goal_gate:% 的判定对应',
      );
      expect(find.text('0/5 轮'), findsOneWidget);
      expect(find.textContaining('下次 2026-10-0'), findsOneWidget);
      expect(find.text('待触发'), findsOneWidget);
    });

    testWidgets('已停用 / 已用尽 的徽标文案不同', (tester) async {
      useStubs(initial: [disabled('sch_1'), exhausted('sch_2')]);
      await pumpPanel(tester);

      expect(find.text('已停用'), findsOneWidget);
      expect(find.text('已用尽'), findsOneWidget);
    });

    testWidgets('有 lastErrorJson 时展示（否则用户不知为何停住）', (tester) async {
      useStubs(
        initial: [
          ChatTurnSchedule.fromJson(
            scheduleJson(lastErrorJson: '{"error":"boom"}'),
          ),
        ],
      );
      await pumpPanel(tester);

      expect(find.text('{"error":"boom"}'), findsOneWidget);
    });

    testWidgets('空列表显示空提示', (tester) async {
      useStubs();
      await pumpPanel(tester);

      expect(
        find.byKey(const ValueKey('auto-schedules-empty')),
        findsOneWidget,
      );
    });
  });

  group('「停用全部」按钮的可点性', () {
    testWidgets('有 pending 项 → 可点，并显示计数', (tester) async {
      useStubs(initial: [pending('sch_1'), pending('sch_2')]);
      await pumpPanel(tester);

      final btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('auto-schedules-stop-all')),
      );
      expect(btn.onPressed, isNotNull);
      expect(find.text('停用全部待触发（2）'), findsOneWidget);
    });

    testWidgets('全部已停用 → 禁用', (tester) async {
      useStubs(initial: [disabled('sch_1'), disabled('sch_2')]);
      await pumpPanel(tester);

      final btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('auto-schedules-stop-all')),
      );
      expect(btn.onPressed, isNull, reason: '服务端谓词会撤销 0 条，点下去只会让用户以为坏了');
    });

    testWidgets('次数已用尽（enabled 仍为 true）→ 也禁用', (tester) async {
      useStubs(initial: [exhausted('sch_1')]);
      await pumpPanel(tester);

      final btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('auto-schedules-stop-all')),
      );
      expect(
        btn.onPressed,
        isNull,
        reason: '停用谓词含 run_count < max_runs，用尽的行不会被撤销',
      );
    });

    testWidgets('父层 busy → 禁用（防并发提交互相覆盖）', (tester) async {
      useStubs(initial: [pending('sch_1')]);
      await pumpPanel(tester, busy: true);

      final btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('auto-schedules-stop-all')),
      );
      expect(btn.onPressed, isNull);
    });
  });

  group('未注入 onStopAll = 只读', () {
    testWidgets('不渲染停用按钮（不是禁用）', (tester) async {
      useStubs(initial: [pending('sch_1')]);
      await pumpPanel(tester, wireStopAll: false);

      expect(
        find.byKey(const ValueKey('auto-schedules-stop-all')),
        findsNothing,
        reason: '禁用按钮会让用户以为「本端支持但暂时不可用」',
      );
      // 列表本身仍正常渲染。
      expect(find.text('继续推进目标'), findsOneWidget);
    });
  });

  group('错误处理', () {
    testWidgets('加载失败展示已翻译的文案 + 可重试', (tester) async {
      useStubs();
      await pumpPanel(
        tester,
        loadFailure: const AutoSchedulesFailure('网络连接失败，请检查网络后重试'),
      );

      expect(
        find.byKey(const ValueKey('auto-schedules-error')),
        findsOneWidget,
      );
      expect(find.textContaining('网络连接失败，请检查网络后重试'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('auto-schedules-retry')),
        findsOneWidget,
      );
    });

    testWidgets('加载失败不静默成空列表', (tester) async {
      useStubs();
      await pumpPanel(
        tester,
        loadFailure: const AutoSchedulesFailure('服务端暂时不可用，请稍后重试'),
      );

      expect(
        find.byKey(const ValueKey('auto-schedules-empty')),
        findsNothing,
        reason: '静默成空列表会让用户以为「确实没有排程」',
      );
    });

    testWidgets('纵深防御：装配层注入裸 SpbError 也不崩（未翻译）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AutoSchedulesPanel(
              load: () async => throw const HttpError(500, 'HTTP 500'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('auto-schedules-error')),
        findsOneWidget,
        reason: '用例未翻译时应由面板兜住，而不是抛到框架',
      );
    });

    testWidgets('停用失败展示文案（列表让位给错误条）', (tester) async {
      useStubs(initial: [pending('sch_1')]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AutoSchedulesPanel(
              load: () async => items,
              onStopAll: () async =>
                  throw const AutoSchedulesFailure('操作太频繁，请稍后再试'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('auto-schedules-stop-all')));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('操作太频繁，请稍后再试'), findsOneWidget);
    });
  });

  group('切换对话', () {
    testWidgets('reloadToken 变化 → 清空旧列表并重新加载', (tester) async {
      useStubs(initial: [pending('sch_1')]);
      await pumpPanel(tester, reloadToken: 'grp_1');
      expect(find.text('继续推进目标'), findsOneWidget);
      expect(loadCalls, 1);

      // 切到另一个 group：新 group 没有排程。
      items = const [];
      await pumpPanel(tester, reloadToken: 'grp_2');

      expect(loadCalls, 2);
      expect(
        find.byKey(const ValueKey('auto-schedules-empty')),
        findsOneWidget,
        reason: '不能残留上一个 group 的排程',
      );
    });
  });

  /// 停用后**用回调返回的列表**替换本地状态。
  ///
  /// ## 为什么是这条断言（而不是「再 load() 一次」）
  ///
  /// [StopAllAutoSchedules] 的契约是「回调带回回读后的权威列表」。若面板忽略
  /// 返回值、自己再 `load()`，会多两次请求且两次之间服务端可能又变了。
  /// 这里用「初始 pending / 回调返回 disabled」的桩把「面板确实采纳了返回值」
  /// 钉死；用例**真的会回读**这一层由 `auto_schedules_test.dart` 的端到端
  /// 断言负责（那里能用真 Dio，不被 widget 测试的 fake async 卡住）。
  group('停用后回读列表', () {
    testWidgets('面板采纳回调返回的权威列表（按钮随之禁用）', (tester) async {
      useStubs(initial: [pending('sch_1')]);
      await pumpPanel(
        tester,
        // 服务端停用后回读到的列表：同一条已 enabled:false。
        stopReturns: [disabled('sch_1')],
      );

      // 初始：pending，按钮可点。
      expect(find.text('待触发'), findsOneWidget);
      var btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('auto-schedules-stop-all')),
      );
      expect(btn.onPressed, isNotNull);

      await tester.tap(find.byKey(const ValueKey('auto-schedules-stop-all')));
      await tester.pump();
      await tester.pump();

      expect(stopCalls, 1);
      expect(
        find.text('已停用'),
        findsOneWidget,
        reason: '必须显示回读后的权威状态，而不是旧的「待触发」',
      );
      btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('auto-schedules-stop-all')),
      );
      expect(btn.onPressed, isNull, reason: '回读后已无 pending，按钮应禁用——否则用户会反复点');
    });

    testWidgets('停用后列表变空 → 显示空提示', (tester) async {
      useStubs(initial: [pending('sch_1')]);
      await pumpPanel(tester, stopReturns: const []);

      await tester.tap(find.byKey(const ValueKey('auto-schedules-stop-all')));
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('auto-schedules-empty')),
        findsOneWidget,
      );
    });
  });
}
