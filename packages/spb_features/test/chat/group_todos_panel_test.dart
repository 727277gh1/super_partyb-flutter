import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// [GroupTodosPanel] 的 widget 测试。
void main() {
  ConfirmationItem conf(
    String id,
    String turnId, {
    String question = '是否继续？',
    bool resolved = false,
    DateTime? createdAt,
    String confirmationId = '',
    String groupId = 'grp_1',
  }) => ConfirmationItem(
    id: id,
    createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
    turnId: turnId,
    question: question,
    resolved: resolved,
    confirmationId: confirmationId.isEmpty ? 'cf_$id' : confirmationId,
    groupId: groupId,
  );

  UserMessageItem userMsg(String turnId, String text, {DateTime? createdAt}) =>
      UserMessageItem(
        id: 'u_$turnId',
        createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
        turnId: turnId,
        text: text,
      );

  TurnGroup turn(String turnId, List<ConversationItem> items) =>
      TurnGroup(turnId: turnId, items: items);

  Future<void> pumpPanel(
    WidgetTester tester, {
    required List<TurnGroup> turns,
    void Function(String groupId, String confirmationId, String option)?
    onResolveConfirmation,
    Set<String> resolvingIds = const {},
    bool showHeader = true,
    Object? reloadKey,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupTodosPanel(
            turns: turns,
            onResolveConfirmation: onResolveConfirmation,
            resolvingIds: resolvingIds,
            showHeader: showHeader,
            reloadKey: reloadKey,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('空态', () {
    testWidgets('无待办时显示空提示', (tester) async {
      await pumpPanel(tester, turns: const []);

      expect(find.byKey(const ValueKey('todos-empty')), findsOneWidget);
      expect(find.text('没有待处理的确认'), findsOneWidget);
    });

    testWidgets('所有确认都已解决时不显示（pendingConfirmations 过滤）', (tester) async {
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [conf('c1', 't1', resolved: true)]),
        ],
      );

      expect(find.byKey(const ValueKey('todos-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('todos-list')), findsNothing);
    });

    testWidgets('轮次无确认卡时也被过滤（不渲染空轮次卡片）', (tester) async {
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [userMsg('t1', '你好')]),
        ],
      );

      // 只有用户消息、没有确认卡的轮次不显示。
      expect(find.byKey(const ValueKey('todos-empty')), findsOneWidget);
    });
  });

  group('渲染', () {
    testWidgets('显示头部与轮次计数', (tester) async {
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [userMsg('t1', '写文档'), conf('c1', 't1')]),
          turn('t2', [userMsg('t2', '跑测试'), conf('c2', 't2')]),
        ],
      );

      expect(find.text('待处理'), findsOneWidget);
      expect(find.text('2 轮'), findsOneWidget);
    });

    testWidgets('showHeader=false 时不渲染标题行', (tester) async {
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [conf('c1', 't1')]),
        ],
        showHeader: false,
      );

      expect(find.text('待处理'), findsNothing);
      // 卡片仍然渲染。
      expect(find.text('需要你的确认'), findsOneWidget);
    });

    testWidgets('轮次头显示用户输入摘要与待办计数', (tester) async {
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [userMsg('t1', '帮我写文档'), conf('c1', 't1')]),
        ],
      );

      expect(find.text('帮我写文档'), findsOneWidget);
      // 一个待办。
      expect(find.text('1'), findsWidgets);
    });

    testWidgets('无用户输入时轮次头显示「（无输入）」', (tester) async {
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [conf('c1', 't1')]),
        ],
      );

      expect(find.text('（无输入）'), findsOneWidget);
    });

    testWidgets('确认卡复用 ConfirmationCard', (tester) async {
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [conf('c1', 't1', question: '是否部署到生产？')]),
        ],
      );

      expect(find.text('是否部署到生产？'), findsOneWidget);
      expect(find.text('需要你的确认'), findsOneWidget);
    });
  });

  group('折叠/展开', () {
    testWidgets('点击轮次头折叠/展开', (tester) async {
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [conf('c1', 't1', question: '确认内容')]),
        ],
      );

      // 默认展开：确认卡可见。
      expect(find.text('确认内容'), findsOneWidget);

      // 点头部折叠。
      await tester.tap(find.byKey(const ValueKey('todo-turn-header-t1')));
      await tester.pumpAndSettle();

      expect(find.text('确认内容'), findsNothing);
    });

    testWidgets('多个轮次独立折叠', (tester) async {
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [userMsg('t1', 'Q1'), conf('c1', 't1', question: 'C1?')]),
          turn('t2', [userMsg('t2', 'Q2'), conf('c2', 't2', question: 'C2?')]),
        ],
      );

      // 折叠 t1。
      await tester.tap(find.byKey(const ValueKey('todo-turn-header-t1')));
      await tester.pumpAndSettle();

      expect(find.text('C1?'), findsNothing);
      expect(find.text('C2?'), findsOneWidget);
    });
  });

  group('resolve 动作', () {
    testWidgets('点确认按钮触发注入的回调', (tester) async {
      final calls = <(String, String, String)>[];
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [conf('c1', 't1', groupId: 'grp_1')]),
        ],
        onResolveConfirmation: (g, cid, opt) => calls.add((g, cid, opt)),
      );

      // 点默认按钮「继续」。
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();

      expect(calls, [('grp_1', 'cf_c1', '继续')]);
    });

    testWidgets('提交中时按钮禁用（防重复点击）', (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupTodosPanel(
              turns: [
                turn('t1', [conf('c1', 't1')]),
              ],
              onResolveConfirmation: (g, cid, opt) => calls.add(opt),
              resolvingIds: {'cf_c1'},
            ),
          ),
        ),
      );
      // busy 时有无限动画的 CircularProgressIndicator，不能用 pumpAndSettle。
      await tester.pump();

      // busy 时按钮被禁用，不应有点击。
      await tester.tap(find.text('继续'), warnIfMissed: false);
      await tester.pump();

      expect(calls, isEmpty);
      expect(find.text('提交中…'), findsOneWidget);
    });

    testWidgets('canResolve 为 false（缺 confirmationId）时按钮禁用', (tester) async {
      final calls = <String>[];
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [
            ConfirmationItem(
              id: 'c1',
              createdAt: DateTime.utc(2026, 1, 1),
              turnId: 't1',
              question: '无 id 的异常载荷',
              confirmationId: '',
              groupId: 'grp_1',
            ),
          ]),
        ],
        onResolveConfirmation: (g, cid, opt) => calls.add(opt),
      );

      await tester.tap(find.text('继续'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(calls, isEmpty, reason: '缺 confirmationId 不应退化用事件 id 去试');
    });
  });

  group('reloadKey', () {
    testWidgets('切换 reloadKey 清空折叠状态', (tester) async {
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [conf('c1', 't1')]),
        ],
        reloadKey: 'group_a',
      );

      // 折叠。
      await tester.tap(find.byKey(const ValueKey('todo-turn-header-t1')));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmationCard), findsNothing);

      // 切换 reloadKey：折叠清空 → 重新展开。
      await pumpPanel(
        tester,
        turns: [
          turn('t1', [conf('c1', 't1')]),
        ],
        reloadKey: 'group_b',
      );

      expect(find.byType(ConfirmationCard), findsOneWidget, reason: '换对话后折叠重置');
    });
  });
}
