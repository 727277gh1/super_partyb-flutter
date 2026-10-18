import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 工作列表页测试。
///
/// ## 这个测试防的是什么
///
/// `listWorks` 返回的 `next_cursor` **名字是游标、值其实是 offset**
/// （服务端 `strconv.Itoa(offset + len(groups))`）。用 offset 分页时列表变动会
/// 让窗口移动、产生重复项——不去重会让 Flutter 因**重复 Key** 崩溃，而且这个
/// 崩溃发生在用户滚动时，很难复现定位。
///
/// 另有一条更隐蔽的：若整页都是重复项却仍带着 cursor，`_hasMore` 靠
/// 「本页条数」判定就会**无限翻页**（每次请求都成功、都加 0 条）。故必须用
/// 「本次新增数」判定。
void main() {
  Map<String, dynamic> workJson({
    required String id,
    String title = '做个报表',
    String status = 'running',
    String statusLabel = '运行中',
    int total = 3,
    int completed = 1,
    int pendingConfirmations = 0,
    String? latestSummary,
    String? goal,
  }) => {
    'id': id,
    'title': title,
    'goal': goal,
    'status': status,
    'status_label': statusLabel,
    'progress': {
      'total': total,
      'completed': completed,
      'percent': total == 0 ? 0 : (completed * 100 / total).round(),
    },
    'pending_confirmation_count': pendingConfirmations,
    'latest_summary': latestSummary,
    'latest_artifact': null,
    'created_at': '2024-03-05T08:09:10Z',
    'updated_at': '2024-03-05T08:09:12Z',
  };

  MiniappWork work(String id, {String status = 'running'}) =>
      MiniappWork.fromJson(workJson(id: id, status: status));

  /// 记录每次调用的 (status, cursor)，供断言分页参数。
  late List<(String, int?)> calls;
  late LoadMiniappWorks load;
  late List<MiniappWork> opened;

  void useStub(
    Future<MiniappWorkPage> Function(String status, int? cursor) impl,
  ) {
    calls = [];
    load = ({String status = 'active', int? cursor}) {
      calls.add((status, cursor));
      return impl(status, cursor);
    };
    opened = [];
  }

  /// ## 为什么要缩小视口才能测分页
  ///
  /// 触发「滚动到底部 → 加载更多」需要列表**真的能滚**（`maxScrollExtent > 0`）。
  /// 默认 800×600 视口下两张卡不溢出，`drag` 不产生任何滚动，滚动监听器永不
  /// 触发——测试会以「第二次请求没发生」失败，而根因是视口而不是分页逻辑。
  ///
  /// 但它**不能对所有用例都生效**：视口太小会把重试按钮、后续条目挤出屏幕，
  /// 那些用例又会因为「找不到控件」失败。故做成开关，只在分页用例里开。
  void useSmallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(600, 150);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WorksPage(loadWorks: load, onOpenWork: opened.add),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('渲染工作卡片：标题 / 状态名 / 进度 / 待确认', (tester) async {
    useStub(
      (_, _) async => MiniappWorkPage(
        items: [
          MiniappWork.fromJson(
            workJson(
              id: 'w1',
              title: '做个报表',
              pendingConfirmations: 2,
              latestSummary: '已抓取 3 个数据源',
              goal: '生成月度报表',
            ),
          ),
        ],
      ),
    );
    await pumpPage(tester);

    expect(find.text('做个报表'), findsOneWidget);
    // 状态名用服务端下发的 status_label（前端硬编码会漂移）。
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
    expect(find.textContaining('2 项待确认'), findsOneWidget);
    expect(find.text('已抓取 3 个数据源'), findsOneWidget);
    expect(find.text('生成月度报表'), findsOneWidget);
  });

  testWidgets('无工作时展示空态（区分「进行中」与「全部」）', (tester) async {
    useStub((_, _) async => const MiniappWorkPage(items: []));
    await pumpPage(tester);

    expect(find.byKey(const ValueKey('miniapp-works-empty')), findsOneWidget);
    expect(find.text('还没有进行中的工作'), findsOneWidget);
  });

  testWidgets('首屏加载中展示进度圈', (tester) async {
    final gate = Completer<MiniappWorkPage>();
    useStub((_, _) => gate.future);

    await tester.pumpWidget(MaterialApp(home: WorksPage(loadWorks: load)));
    await tester.pump();

    expect(find.byKey(const ValueKey('miniapp-works-loading')), findsOneWidget);

    gate.complete(const MiniappWorkPage(items: []));
    await tester.pump();
    await tester.pump();
  });

  testWidgets('加载失败展示错误与重试，且不静默成空态', (tester) async {
    var attempts = 0;
    useStub((_, _) async {
      attempts++;
      if (attempts == 1) throw const NetworkError('连接超时');
      return const MiniappWorkPage(items: []);
    });
    await pumpPage(tester);

    expect(find.byKey(const ValueKey('miniapp-works-error')), findsOneWidget);
    expect(find.textContaining('连接超时'), findsOneWidget);
    // 关键：不能显示成「还没有工作」——那会让用户以为真的没有工作。
    expect(find.byKey(const ValueKey('miniapp-works-empty')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('miniapp-works-retry')));
    await tester.pump();
    await tester.pump();

    expect(attempts, 2);
    expect(find.byKey(const ValueKey('miniapp-works-empty')), findsOneWidget);
  });

  testWidgets('分页：next_cursor 作为 offset 传给下一次请求', (tester) async {
    useSmallViewport(tester);
    useStub((status, cursor) async {
      if (cursor == null) {
        return MiniappWorkPage(
          items: [work('w1'), work('w2')],
          nextCursor: '2',
        );
      }
      return MiniappWorkPage(items: [work('w3')]);
    });

    await pumpPage(tester);
    expect(calls, [('active', null)]);

    // 触发滚动加载更多。
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    await tester.pump();

    expect(calls, [('active', null), ('active', 2)]);

    // 第三张卡已进入列表，但小视口下 ListView **惰性构建**、屏幕外的条目不
    // 在树上（`find` 找不到）。放大视口让三张卡都可见后再断言。
    tester.view.physicalSize = const Size(800, 1200);
    await tester.pump();
    expect(find.text('做个报表'), findsNWidgets(3));
  });

  testWidgets('offset 分页去重：重复项不会产生重复 Key（也不重复渲染）', (tester) async {
    useSmallViewport(tester);
    // ## 这个测试防的是什么
    //
    // offset 分页在列表变动时会返回已经见过的条目（窗口移动）。不去重会让
    // Flutter 抛「Duplicate GlobalKey」/ 重复 Key 崩溃。
    useStub((status, cursor) async {
      if (cursor == null) {
        return MiniappWorkPage(
          items: [work('w1'), work('w2')],
          nextCursor: '2',
        );
      }
      // 第二页里 w2 是重复项（窗口移动的典型表现）。
      return MiniappWorkPage(items: [work('w2'), work('w3')], nextCursor: '4');
    });

    await pumpPage(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    await tester.pump();

    // ⚠️ 必须先放大视口再断言：ListView **惰性构建**，小视口下屏幕外的条目
    // 根本不在树上，`find` 找不到——那样即使列表里真的有两张 w2 卡，断言
    // `findsOneWidget` 也会「通过」（因为只构建了一张）。实测：不去重时
    // 放大后 w2 出现 3 次，小视口下却只数到 1 次。
    tester.view.physicalSize = const Size(800, 2000);
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '重复 Key 会在这里崩');
    expect(find.byKey(const ValueKey('miniapp-work-w2')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniapp-work-w3')), findsOneWidget);
  });

  testWidgets('整页重复项时立即停止翻页（否则无限请求）', (tester) async {
    useSmallViewport(tester);
    // 服务端 cursor 只在 len(groups)==limit 时非空；若整页都是重复项却仍有
    // cursor，用「本页条数」判定 hasMore 会陷入无限翻页。
    //
    // ## 为什么要「上滚再下滚」而不是一直往下拖
    //
    // 滚动监听器只在**滚动事件**里触发。到达底部后列表不再变长（全是重复项），
    // 继续往下拖产生不了新的滚动量，监听器不再触发——于是「无限翻页」这个 bug
    // 根本不会被触发，测试会以「请求数没涨」通过。实测：一直往下拖 5 次，
    // 请求数停在 2；改成「上滚 400 再下滚 800」循环，请求数才会 2→4→6→8 地涨。
    var page = 0;
    useStub((status, cursor) async {
      page++;
      if (cursor == null) {
        return MiniappWorkPage(
          items: [for (var i = 0; i < 10; i++) work('w$i')],
          nextCursor: '10',
        );
      }
      // 第二页起全是重复项，但仍带着 cursor。
      return MiniappWorkPage(
        items: [for (var i = 0; i < 10; i++) work('w$i')],
        nextCursor: '${page * 10}',
      );
    });

    Future<void> cycle() async {
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pump();
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pump();
      await tester.pump();
    }

    await pumpPage(tester);

    // 反复上滚+下滚制造滚动事件。不能只拖一次——首屏列表比视口长得多，
    // 一次 drag 未必落到 `maxScrollExtent - viewportDimension` 的触发区内。
    for (var i = 0; i < 12; i++) {
      await cycle();
    }

    // ## 为什么断言「上界」而不是「等于某个值」
    //
    // 正确行为：第 1 页（10 条）→ 第 2 页（全重复）→ 发现新增 0 条 → 停止。
    // 共 **2** 次请求。之后无论滚多少次都不该再发。
    //
    // 错误行为（用「本页条数」判 hasMore）：每次滚动都再发一次，请求数随
    // 滚动次数线性增长。实测 12 轮 cycle 下会涨到 8+，故 `<= 2` 足以区分。
    //
    // 用上界而非精确值，是为了不依赖「drag 究竟在第几轮落入触发区」这个
    // 与实现无关的细节。
    expect(
      page,
      lessThanOrEqualTo(2),
      reason: '整页重复 = 已到尽头；按本页条数判 hasMore 会随滚动次数无限翻页',
    );
  });

  testWidgets('分页失败只提示底部、不清空已有列表', (tester) async {
    useSmallViewport(tester);
    useStub((status, cursor) async {
      if (cursor == null) {
        return MiniappWorkPage(items: [work('w1')], nextCursor: '1');
      }
      throw const NetworkError('连接超时');
    });

    await pumpPage(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    await tester.pump();

    // 已加载的条目必须还在（下一页失败不该让用户丢掉正在看的内容）。
    expect(find.byKey(const ValueKey('miniapp-work-w1')), findsOneWidget);
    expect(find.textContaining('加载更多失败'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('miniapp-works-more-retry')),
      findsOneWidget,
    );
  });

  testWidgets('切换状态过滤重新加载并重置分页', (tester) async {
    useStub((status, cursor) async {
      if (status == 'all') {
        return MiniappWorkPage(
          items: [
            work('w1'),
            work('archived1', status: 'archived'),
          ],
        );
      }
      return MiniappWorkPage(items: [work('w1')]);
    });

    await pumpPage(tester);
    expect(calls, [('active', null)]);

    await tester.tap(find.byKey(const ValueKey('miniapp-works-status-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部（含已归档）').last);
    await tester.pump();
    await tester.pump();

    // 重载后 cursor 必须重置为 null（否则会从旧 offset 开始，漏掉前面的）。
    expect(calls.last, ('all', null));
    expect(
      find.byKey(const ValueKey('miniapp-work-archived1')),
      findsOneWidget,
    );
  });

  testWidgets('点条目回调 onOpenWork（work.id 即 group id）', (tester) async {
    useStub((_, _) async => MiniappWorkPage(items: [work('grp_abc')]));
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('miniapp-work-grp_abc')));
    await tester.pump();

    expect(opened.single.id, 'grp_abc');
  });

  testWidgets('onOpenWork 为 null 时条目不可点击（只读用法）', (tester) async {
    useStub((_, _) async => MiniappWorkPage(items: [work('w1')]));

    await tester.pumpWidget(MaterialApp(home: WorksPage(loadWorks: load)));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('miniapp-work-w1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('miniapp-work-w1')));
    await tester.pump();
    // 没有 onOpenWork，点击不应抛异常。
    expect(tester.takeException(), isNull);
  });

  testWidgets('status_label 为空时回落原始 status（不显示空白徽标）', (tester) async {
    useStub(
      (_, _) async => MiniappWorkPage(
        items: [
          MiniappWork.fromJson(
            workJson(id: 'w1', status: 'brand_new', statusLabel: ''),
          ),
        ],
      ),
    );
    await pumpPage(tester);

    expect(find.text('brand_new'), findsOneWidget);
  });

  group('工作台：新建工作', () {
    testWidgets('未注入 onCreateWork 时不展示新建按钮（只读用法）', (tester) async {
      useStub((_, _) async => const MiniappWorkPage(items: []));
      await pumpPage(tester);

      expect(
        find.byKey(const ValueKey('miniapp-works-create')),
        findsNothing,
        reason: '没注入实现却展示按钮，点下去什么也不会发生',
      );
    });

    testWidgets('点新建 → 调用 onCreateWork 并刷新列表', (tester) async {
      // 断言「刷新」而不只是「回调被调」：不刷新的话用户看到的是旧列表，
      // 会以为新建没生效而反复点（服务端会建出一堆空工作）。
      useStub((_, _) async => MiniappWorkPage(items: [work('w1')]));
      var created = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: WorksPage(
            loadWorks: load,
            onOpenWork: opened.add,
            onCreateWork: () async {
              created++;
              return 'w_new';
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final before = calls.length;

      await tester.tap(find.byKey(const ValueKey('miniapp-works-create')));
      await tester.pump();
      await tester.pump();

      expect(created, 1, reason: '新建必须真的调 onCreateWork');
      expect(
        calls.length,
        greaterThan(before),
        reason: '新建后必须刷新列表，否则用户看不到刚建的工作',
      );
    });

    testWidgets('新建失败展示提示且不抛异常', (tester) async {
      useStub((_, _) async => const MiniappWorkPage(items: []));

      await tester.pumpWidget(
        MaterialApp(
          home: WorksPage(
            loadWorks: load,
            onCreateWork: () async => throw const HttpError(503, '服务不可用'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('miniapp-works-create')));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('新建工作失败'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '失败必须被捕获，不能让页面崩');
    });
  });
}
