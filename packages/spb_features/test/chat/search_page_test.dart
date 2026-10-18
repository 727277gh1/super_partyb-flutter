import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 搜索页的交互测试。
///
/// ## 这个测试防的是什么
///
/// 搜索页有三个容易出错的地方，且都不会报错、只会表现成「看起来能用」：
///
/// 1. **防抖**：逐字符发请求会让「报错排查」打 4 次全表 LIKE 扫描；
/// 2. **在途响应乱序**：防抖挡不住已发出的请求，慢响应回来会覆盖新结果，
///    表现为「输入框是「报错」但列表是「报」的结果」；
/// 3. **空结果 vs 未搜索**：两者都显示空列表，若不区分，用户会以为
///    「搜了但没结果」和「还没搜」是同一件事。
void main() {
  Map<String, dynamic> hitJson({
    required String turnId,
    String groupId = 'grp_1',
    String groupTitle = '报错排查',
    String inputText = '帮我看一下这个报错',
  }) => {
    'turn_id': turnId,
    'group_id': groupId,
    'group_title': groupTitle,
    'input_text': inputText,
    'created_at': '2024-03-05T08:09:10Z',
    'agent_id': 'agt_1',
  };

  /// 记录每次搜索的查询词。
  late List<String> queries;
  late SearchChat search;

  /// 默认实现：对任何查询返回一条命中。
  void useSearch({
    List<ChatSearchHit> Function(String query)? hits,
    Future<List<ChatSearchHit>> Function(String query)? raw,
  }) {
    queries = [];
    search = (query, {int? limit}) async {
      queries.add(query);
      if (raw != null) return raw(query);
      final items =
          hits?.call(query) ?? [ChatSearchHit.fromJson(hitJson(turnId: 't1'))];
      return items;
    };
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    void Function(ChatSearchHit hit)? onOpenHit,
    Duration debounce = const Duration(milliseconds: 300),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          search: search,
          onOpenHit: onOpenHit,
          debounce: debounce,
        ),
      ),
    );
    await tester.pump();
  }

  /// 输入并等过防抖。
  Future<void> typeAndSettle(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('search-field')), text);
    await tester.pump();
    // 推进假时钟越过防抖 + 让 Future 落地。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  group('搜索页：输入与防抖', () {
    testWidgets('初始状态提示输入关键字（不是「没找到」）', (tester) async {
      useSearch();
      await pumpPage(tester);

      expect(find.text('输入关键字搜索消息内容'), findsOneWidget);
      expect(queries, isEmpty);
    });

    testWidgets('连打不逐字符发请求（防抖只发最后一次）', (tester) async {
      useSearch();
      await pumpPage(tester);

      // 模拟连打：每次间隔短于防抖时长。
      for (final t in ['报', '报错', '报错排']) {
        await tester.enterText(find.byKey(const ValueKey('search-field')), t);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(queries, ['报错排'], reason: '逐字符发请求会对无法走索引的 LIKE 查询打多次全表扫描');
    });

    testWidgets('停顿超过防抖时长才发请求', (tester) async {
      useSearch();
      await pumpPage(tester);

      await tester.enterText(find.byKey(const ValueKey('search-field')), '报错');
      await tester.pump(const Duration(milliseconds: 100));
      expect(queries, isEmpty, reason: '还没到防抖时间');

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(queries, ['报错']);
    });

    testWidgets('回车立即搜索（不等防抖）', (tester) async {
      useSearch();
      await pumpPage(tester);

      await tester.enterText(find.byKey(const ValueKey('search-field')), '报错');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      expect(queries, ['报错']);
    });

    testWidgets('点搜索按钮立即搜索', (tester) async {
      useSearch();
      await pumpPage(tester);

      await tester.enterText(find.byKey(const ValueKey('search-field')), '报错');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const ValueKey('search-submit')));
      await tester.pump();

      expect(queries, ['报错']);
    });

    testWidgets('查询词会被 trim', (tester) async {
      useSearch();
      await pumpPage(tester);

      await typeAndSettle(tester, '  报错  ');

      expect(queries, ['报错']);
    });

    testWidgets('清空输入回到「未搜索」且不残留上次结果', (tester) async {
      useSearch();
      await pumpPage(tester);

      await typeAndSettle(tester, '报错');
      expect(find.text('帮我看一下这个报错'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('search-field')), '');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.text('输入关键字搜索消息内容'), findsOneWidget);
      expect(find.text('帮我看一下这个报错'), findsNothing);
      expect(queries, ['报错'], reason: '清空不该产生一次多余的往返');
    });

    testWidgets('纯空格视同清空（不搜索）', (tester) async {
      useSearch();
      await pumpPage(tester);

      await tester.enterText(find.byKey(const ValueKey('search-field')), '   ');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(queries, isEmpty);
      expect(find.text('输入关键字搜索消息内容'), findsOneWidget);
    });
  });

  group('搜索页：结果展示', () {
    testWidgets('展示 group_title 与命中片段', (tester) async {
      useSearch();
      await pumpPage(tester);

      await typeAndSettle(tester, '报错');

      expect(find.text('报错排查'), findsOneWidget);
      expect(find.textContaining('帮我看一下这个报错'), findsOneWidget);
    });

    testWidgets('group_title 为空时兜底展示（归档 group 取不到标题）', (tester) async {
      useSearch(
        hits: (_) => [
          ChatSearchHit.fromJson(hitJson(turnId: 't1', groupTitle: '')),
        ],
      );
      await pumpPage(tester);

      await typeAndSettle(tester, '报错');

      expect(find.text('（未命名对话）'), findsOneWidget);
    });

    testWidgets('多条命中都展示（同一对话可能命中多句）', (tester) async {
      useSearch(
        hits: (_) => [
          ChatSearchHit.fromJson(hitJson(turnId: 't1', inputText: '第一处报错')),
          ChatSearchHit.fromJson(hitJson(turnId: 't2', inputText: '第二处报错')),
        ],
      );
      await pumpPage(tester);

      await typeAndSettle(tester, '报错');

      expect(find.textContaining('第一处报错'), findsOneWidget);
      expect(find.textContaining('第二处报错'), findsOneWidget);
    });

    testWidgets('搜了但没结果 → 显示「没有找到 X」而非「输入关键字」', (tester) async {
      useSearch(hits: (_) => const []);
      await pumpPage(tester);

      await typeAndSettle(tester, '不存在的词');

      expect(find.text('没有找到「不存在的词」'), findsOneWidget);
      expect(
        find.text('输入关键字搜索消息内容'),
        findsNothing,
        reason: '「还没搜」与「搜了没结果」是两件事，混淆会让用户以为搜索没生效',
      );
    });

    testWidgets('命中项按 turn_id 有稳定 key（供点击定位）', (tester) async {
      useSearch();
      await pumpPage(tester);

      await typeAndSettle(tester, '报错');

      expect(find.byKey(const ValueKey('search-hit-t1')), findsOneWidget);
    });
  });

  group('搜索页：点击跳转', () {
    testWidgets('点击命中项回调携带该 hit（含 groupId）', (tester) async {
      final opened = <ChatSearchHit>[];
      useSearch();
      await pumpPage(tester, onOpenHit: opened.add);

      await typeAndSettle(tester, '报错');
      await tester.tap(find.byKey(const ValueKey('search-hit-t1')));
      await tester.pump();

      expect(opened, hasLength(1));
      expect(opened.single.groupId, 'grp_1');
      expect(opened.single.turnId, 't1');
    });

    testWidgets('未注入回调时条目不可点（不崩溃）', (tester) async {
      useSearch();
      await pumpPage(tester);

      await typeAndSettle(tester, '报错');
      await tester.tap(find.byKey(const ValueKey('search-hit-t1')));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('搜索页：在途响应乱序', () {
    testWidgets('慢的旧响应回来不覆盖新结果', (tester) async {
      // 「报」的响应挂起，「报错」的响应立刻返回。
      final slow = Completer<List<ChatSearchHit>>();
      queries = [];
      search = (query, {int? limit}) {
        queries.add(query);
        if (query == '报') return slow.future;
        return Future.value([
          ChatSearchHit.fromJson(hitJson(turnId: 't_new', inputText: '新结果')),
        ]);
      };
      await pumpPage(tester);

      // 第一次搜索：发出后挂起。
      await tester.enterText(find.byKey(const ValueKey('search-field')), '报');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(queries, ['报']);

      // 第二次搜索：立刻返回。
      await tester.enterText(find.byKey(const ValueKey('search-field')), '报错');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.textContaining('新结果'), findsOneWidget);

      // 旧响应此时才回来——不得覆盖。
      slow.complete([
        ChatSearchHit.fromJson(hitJson(turnId: 't_old', inputText: '旧结果')),
      ]);
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('旧结果'),
        findsNothing,
        reason: '防抖挡不住已发出的请求；乱序覆盖会让列表与输入框不一致',
      );
      expect(find.textContaining('新结果'), findsOneWidget);
    });
  });

  group('搜索页：错误处理', () {
    testWidgets('搜索失败展示错误与重试', (tester) async {
      queries = [];
      search = (query, {int? limit}) async {
        queries.add(query);
        throw const NetworkError('连接超时');
      };
      await pumpPage(tester);

      await typeAndSettle(tester, '报错');

      expect(find.text('连接超时'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(
        find.text('输入关键字搜索消息内容'),
        findsNothing,
        reason: '失败时不该同时显示「还没搜」的空状态',
      );
    });

    testWidgets('重试按钮重发同一查询', (tester) async {
      var fail = true;
      queries = [];
      search = (query, {int? limit}) async {
        queries.add(query);
        if (fail) throw const NetworkError('连接超时');
        return [ChatSearchHit.fromJson(hitJson(turnId: 't1'))];
      };
      await pumpPage(tester);

      await typeAndSettle(tester, '报错');
      fail = false;
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump();

      expect(queries, ['报错', '报错']);
      expect(find.textContaining('帮我看一下这个报错'), findsOneWidget);
    });
  });

  group('搜索页：命中高亮', () {
    testWidgets('命中片段按查询词高亮（大小写不敏感，与服务端 LIKE 一致）', (tester) async {
      useSearch(
        hits: (_) => [
          ChatSearchHit.fromJson(hitJson(turnId: 't1', inputText: 'todo 事项待办')),
        ],
      );
      await pumpPage(tester);

      await typeAndSettle(tester, 'Todo');

      // 高亮用 TextSpan 实现，故检查富文本里存在带高亮样式的片段。
      final richText = tester.widget<Text>(
        find
            .byWidgetPredicate(
              (w) => w is Text && w.textSpan != null && w.textSpan is TextSpan,
            )
            .first,
      );
      final spans = (richText.textSpan! as TextSpan).children!.cast<TextSpan>();
      final highlighted = spans.where((s) => s.style?.backgroundColor != null);
      expect(
        highlighted,
        isNotEmpty,
        reason:
            'SQLite LIKE 对 ASCII 大小写不敏感，客户端高亮必须一致，'
            '否则会出现「命中了但没有任何高亮」',
      );
      expect(highlighted.single.text, 'todo');
    });

    testWidgets('查询词含正则元字符时不抛异常（不做正则匹配）', (tester) async {
      useSearch(
        hits: (_) => [
          ChatSearchHit.fromJson(hitJson(turnId: 't1', inputText: 'a.b*c(d')),
        ],
      );
      await pumpPage(tester);

      await typeAndSettle(tester, '.*(');

      expect(tester.takeException(), isNull);
      expect(find.textContaining('a.b*c(d'), findsOneWidget);
    });
  });
}
