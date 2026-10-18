import 'dart:async';

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
    Future<List<ChatTurnSummary>> Function(String)? search,
    List<String>? searchCalls,
    Object? searchError,
    List<ChatTurnSummary>? searchItems,
    Duration debounce = kMyTurnsSearchDebounce,
  }) => MaterialApp(
    home: MyTurnsPage(
      initialFilter: initialFilter,
      groupLabel: groupLabel,
      onOpenTurn: onOpenTurn,
      debounce: debounce,
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
      search: search == null
          ? null
          : (query) {
              searchCalls?.add(query);
              if (searchError != null) {
                return Future<List<ChatTurnSummary>>.error(searchError);
              }
              return search(query);
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

  // =========================================================================
  group('关键词搜索（issue #18）', () {
    /// 只造搜索回调用例需要的页面（列表为空，避免干扰）。
    Widget searchHost({
      required List<String> searchCalls,
      List<ChatTurnSummary>? searchItems,
      Object? searchError,
      Future<List<ChatTurnSummary>> Function(String)? search,
      List<FetchArgs>? calls,
    }) => host(
      calls: calls,
      searchCalls: searchCalls,
      searchItems: searchItems,
      searchError: searchError,
      search: search ?? (_) async => searchItems ?? const <ChatTurnSummary>[],
    );

    testWidgets('未注入 search 时不渲染搜索框（不是禁用）', (t) async {
      await t.pumpWidget(host(items: [_turn()]));
      await t.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('my-turns-search-field')),
        findsNothing,
        reason: '与 GoalHistoryPanel 的 onSwitch 同一约定：不渲染点了没反应的入口',
      );
    });

    testWidgets('注入 search 后渲染搜索框', (t) async {
      await t.pumpWidget(searchHost(searchCalls: []));
      await t.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('my-turns-search-field')),
        findsOneWidget,
      );
    });

    testWidgets('输入后 300ms 内不发请求，超时才发（防抖）', (t) async {
      final searchCalls = <String>[];
      await t.pumpWidget(searchHost(searchCalls: searchCalls));
      await t.pumpAndSettle();

      await t.enterText(
        find.byKey(const ValueKey('my-turns-search-field')),
        '报错',
      );
      // 还没到防抖时长。
      await t.pump(const Duration(milliseconds: 200));
      expect(searchCalls, isEmpty, reason: 'LIKE 是全表扫描，逐字符发请求会白打多次');

      // 再走 150ms（累计 350ms > 300ms）。
      await t.pump(const Duration(milliseconds: 150));
      expect(searchCalls, ['报错']);
    });

    testWidgets('连续输入只发最后一次（防抖真的取消了前一次）', (t) async {
      final searchCalls = <String>[];
      await t.pumpWidget(searchHost(searchCalls: searchCalls));
      await t.pumpAndSettle();

      final field = find.byKey(const ValueKey('my-turns-search-field'));
      await t.enterText(field, '报');
      await t.pump(const Duration(milliseconds: 100));
      await t.enterText(field, '报错');
      await t.pump(const Duration(milliseconds: 100));
      await t.enterText(field, '报错排查');
      await t.pump(const Duration(milliseconds: 400));

      expect(searchCalls, ['报错排查']);
    });

    testWidgets('搜索结果替换列表（不再展示列表项）', (t) async {
      await t.pumpWidget(
        host(
          items: [_turn(inputPreview: '列表里的项')],
          searchCalls: [],
          search: (_) async => [_turn(turnId: 'hit_1', inputPreview: '命中的项')],
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('列表里的项'), findsOneWidget);

      await t.enterText(
        find.byKey(const ValueKey('my-turns-search-field')),
        '命中',
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();

      expect(find.text('命中的项'), findsOneWidget);
      expect(find.text('列表里的项'), findsNothing);
      expect(
        find.byKey(const ValueKey('my-turns-search-list')),
        findsOneWidget,
      );
    });

    testWidgets('清空输入回到列表模式：重新调 fetch，不再调 search', (t) async {
      final calls = <FetchArgs>[];
      final searchCalls = <String>[];
      await t.pumpWidget(
        host(
          items: [_turn(inputPreview: '列表里的项')],
          calls: calls,
          searchCalls: searchCalls,
          search: (_) async => [_turn(turnId: 'hit_1', inputPreview: '命中的项')],
        ),
      );
      await t.pumpAndSettle();
      expect(calls, hasLength(1));

      final field = find.byKey(const ValueKey('my-turns-search-field'));
      await t.enterText(field, '命中');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(searchCalls, hasLength(1));

      // 清空（用 suffix 清除按钮，与真实交互一致）。
      await t.tap(find.byKey(const ValueKey('my-turns-search-clear')));
      await t.pumpAndSettle();

      expect(calls, hasLength(2), reason: '回到列表模式要重拉列表（否则看到的是上次列表的旧快照）');
      expect(searchCalls, hasLength(1), reason: '清空不是「搜空串」');
      expect(find.text('列表里的项'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('my-turns-search-hint')),
        findsNothing,
        reason: '回到列表模式后不应还挂着「搜索时筛选不生效」的提示',
      );
    });

    testWidgets('清空输入会让在途响应失效（否则旧结果会把列表又拽回去）', (t) async {
      final completers = <String, Completer<List<ChatTurnSummary>>>{};
      final searchCalls = <String>[];
      await t.pumpWidget(
        host(
          items: [_turn(inputPreview: '列表里的项')],
          searchCalls: searchCalls,
          search: (q) =>
              (completers[q] = Completer<List<ChatTurnSummary>>()).future,
        ),
      );
      await t.pumpAndSettle();

      final field = find.byKey(const ValueKey('my-turns-search-field'));
      await t.enterText(field, '报错');
      await t.pump(const Duration(milliseconds: 400));
      expect(searchCalls, ['报错']);

      // 清空输入（在途请求还没回来）。
      await t.tap(find.byKey(const ValueKey('my-turns-search-clear')));
      await t.pumpAndSettle();
      expect(find.text('列表里的项'), findsOneWidget);

      // 旧请求这时才返回——不能把列表模式又拽回搜索结果。
      completers['报错']!.complete([
        _turn(turnId: 'hit_1', inputPreview: '迟到的命中项'),
      ]);
      await t.pumpAndSettle();

      expect(find.text('迟到的命中项'), findsNothing);
      expect(find.text('列表里的项'), findsOneWidget);
    });

    testWidgets('旧响应不覆盖新结果（_searchSeq 序号守卫）', (t) async {
      // 网络抖动下完全可能：先发的「报」后返回。无守卫时它会覆盖「报错」的
      // 结果——列表显示「报」的命中，而输入框里写着「报错」。
      final completers = <String, Completer<List<ChatTurnSummary>>>{};
      final searchCalls = <String>[];
      await t.pumpWidget(
        host(
          searchCalls: searchCalls,
          search: (q) =>
              (completers[q] = Completer<List<ChatTurnSummary>>()).future,
        ),
      );
      await t.pumpAndSettle();

      final field = find.byKey(const ValueKey('my-turns-search-field'));
      await t.enterText(field, '报');
      await t.pump(const Duration(milliseconds: 400));
      await t.enterText(field, '报错');
      await t.pump(const Duration(milliseconds: 400));
      expect(searchCalls, ['报', '报错']);

      // 「报错」（后发）先返回。
      completers['报错']!.complete([
        _turn(turnId: 'hit_b', inputPreview: '报错的命中项'),
      ]);
      await t.pumpAndSettle();
      expect(find.text('报错的命中项'), findsOneWidget);

      // 「报」（先发）后返回——必须被丢弃。
      completers['报']!.complete([
        _turn(turnId: 'hit_a', inputPreview: '报的命中项'),
      ]);
      await t.pumpAndSettle();

      expect(
        find.text('报的命中项'),
        findsNothing,
        reason: '先发后到的响应覆盖了后发的结果，列表与输入框不一致',
      );
      expect(find.text('报错的命中项'), findsOneWidget);
    });

    testWidgets('搜索模式下筛选器被禁用并给出可见提示', (t) async {
      // 服务端 `/me/turns/search` 只认 q/limit。不禁用+提示的话，用户会以为
      // 「近 30 天 / 只看失败」仍然生效，而列表其实是全量关键字命中。
      final calls = <FetchArgs>[];
      await t.pumpWidget(
        host(calls: calls, searchCalls: [], search: (_) async => []),
      );
      await t.pumpAndSettle();

      // 列表模式：筛选器可用，无提示。
      expect(
        t
            .widget<ChoiceChip>(find.byKey(const ValueKey('my-turns-days-30')))
            .onSelected,
        isNotNull,
      );
      expect(find.byKey(const ValueKey('my-turns-search-hint')), findsNothing);

      await t.enterText(
        find.byKey(const ValueKey('my-turns-search-field')),
        '报错',
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();

      // 搜索模式：时间窗 chip 禁用。
      expect(
        t
            .widget<ChoiceChip>(find.byKey(const ValueKey('my-turns-days-30')))
            .onSelected,
        isNull,
        reason: '服务端不认 days，留着可点会让用户以为筛了',
      );
      // 两个下拉也禁用。
      expect(
        t
            .widget<DropdownButton<TurnSource?>>(
              find.byKey(const ValueKey('my-turns-source')),
            )
            .onChanged,
        isNull,
      );
      expect(
        t
            .widget<DropdownButton<String?>>(
              find.byKey(const ValueKey('my-turns-status')),
            )
            .onChanged,
        isNull,
      );
      // 并且有可见提示（只禁用不解释，用户不知道「为什么灰了」）。
      expect(
        find.byKey(const ValueKey('my-turns-search-hint')),
        findsOneWidget,
      );
      expect(find.textContaining('筛选条件不生效'), findsOneWidget);
      // 搜索过程中不应触发列表请求。
      expect(calls, hasLength(1));
    });

    testWidgets('搜索模式下预筛对话 chip 也不可删（服务端不认 group_id）', (t) async {
      await t.pumpWidget(
        host(
          initialFilter: const MyTurnsFilter(groupId: 'grp_x'),
          groupLabel: '团队周报',
          searchCalls: [],
          search: (_) async => [],
        ),
      );
      await t.pumpAndSettle();

      await t.enterText(
        find.byKey(const ValueKey('my-turns-search-field')),
        '报错',
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();

      expect(
        t
            .widget<InputChip>(
              find.byKey(const ValueKey('my-turns-group-chip')),
            )
            .onDeleted,
        isNull,
      );
    });

    testWidgets('搜索空结果文案点名关键词（不说「最近没有轮次记录」）', (t) async {
      await t.pumpWidget(
        host(searchCalls: [], search: (_) async => const <ChatTurnSummary>[]),
      );
      await t.pumpAndSettle();

      await t.enterText(
        find.byKey(const ValueKey('my-turns-search-field')),
        '不存在的词',
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('my-turns-search-empty')),
        findsOneWidget,
      );
      // 文案里要点名关键词（搜的什么、没搜到）。
      // 必须限定在空态子树上：输入框自己也含这个词。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('my-turns-search-empty')),
          matching: find.textContaining('不存在的词'),
        ),
        findsOneWidget,
      );
      expect(find.text('最近没有轮次记录'), findsNothing, reason: '列表空态文案会让用户以为数据丢了');
    });

    testWidgets('搜索失败展示错误与重试（重试重跑搜索而不是拉列表）', (t) async {
      final calls = <FetchArgs>[];
      final searchCalls = <String>[];
      await t.pumpWidget(
        host(
          calls: calls,
          searchCalls: searchCalls,
          searchError: StateError('搜索不可用'),
          search: (_) async => const <ChatTurnSummary>[],
        ),
      );
      await t.pumpAndSettle();

      await t.enterText(
        find.byKey(const ValueKey('my-turns-search-field')),
        '报错',
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('my-turns-search-error')),
        findsOneWidget,
      );
      expect(find.textContaining('搜索不可用'), findsOneWidget);

      await t.tap(find.text('重试'));
      await t.pumpAndSettle();

      expect(searchCalls, hasLength(2));
      expect(calls, hasLength(1), reason: '重试应重跑搜索，而不是回到列表');
    });

    testWidgets('回车立即搜索，不等防抖', (t) async {
      final searchCalls = <String>[];
      await t.pumpWidget(searchHost(searchCalls: searchCalls));
      await t.pumpAndSettle();

      await t.enterText(
        find.byKey(const ValueKey('my-turns-search-field')),
        '报错',
      );
      // 不等 300ms，直接提交。
      await t.testTextInput.receiveAction(TextInputAction.search);
      await t.pumpAndSettle();

      expect(searchCalls, ['报错']);
    });

    testWidgets('AppBar 刷新在搜索模式下重跑搜索（不是拉列表）', (t) async {
      final calls = <FetchArgs>[];
      final searchCalls = <String>[];
      await t.pumpWidget(
        host(
          calls: calls,
          searchCalls: searchCalls,
          search: (_) async => const <ChatTurnSummary>[],
        ),
      );
      await t.pumpAndSettle();

      await t.enterText(
        find.byKey(const ValueKey('my-turns-search-field')),
        '报错',
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(searchCalls, hasLength(1));

      await t.tap(find.byKey(const ValueKey('my-turns-refresh')));
      await t.pumpAndSettle();

      expect(searchCalls, hasLength(2));
      expect(calls, hasLength(1));
    });
  });
}
