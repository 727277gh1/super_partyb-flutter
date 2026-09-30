import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_models/spb_models.dart';
import 'package:spb_features/spb_features.dart';

/// [MyTurnsPage] 的渲染与交互测试。
///
/// 页面纯 UI：数据拉取靠注入回调，不发起真实网络（无头环境）。
ChatTurnSummary _turn({
  String turnId = 'turn_1',
  String groupId = 'grp_1',
  String? groupTitle = '测试对话',
  String inputPreview = '帮我看看这个报错',
  String status = 'completed',
  TurnSource source = TurnSource.chat,
  bool hasError = false,
}) =>
    ChatTurnSummary(
      turnId: turnId,
      groupId: groupId,
      groupTitle: groupTitle,
      inputPreview: inputPreview,
      status: status,
      source: source,
      createdAt: DateTime(2024, 3, 5, 12, 0),
      messageCount: 2,
      hasError: hasError,
    );

void main() {
  testWidgets('最近轮次列表渲染状态徽标、来源、摘要与时间', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: MyTurnsPage(
          fetch: () async => [
            _turn(),
            _turn(
              turnId: 'turn_2',
              groupId: 'grp_2',
              groupTitle: '另一个对话',
              inputPreview: '整理周报',
              status: 'failed',
              source: TurnSource.schedule,
            ),
          ],
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('my-turns-list')), findsOneWidget);
    expect(find.text('帮我看看这个报错'), findsOneWidget);
    expect(find.text('整理周报'), findsOneWidget);
    expect(find.text('测试对话'), findsOneWidget);
    expect(find.text('另一个对话'), findsOneWidget);
    // 状态与来源徽标。
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('定时'), findsOneWidget);
  });

  testWidgets('点击轮次跳转携带正确的 groupId', (t) async {
    String? openedGroupId;
    await t.pumpWidget(
      MaterialApp(
        home: MyTurnsPage(
          fetch: () async => [
            _turn(groupId: 'grp_x'),
            _turn(turnId: 'turn_2', groupId: 'grp_y', inputPreview: '整理周报'),
          ],
          onOpenTurn: (gid) => openedGroupId = gid,
        ),
      ),
    );
    await t.pumpAndSettle();

    await t.tap(find.text('帮我看看这个报错'));
    await t.pump();
    expect(openedGroupId, 'grp_x');

    await t.tap(find.text('整理周报'));
    await t.pump();
    expect(openedGroupId, 'grp_y');
  });

  testWidgets('空态友好提示', (t) async {
    await t.pumpWidget(
      MaterialApp(home: MyTurnsPage(fetch: () async => const [])),
    );
    await t.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('my-turns-empty')),
      findsOneWidget,
    );
    expect(find.text('最近没有轮次记录'), findsOneWidget);
  });

  testWidgets('错误态展示原因与重试', (t) async {
    var calls = 0;
    await t.pumpWidget(
      MaterialApp(
        home: MyTurnsPage(fetch: () async {
          calls++;
          throw StateError('网络不可用');
        }),
      ),
    );
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('my-turns-error')), findsOneWidget);
    expect(find.textContaining('网络不可用'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(calls, 1);

    // 点「重试」再拉一次（仍失败，但不应崩溃）。
    await t.tap(find.text('重试'));
    await t.pumpAndSettle();
    expect(calls, 2);
    expect(find.byKey(const ValueKey('my-turns-error')), findsOneWidget);
  });
}
