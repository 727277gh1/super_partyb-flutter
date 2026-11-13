import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// 包一层 MaterialApp（组件依赖 Theme 与 Directionality）。
Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 造一张习惯强化卡。
HabitAutoRunItem item({
  String id = 'evt-1',
  String topicKey = 'daily_review',
  String? runId = 'run-1',
  String? patternId = 'hp-1',
}) => HabitAutoRunItem(
  id: id,
  createdAt: DateTime.utc(2026, 10, 4),
  turnId: 'turn-1',
  topicKey: topicKey,
  runId: runId,
  patternId: patternId,
);

/// `habit_auto_run_completed` 渲染成可见的「习惯强化」卡。
///
/// ## 这个测试防的是什么
///
/// 该事件曾落到归约器的 `default:` 分支被静默丢弃（不在 `chatbus/broker.go`
/// 的常量表里），用户因此看不到「服务端帮你跑了一轮习惯」的回执。这里钉住
/// 的是**渲染层**的另一半：归约产出了项，但若 `_buildItem` 没有对应分支，
/// Flutter 的穷举 switch 会在编译期报错（这是好事），而若卡片渲染成空白，
/// 则不会有任何报错。故断言可见文案。
///
/// ## ⚠️ 文案与 webapp 对齐
///
/// 标签取 webapp `habitTimelineEventLabel` 的「习惯强化」（**不是**任务描述里
/// 写的「习惯已自动执行」——全仓无该文案，见 webapp 的 `habit-timeline.mts`）。
/// 摘要取 `formatHabitAutoRunCompletedSummary` 的
/// `habit 提醒已送达 · <topic 下划线转空格>`。
void main() {
  testWidgets('渲染「习惯强化」标签与摘要', (tester) async {
    await tester.pumpWidget(_host(HabitAutoRunCard(item: item())));

    expect(find.text('习惯强化'), findsOneWidget);
    expect(find.text('habit 提醒已送达 · daily review'), findsOneWidget);
  });

  testWidgets('topic_key 的分隔符换成空格（不把机器键丢给用户）', (tester) async {
    await tester.pumpWidget(
      _host(HabitAutoRunCard(item: item(topicKey: 'weekly-report'))),
    );

    expect(find.text('habit 提醒已送达 · weekly report'), findsOneWidget);
  });

  testWidgets('topic_key 为空时回退到「未命名习惯」（不显示空白）', (tester) async {
    await tester.pumpWidget(_host(HabitAutoRunCard(item: item(topicKey: ''))));

    expect(find.text('habit 提醒已送达 · 未命名习惯'), findsOneWidget);
  });

  testWidgets('纯通知：不渲染任何按钮（对齐 webapp 的 reward 分支）', (tester) async {
    await tester.pumpWidget(_host(HabitAutoRunCard(item: item())));

    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('卡片身份键用事件 id（列表 diff 依赖它）', (tester) async {
    await tester.pumpWidget(_host(HabitAutoRunCard(item: item(id: 'evt-42'))));

    expect(find.byKey(const ValueKey('habit-auto-run-evt-42')), findsOneWidget);
  });
}
