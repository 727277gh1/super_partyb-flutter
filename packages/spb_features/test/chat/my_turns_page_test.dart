import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_models/spb_models.dart';
import 'package:spb_features/spb_features.dart';

/// [MyTurnsPage] 的渲染、筛选与交互测试。
///
/// 页面纯 UI：数据拉取靠注入回调，不发起真实网络（无头环境）。
///
/// ## 这个测试防的是什么
///
/// 筛选参数最终要变成服务端 `GET /me/turns?days=&source=&status=&group_id=`
/// 的 query。漏传、传错值都**不会报错**——服务端只会返回未过滤的结果，
/// 表现为「选了筛选条件但列表没变」，用户以为没有匹配记录。故这里逐项钉住
/// 「选了 X 之后注入的 fetch 收到什么」。
ChatTurnSummary _turn({
  String turnId = 'turn_1',
  String groupId = 'grp_1',
  String? groupTitle = '测试对话',
  String inputPreview = '帮我看看这个报错',
  String status = 'completed',
  TurnSource source = TurnSource.chat,
  bool hasError = false,
}) => ChatTurnSummary(
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

/// 一次 fetch 调用收到的具名参数（与 [FetchMyTurns] 的签名一一对应）。
typedef FetchArgs = ({
  int? days,
  String? status,
  String? source,
  String? groupId,
});

void main() {
  /// 造一个记录调用的页面。`calls` 为空时仍可正常渲染。
  Widget host({
    List<ChatTurnSummary>? items,
    Object? error,
    void Function(String groupId, String turnId)? onOpenTurn,
    MyTurnsFilter initialFilter = const MyTurnsFilter(),
    String? groupLabel,
    List<FetchArgs>? calls,
  }) => MaterialApp(
    home: MyTurnsPage(
      initialFilter: initialFilter,
      groupLabel: groupLabel,
      onOpenTurn: onOpenTurn,
      fetch: ({days, status, source, groupId}) async {
        calls?.add((
          days: days,
          status: status,
          source: source,
          groupId: groupId,
        ));
        if (error != null) throw error;
        return items ?? const <ChatTurnSummary>[];
      },
    ),
  );

  testWidgets('最近轮次列表渲染状态徽标、来源、摘要与时间', (t) async {
    await t.pumpWidget(
      host(
        items: [
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

  testWidgets('点击轮次跳转携带 groupId + turnId 两个参数（issue #19）', (t) async {
    // ## 这个测试防的是什么
    //
    // 回调签名曾经是 `void Function(String groupId)`——**turnId 被丢弃**，
    // 调用方无法拉取该轮详情（只能跳到对话列表）。签名改宽后，若调用处仍只传
    // groupId，编译期不会报错（多余参数在 Dart 里是编译错误，但**少**传会——
    // 故这里断言两个值都真的到位，而不是只看「回调被调了」）。
    final opened = <(String, String)>[];
    await t.pumpWidget(
      host(
        items: [
          _turn(turnId: 'turn_a', groupId: 'grp_x'),
          _turn(turnId: 'turn_b', groupId: 'grp_y', inputPreview: '整理周报'),
        ],
        onOpenTurn: (gid, tid) => opened.add((gid, tid)),
      ),
    );
    await t.pumpAndSettle();

    await t.tap(find.text('帮我看看这个报错'));
    await t.pump();
    expect(opened, [('grp_x', 'turn_a')]);

    await t.tap(find.text('整理周报'));
    await t.pump();
    expect(opened, [('grp_x', 'turn_a'), ('grp_y', 'turn_b')]);
  });

  testWidgets('未注入 onOpenTurn 时行不可点（不渲染 chevron）', (t) async {
    await t.pumpWidget(host(items: [_turn()]));
    await t.pumpAndSettle();

    expect(
      t
          .widget<ListTile>(
            // key 挂在 `_TurnTile` 上，ListTile 是它的子项。
            find.descendant(
              of: find.byKey(const ValueKey('my-turn-turn_1')),
              matching: find.byType(ListTile),
            ),
          )
          .onTap,
      isNull,
    );
  });

  testWidgets('空态友好提示', (t) async {
    await t.pumpWidget(host(items: const []));
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('my-turns-empty')), findsOneWidget);
    expect(find.text('最近没有轮次记录'), findsOneWidget);
  });

  testWidgets('错误态展示原因与重试', (t) async {
    final calls = <FetchArgs>[];
    await t.pumpWidget(host(error: StateError('网络不可用'), calls: calls));
    await t.pumpAndSettle();

    expect(find.byKey(const ValueKey('my-turns-error')), findsOneWidget);
    expect(find.textContaining('网络不可用'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(calls, hasLength(1));

    // 点「重试」再拉一次（仍失败，但不应崩溃）。
    await t.tap(find.text('重试'));
    await t.pumpAndSettle();
    expect(calls, hasLength(2));
    expect(find.byKey(const ValueKey('my-turns-error')), findsOneWidget);
  });

  group('筛选参数透传（漏传不报错，只是筛选静默失效）', () {
    testWidgets('首次拉取带默认 days=7，其余不筛（null）', (t) async {
      final calls = <FetchArgs>[];
      await t.pumpWidget(host(calls: calls));
      await t.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.days, kMyTurnsDefaultDays);
      // null = 不发该 query 参数（发空串会被服务端当「筛空串」，语义不同）。
      expect(calls.single.source, isNull);
      expect(calls.single.status, isNull);
      expect(calls.single.groupId, isNull);
    });

    testWidgets('选「30 天」后重拉带 days=30', (t) async {
      final calls = <FetchArgs>[];
      await t.pumpWidget(host(calls: calls));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('my-turns-days-30')));
      await t.pumpAndSettle();

      expect(calls, hasLength(2));
      expect(calls.last.days, 30);
    });

    testWidgets('选来源「工具」发出 wire 值 tool_agent（不是枚举名 toolAgent）', (t) async {
      // ⚠️ 回归锁：枚举名 `toolAgent` 与 wire 值 `tool_agent` 不同名。
      // 写成 `source.name` 会发出 `toolAgent`，服务端 `switch source` 落不到
      // `tool_agent` 分支 → 筛选静默失效（返回未过滤结果，不报错）。
      final calls = <FetchArgs>[];
      await t.pumpWidget(host(calls: calls));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('my-turns-source')));
      await t.pumpAndSettle();
      await t.tap(find.text('工具').last);
      await t.pumpAndSettle();

      expect(calls.last.source, 'tool_agent');
      expect(calls.last.days, kMyTurnsDefaultDays, reason: '不应重置时间窗');
    });

    testWidgets('选状态「已取消」发出英式 cancelled（不是美式 canceled）', (t) async {
      // ⚠️ 回归锁：`domain.go` 的 `TurnStatusCanceled` 与 schema CHECK 都是
      // 英式 `cancelled`。发美式会被服务端当「筛一个不存在的值」→ 空结果。
      final calls = <FetchArgs>[];
      await t.pumpWidget(host(calls: calls));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('my-turns-status')));
      await t.pumpAndSettle();
      await t.tap(find.text('已取消').last);
      await t.pumpAndSettle();

      expect(calls.last.status, 'cancelled');
    });

    testWidgets('选回「全部来源」清掉筛选（发 null，不是空串）', (t) async {
      final calls = <FetchArgs>[];
      await t.pumpWidget(host(calls: calls));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('my-turns-source')));
      await t.pumpAndSettle();
      await t.tap(find.text('习惯').last);
      await t.pumpAndSettle();
      expect(calls.last.source, 'habit');

      await t.tap(find.byKey(const ValueKey('my-turns-source')));
      await t.pumpAndSettle();
      await t.tap(find.text('全部来源').last);
      await t.pumpAndSettle();

      expect(calls.last.source, isNull);
    });

    testWidgets('重复选同一个值不重拉（无变化的请求是噪音）', (t) async {
      final calls = <FetchArgs>[];
      await t.pumpWidget(host(calls: calls));
      await t.pumpAndSettle();

      // 默认已是 7 天，再点一次不应触发请求。
      await t.tap(find.byKey(const ValueKey('my-turns-days-7')));
      await t.pumpAndSettle();

      expect(calls, hasLength(1));
    });
  });

  group('预筛某个对话（initialFilter.groupId）', () {
    testWidgets('首次拉取即带 groupId，并显示可清除的对话 chip', (t) async {
      final calls = <FetchArgs>[];
      await t.pumpWidget(
        host(
          calls: calls,
          initialFilter: const MyTurnsFilter(days: 30, groupId: 'grp_x'),
          groupLabel: '团队周报',
        ),
      );
      await t.pumpAndSettle();

      expect(calls.single.days, 30);
      expect(calls.single.groupId, 'grp_x');
      // chip 用注入的标题而不是裸 id。
      expect(find.text('仅看：团队周报'), findsOneWidget);
    });

    testWidgets('清除 chip 后重拉不带 groupId', (t) async {
      final calls = <FetchArgs>[];
      await t.pumpWidget(
        host(
          calls: calls,
          initialFilter: const MyTurnsFilter(groupId: 'grp_x'),
          groupLabel: '团队周报',
        ),
      );
      await t.pumpAndSettle();

      await t.tap(
        find.descendant(
          of: find.byKey(const ValueKey('my-turns-group-chip')),
          matching: find.byIcon(Icons.close),
        ),
      );
      await t.pumpAndSettle();

      expect(calls, hasLength(2));
      expect(calls.last.groupId, isNull);
      expect(find.byKey(const ValueKey('my-turns-group-chip')), findsNothing);
    });

    testWidgets('未预筛时不显示对话 chip（本页没有对话选择器）', (t) async {
      await t.pumpWidget(host());
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey('my-turns-group-chip')), findsNothing);
    });

    testWidgets('无 groupLabel 时 chip 回落展示 id（不显示空白）', (t) async {
      await t.pumpWidget(
        host(initialFilter: const MyTurnsFilter(groupId: 'grp_raw')),
      );
      await t.pumpAndSettle();

      expect(find.text('仅看：grp_raw'), findsOneWidget);
    });
  });

  testWidgets('状态徽标接英式 cancelled（否则已取消会显示成已完成）', (t) async {
    await t.pumpWidget(host(items: [_turn(status: 'cancelled')]));
    await t.pumpAndSettle();

    expect(find.text('已取消'), findsOneWidget);
    expect(find.text('已完成'), findsNothing);
  });
}
