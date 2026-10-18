import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/habits_harness.dart';

/// 习惯页：规则列表 / 状态机按钮 / 操作回调 / 新建规则 / 加载失败 / 菜单入口
///
/// ⚠️ 本文件由 `habits_page_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `../support/habits_harness.dart`。
void main() {
  group('规则列表', () {
    testWidgets('渲染主题、触发节奏与元信息', (tester) async {
      await tester.pumpWidget(host(habits: [habit()]));
      await tester.pumpAndSettle();

      // topic_key 是机器键，换分隔符展示（不编造中文名）。
      expect(find.text('weekly report'), findsOneWidget);
      // time_based 形状按 times/weekday 渲染。
      expect(find.textContaining('每周一'), findsOneWidget);
      expect(find.textContaining('09:00'), findsOneWidget);
      expect(find.textContaining('已执行 3 次'), findsOneWidget);
      // 接受级别与来源拼在同一行（一个 Text），故用 textContaining。
      expect(find.textContaining('仅建议'), findsOneWidget);
      expect(find.textContaining('手动创建'), findsOneWidget);
    });

    testWidgets('空列表显示空态（而不是空白页）', (tester) async {
      await tester.pumpWidget(host(habits: const []));
      await tester.pumpAndSettle();

      expect(find.textContaining('还没有习惯'), findsOneWidget);
    });
  });

  group('状态机：只显示当前状态可用的按钮', () {
    testWidgets('active：显示立即执行 + 暂停 + 归档，不显示恢复', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit()],
          onTrigger: (_) async {},
          onPause: (_) async {},
          onResume: (_) async {},
          onArchive: (_) async {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-trigger-hp-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-pause-hp-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-archive-hp-1')), findsOneWidget);
      // 服务端 resume 仅接受 paused；对 active 显示它是「点了必然 409」。
      expect(find.byKey(const ValueKey('habit-resume-hp-1')), findsNothing);
    });

    testWidgets('paused：只显示恢复（trigger/pause 都会 409）', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit(status: HabitPatternStatus.paused)],
          onTrigger: (_) async {},
          onPause: (_) async {},
          onResume: (_) async {},
          onArchive: (_) async {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-resume-hp-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-trigger-hp-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-pause-hp-1')), findsNothing);
    });

    testWidgets('archived：只剩「归档」以外的操作全部消失', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit(status: HabitPatternStatus.archived)],
          onTrigger: (_) async {},
          onPause: (_) async {},
          onResume: (_) async {},
          onArchive: (_) async {},
        ),
      );
      await tester.pumpAndSettle();

      // 归档是终态：不再显示归档按钮（避免重复归档）。
      expect(find.byKey(const ValueKey('habit-archive-hp-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-trigger-hp-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-pause-hp-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-resume-hp-1')), findsNothing);
    });

    testWidgets('未注入回调时不显示任何操作按钮（只读展示）', (tester) async {
      await tester.pumpWidget(host(habits: [habit()]));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-trigger-hp-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-pause-hp-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-archive-hp-1')), findsNothing);
    });
  });

  group('操作回调', () {
    testWidgets('点「立即执行」传出该规则', (tester) async {
      final seen = <UserHabit>[];
      await tester.pumpWidget(
        host(habits: [habit()], onTrigger: (h) async => seen.add(h)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-trigger-hp-1')));
      await tester.pumpAndSettle();

      expect(seen.single.id, 'hp-1');
    });

    testWidgets('点「暂停」传出该规则', (tester) async {
      final seen = <UserHabit>[];
      await tester.pumpWidget(
        host(habits: [habit()], onPause: (h) async => seen.add(h)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-pause-hp-1')));
      await tester.pumpAndSettle();

      expect(seen.single.id, 'hp-1');
    });

    testWidgets('归档必须先确认；取消则不调用', (tester) async {
      final archived = <UserHabit>[];
      await tester.pumpWidget(
        host(habits: [habit()], onArchive: (h) async => archived.add(h)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-archive-hp-1')));
      await tester.pumpAndSettle();

      // 归档是终态，必须先说明不可撤销。
      expect(find.textContaining('无法恢复'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(archived, isEmpty, reason: '取消不应触发归档');
    });

    testWidgets('归档确认后调用回调', (tester) async {
      final archived = <UserHabit>[];
      await tester.pumpWidget(
        host(habits: [habit()], onArchive: (h) async => archived.add(h)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-archive-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-archive-confirm')));
      await tester.pumpAndSettle();

      expect(archived.single.id, 'hp-1');
    });

    testWidgets('409（状态不符）弹提示并说明原因，而非静默失败', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit()],
          onTrigger: (_) async =>
              throw const HttpError(409, '仅 active 状态可触发，当前: paused'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-trigger-hp-1')));
      await tester.pumpAndSettle();

      // 用户必须知道「是状态变了」而不是「客户端坏了」。
      expect(find.textContaining('仅 active 状态可触发'), findsOneWidget);
    });
  });

  group('新建规则', () {
    testWidgets('未注入 onCreate 时不显示新建入口', (tester) async {
      await tester.pumpWidget(host(habits: const []));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habits-create')), findsNothing);
    });

    testWidgets('对话框收集主题/执行方式/时间/重复，产出 draft', (tester) async {
      final drafts = <HabitDraft>[];
      await tester.pumpWidget(
        host(
          habits: const [],
          onCreate: (d) async {
            drafts.add(d);
            return 'hp-new';
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habits-create')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('habit-editor-topic')),
        'preference.coffee',
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('habit-editor-level-auto_run')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-editor-weekday-1')));
      await tester.tap(find.byKey(const ValueKey('habit-editor-weekday-3')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-editor-save')));
      await tester.pumpAndSettle();

      expect(drafts, hasLength(1));
      final d = drafts.single;
      expect(d.topicKey, 'preference.coffee');
      expect(d.acceptanceLevel, HabitAcceptanceLevel.autoRun);
      // 默认 9:00（与 webapp HabitPatternEditor 一致）。
      expect(d.triggerConfig!.time!.firstHour, 9);
      expect(d.triggerConfig!.time!.weekdays, [1, 3]);
    });

    testWidgets('主题为空时「创建」禁用', (tester) async {
      await tester.pumpWidget(
        host(habits: const [], onCreate: (_) async => ''),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habits-create')));
      await tester.pumpAndSettle();

      final btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('habit-editor-save')),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets('取消对话框不调用 onCreate', (tester) async {
      var created = 0;
      await tester.pumpWidget(
        host(
          habits: const [],
          onCreate: (_) async {
            created++;
            return '';
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habits-create')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(created, 0);
    });
  });

  group('加载失败', () {
    testWidgets('显示错误与重试按钮', (tester) async {
      await tester.pumpWidget(host(error: const NetworkError('连接失败')));
      await tester.pumpAndSettle();

      expect(find.text('连接失败'), findsOneWidget);
      expect(find.byKey(const ValueKey('habits-retry')), findsOneWidget);
    });

    testWidgets('点重试会重新拉取', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          loadHabits: () async {
            calls++;
            if (calls == 1) throw const NetworkError('连接失败');
            return [habit()];
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habits-retry')));
      await tester.pumpAndSettle();

      expect(calls, greaterThan(1));
      expect(find.text('weekly report'), findsOneWidget);
    });
  });

  group('规则菜单：编辑与执行记录入口', () {
    testWidgets('未注入 onEdit / loadHabitRuns 时没有溢出菜单', (tester) async {
      await tester.pumpWidget(host(habits: [habit()]));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-menu-hp-1')), findsNothing);
    });

    testWidgets('注入后菜单里有「编辑」与「执行记录」', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit()],
          onEdit: (h, patch) async {},
          loadHabitRuns: (_) async => const [],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-edit')), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-runs')), findsOneWidget);
    });

    testWidgets('只注入 onEdit 时菜单里只有「编辑」', (tester) async {
      await tester.pumpWidget(
        host(habits: [habit()], onEdit: (h, patch) async {}),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-edit')), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-runs')), findsNothing);
    });
  });
}
