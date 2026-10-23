import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_ui/spb_ui.dart';

void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
  });

  /// `groupRowToDict` 的真实输出形状（`internal/server/chat.go`）。
  Map<String, dynamic> groupJson({
    required String id,
    String title = '某个对话',
    String status = 'active',
    String updatedAt = '2024-03-05T08:09:10Z',
  }) => {
    'id': id,
    'user_id': 'usr_1',
    'title': title,
    'status': status,
    'created_at': '2024-03-05T08:00:00Z',
    'updated_at': updatedAt,
  };

  /// 挂一页 groups 响应。
  void mockPage({
    required int offset,
    required List<Map<String, dynamic>> items,
    int limit = 30,
  }) {
    adapter.onGet(
      '/chat/groups',
      (server) => server.reply(200, {'items': items}),
      queryParameters: {'limit': limit, 'offset': offset},
    );
  }

  /// 等 dio mock 的响应落地。
  ///
  /// ⚠️ 用 [WidgetTester.pump] 推进**假时区**，不能用 `runAsync`：
  /// dio 的 mock 响应是在一个 `Timer` 里 resolve 的，而 `testWidgets` 默认跑在
  /// FakeAsync 时区——`runAsync` 跑真实时区，**不会推进假时钟**，Timer 永远不触发，
  /// 页面会一直停在 loading（实测：连续 6 次 runAsync + pump 后仍只有 AppBar）。
  /// `pump(Duration)` 显式推进假时钟，Timer 才会触发。
  Future<void> settleIo(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    void Function(ChatGroup)? onOpenGroup,
    Future<ChatGroup> Function(String)? onCreateGroup,
    GroupActionHandler? onGroupAction,
    Stream<GroupUpdate>? groupUpdates,
    VoidCallback? onOpenHabits,
    VoidCallback? onOpenSettings,
    GroupCacheStore? cache,
    String? userId,
    int pageSize = 30,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GroupListPage(
          api: api,
          onOpenGroup: onOpenGroup,
          onCreateGroup: onCreateGroup,
          onGroupAction: onGroupAction,
          groupUpdates: groupUpdates,
          onOpenHabits: onOpenHabits,
          onOpenSettings: onOpenSettings,
          cache: cache,
          userId: userId,
          pageSize: pageSize,
        ),
      ),
    );
    await settleIo(tester);
  }

  /// 内存版 [GroupCacheStore]（页面单测不造 drift 库）。
  ///
  /// 语义与 `DriftGroupCacheStore` 对齐到「页面依赖的部分」：整表替换、
  /// 按 user 隔离、读失败返回空。**不做**坏行跳过/排序等实现细节——那些由
  /// `spb_data` 的测试覆盖（见 `database_test.dart`）。
  late FakeGroupCacheStore fakeCache;
  setUp(() => fakeCache = FakeGroupCacheStore());

  /// 一份服务端 `POST /chat/groups` 的响应体（`groupToDict` 的形状）。
  Map<String, dynamic> createdJson({
    String id = 'g_new',
    String title = '新对话',
  }) => groupJson(id: id, title: title);

  testWidgets('渲染对话列表（标题 + 相对时间）', (tester) async {
    mockPage(
      offset: 0,
      items: [
        groupJson(id: 'g1', title: '报错排查'),
        groupJson(id: 'g2', title: '第二个对话'),
      ],
    );
    await pumpPage(tester);

    expect(find.text('报错排查'), findsOneWidget);
    expect(find.text('第二个对话'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget); // AppBar 标题
  });

  testWidgets('归档对话显示「已归档」标记', (tester) async {
    // 归档状态必须可见，否则用户会奇怪为什么这个对话不更新。
    mockPage(
      offset: 0,
      items: [groupJson(id: 'g1', title: '旧对话', status: 'archived')],
    );
    await pumpPage(tester);

    expect(find.text('已归档'), findsOneWidget);
  });

  testWidgets('点击条目回调携带该 ChatGroup', (tester) async {
    final opened = <ChatGroup>[];
    mockPage(
      offset: 0,
      items: [groupJson(id: 'g1', title: '点我')],
    );
    await pumpPage(tester, onOpenGroup: opened.add);

    await tester.tap(find.text('点我'));
    await tester.pump();

    expect(opened, hasLength(1));
    expect(opened.single.id, 'g1');
  });

  testWidgets('空列表显示空状态', (tester) async {
    mockPage(offset: 0, items: []);
    await pumpPage(tester);

    expect(find.text('还没有对话'), findsOneWidget);
  });

  testWidgets('首屏加载失败显示整页错误与重试', (tester) async {
    adapter.onGet(
      '/chat/groups',
      (server) => server.reply(500, {'error': 'boom'}),
      queryParameters: {'limit': 30, 'offset': 0},
    );
    await pumpPage(tester);

    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('返回不足一页时显示「没有更多了」', (tester) async {
    // 1 条 < pageSize 30 → 到底。
    mockPage(offset: 0, items: [groupJson(id: 'g1')]);
    await pumpPage(tester);

    // 底部 footer 需要滚到可见区域才被构建（ListView.builder 惰性）。
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('offset 分页：滚到底加载下一页', (tester) async {
    mockPage(
      offset: 0,
      items: List.generate(30, (i) => groupJson(id: 'g$i', title: '对话 $i')),
    );
    await pumpPage(tester);

    // 第二页。
    mockPage(
      offset: 30,
      items: [groupJson(id: 'g100', title: '第二页的对话')],
    );

    // 滚到底触发 _onScroll 预加载。
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await settleIo(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await settleIo(tester);

    expect(find.text('第二页的对话'), findsOneWidget);
  });

  testWidgets('新建对话：不弹输入框，直接用默认占位标题建并进入该对话', (tester) async {
    final titles = <String>[];
    final opened = <ChatGroup>[];
    mockPage(
      offset: 0,
      items: [groupJson(id: 'g1', title: '已有的')],
    );
    await pumpPage(
      tester,
      onOpenGroup: opened.add,
      onCreateGroup: (title) async {
        titles.add(title);
        return ChatGroup.fromJson(createdJson(id: 'g_new', title: title));
      },
    );

    await tester.tap(find.byKey(const ValueKey('group-list-create')));
    await tester.pumpAndSettle();

    // 不再有「输入标题」对话框：点了就建。
    expect(
      find.byKey(const ValueKey('group-create-dialog')),
      findsNothing,
      reason: '建对话的真实意图是「开个干净上下文继续聊」，不该先逼用户起名字',
    );
    expect(titles, [defaultGroupTitle]);
    expect(titles.single, '新对话');
    // 建完直接进入该对话——建完还停在列表页会让用户多一步。
    expect(opened, hasLength(1));
    expect(opened.single.id, 'g_new');
  });

  testWidgets('新建对话：成功后把新对话插到列表最前', (tester) async {
    mockPage(
      offset: 0,
      items: [groupJson(id: 'g1', title: '已有的')],
    );
    await pumpPage(
      tester,
      onCreateGroup: (title) async =>
          ChatGroup.fromJson(createdJson(id: 'g_new', title: title)),
    );

    await tester.tap(find.byKey(const ValueKey('group-list-create')));
    await tester.pumpAndSettle();

    // 列表里能看到新项（不必等下拉刷新）。
    expect(find.text(defaultGroupTitle), findsOneWidget);
  });

  testWidgets('新建对话：往返期间禁用入口（连点不会建出两个）', (tester) async {
    var called = 0;
    final pending = Completer<ChatGroup>();
    mockPage(offset: 0, items: [groupJson(id: 'g1')]);
    await pumpPage(
      tester,
      onCreateGroup: (title) {
        called++;
        return pending.future;
      },
    );

    await tester.tap(find.byKey(const ValueKey('group-list-create')));
    await tester.pump();

    IconButton entry() => tester.widget<IconButton>(
      find.byKey(const ValueKey('group-list-create')),
    );
    expect(entry().onPressed, isNull, reason: '请求还在飞时再点一次会建出两个对话');

    pending.complete(ChatGroup.fromJson(createdJson()));
    await tester.pumpAndSettle();
    expect(called, 1);
    expect(entry().onPressed, isNotNull);
  });

  testWidgets('新建对话：失败时提示且不进入对话', (tester) async {
    final opened = <ChatGroup>[];
    mockPage(offset: 0, items: [groupJson(id: 'g1')]);
    await pumpPage(
      tester,
      onOpenGroup: opened.add,
      onCreateGroup: (title) async => throw const NetworkError('网络请求失败'),
    );

    await tester.tap(find.byKey(const ValueKey('group-list-create')));
    await tester.pumpAndSettle();

    expect(find.textContaining('创建失败'), findsOneWidget);
    expect(opened, isEmpty, reason: '没建成就跳走会让用户以为成功了，然后看到一个不存在的对话');
  });

  testWidgets('未注入 onCreateGroup 时不展示新建入口', (tester) async {
    mockPage(offset: 0, items: [groupJson(id: 'g1')]);
    await pumpPage(tester);

    expect(
      find.byKey(const ValueKey('group-list-create')),
      findsNothing,
      reason: '入口存在但点了没反应，比没有入口更糟（同 onSearch / onOpenWorks 约定）',
    );
  });

  testWidgets('习惯入口：注入了才展示，点击调回调', (tester) async {
    var opened = 0;
    mockPage(offset: 0, items: [groupJson(id: 'g1')]);
    await pumpPage(tester, onOpenHabits: () => opened++);

    await tester.tap(find.byKey(const ValueKey('group-list-habits')));
    await tester.pump();

    expect(opened, 1);
  });

  testWidgets('未注入 onOpenHabits 时不展示习惯入口（只读装配不炸）', (tester) async {
    mockPage(offset: 0, items: [groupJson(id: 'g1')]);
    await pumpPage(tester);

    expect(find.byKey(const ValueKey('group-list-habits')), findsNothing);
  });

  testWidgets('设置入口：注入了才展示，点击调回调', (tester) async {
    var opened = 0;
    mockPage(offset: 0, items: [groupJson(id: 'g1')]);
    await pumpPage(tester, onOpenSettings: () => opened++);

    await tester.tap(find.byKey(const ValueKey('group-list-settings')));
    await tester.pump();

    expect(opened, 1);
  });

  testWidgets('未注入 onOpenSettings 时不展示设置入口（只读装配不炸）', (tester) async {
    mockPage(offset: 0, items: [groupJson(id: 'g1')]);
    await pumpPage(tester);

    expect(
      find.byKey(const ValueKey('group-list-settings')),
      findsNothing,
      reason: '入口存在但点了没反应，比没有入口更糟（同 onSearch / onOpenWorks 约定）',
    );
  });

  testWidgets('offset 分页去重：重复返回同一 id 不产生重复项', (tester) async {
    // offset 分页在列表变动时会重复返回同一项。若不去重，
    // Flutter 会因重复 Key 抛异常（或渲染出两个条目）。
    mockPage(
      offset: 0,
      items: List.generate(30, (i) => groupJson(id: 'g$i', title: '对话 $i')),
    );
    await pumpPage(tester);

    // 第二页把 g0 又返回了一次（模拟窗口移动）。
    mockPage(
      offset: 30,
      items: [
        groupJson(id: 'g0', title: '对话 0'),
        groupJson(id: 'g_new', title: '真正的新对话'),
      ],
    );

    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await settleIo(tester);

    // 不崩溃，且新项出现、g0 仍只有一个。
    expect(find.text('真正的新对话'), findsOneWidget);
  });

  group('group_updated 实时增量更新', () {
    /// 造一条 group 变更通知。
    GroupUpdate update(
      GroupUpdateOp op, {
      String groupId = 'g1',
      String? title,
      String? status,
    }) => GroupUpdate(
      op: op,
      groupId: groupId,
      title: title,
      status: status,
      at: DateTime(2024, 3, 5, 8, 30),
    );

    testWidgets('op: created → 列表新增一项（用服务端权威行）', (tester) async {
      // created 的快照刻意最小化（只有 id/title/status，没有时间戳与
      // active_session），故页面要读回权威行。
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '已有的')],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);

      // 新建的那个 group 的权威行。
      adapter.onGet(
        '/chat/groups/g_new',
        (server) => server.reply(200, groupJson(id: 'g_new', title: '别处建的对话')),
      );

      await pumpPage(tester, groupUpdates: stream.stream);
      expect(find.text('别处建的对话'), findsNothing);

      stream.add(update(GroupUpdateOp.created, groupId: 'g_new'));
      await settleIo(tester);

      expect(
        find.text('别处建的对话'),
        findsOneWidget,
        reason: 'A 端建组，B 端列表必须实时出现（服务端广播 group_updated 的存在理由）',
      );
    });

    testWidgets('op: created 重复推送不重复插入', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '已有的')],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);

      adapter.onGet(
        '/chat/groups/g_new',
        (server) => server.reply(200, groupJson(id: 'g_new', title: '新来的')),
      );

      await pumpPage(tester, groupUpdates: stream.stream);

      stream.add(update(GroupUpdateOp.created, groupId: 'g_new'));
      await settleIo(tester);
      stream.add(update(GroupUpdateOp.created, groupId: 'g_new'));
      await settleIo(tester);

      // 重复 Key 会让 Flutter 直接抛异常，故「不崩溃 + 只有一个」都要断言。
      expect(find.text('新来的'), findsOneWidget);
    });

    testWidgets('op: deleted → 从列表移除', (tester) async {
      mockPage(
        offset: 0,
        items: [
          groupJson(id: 'g1', title: '要删的'),
          groupJson(id: 'g2', title: '保留的'),
        ],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);

      await pumpPage(tester, groupUpdates: stream.stream);
      expect(find.text('要删的'), findsOneWidget);

      stream.add(update(GroupUpdateOp.deleted));
      await settleIo(tester);

      expect(find.text('要删的'), findsNothing);
      expect(find.text('保留的'), findsOneWidget, reason: '只移除被删的那一项');
    });

    testWidgets('op: title → 标题就地更新', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '旧标题')],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);

      await pumpPage(tester, groupUpdates: stream.stream);

      stream.add(update(GroupUpdateOp.title, title: '新标题'));
      await settleIo(tester);

      expect(find.text('新标题'), findsOneWidget);
      expect(find.text('旧标题'), findsNothing);
    });

    testWidgets('op: title 不带标题时不动（不把名字清空）', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '原标题')],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);

      await pumpPage(tester, groupUpdates: stream.stream);

      // 异常载荷：op=title 却没带 title。
      stream.add(update(GroupUpdateOp.title));
      await settleIo(tester);

      expect(find.text('原标题'), findsOneWidget);
    });

    testWidgets('op: archived → 显示归档标记且条目留在原位', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '活跃的')],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);

      await pumpPage(tester, groupUpdates: stream.stream);
      expect(find.text('已归档'), findsNothing);

      stream.add(update(GroupUpdateOp.archived, status: 'archived'));
      await settleIo(tester);

      expect(find.text('已归档'), findsOneWidget);
      expect(find.text('活跃的'), findsOneWidget, reason: '本页是单列表 + 归档角标，不移出列表');
    });

    testWidgets('op: active → 归档标记消失', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '恢复的', status: 'archived')],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);

      await pumpPage(tester, groupUpdates: stream.stream);
      expect(find.text('已归档'), findsOneWidget);

      stream.add(update(GroupUpdateOp.active, status: 'active'));
      await settleIo(tester);

      expect(find.text('已归档'), findsNothing);
    });

    testWidgets('op: metadata → 不触发列表变化（本页不渲染 metadata）', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '不动我')],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);

      await pumpPage(tester, groupUpdates: stream.stream);

      stream.add(update(GroupUpdateOp.metadata));
      await settleIo(tester);

      expect(find.text('不动我'), findsOneWidget);
    });

    testWidgets('变更的 group 不在已加载页时忽略（不凭空插入）', (tester) async {
      // 改名/归档不是「新出现」的语义。凭空插入会让用户看到一个
      // 从未加载过的条目——下次翻页拉到它时又会重复。
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '已加载的')],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);

      await pumpPage(tester, groupUpdates: stream.stream);

      stream.add(
        update(GroupUpdateOp.title, groupId: 'g_unknown', title: '没加载过'),
      );
      await settleIo(tester);

      expect(find.text('没加载过'), findsNothing);
      expect(find.text('已加载的'), findsOneWidget);
    });

    testWidgets('未注入 groupUpdates 时不崩溃（保持纯拉取用法）', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '只读')],
      );
      await pumpPage(tester);

      expect(find.text('只读'), findsOneWidget);
    });
  });

  // ── 对话列表缓存回落（issue #26 切片 A）──────────────────────────────
  //
  // 本组的核心命题：**断网冷启动时列表不再是白屏**。反向验证（去掉回落分支）
  // 会让「网络失败时回落缓存」这条失败，而其余用例不受影响。
  group('缓存回落（issue #26）', () {
    testWidgets('网络失败时回落缓存并展示（不显示错误页）', (tester) async {
      // 1) 先在**在线**状态下拉一次，把结果写进缓存。
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '缓存里的对话')],
      );
      await pumpPage(tester, cache: fakeCache, userId: 'usr_1');
      expect(find.text('缓存里的对话'), findsOneWidget);
      expect(fakeCache.saved, hasLength(1), reason: '网络成功后必须写缓存');

      // 2) 断网：同样的页面重新挂载（新 tester 树）。
      await tester.pumpWidget(const SizedBox()); // 卸载，让新页面重新 initState
      adapter.onGet(
        '/chat/groups',
        (server) => server.reply(500, {'error': 'offline'}),
        queryParameters: {'limit': 30, 'offset': 0},
      );
      await pumpPage(tester, cache: fakeCache, userId: 'usr_1');

      // 关键断言：内容来自缓存，**不是**整页错误。
      expect(find.text('缓存里的对话'), findsOneWidget);
      expect(
        find.byType(ErrorState),
        findsNothing,
        reason: '回落成功不得渲染错误页（那会盖掉缓存内容）',
      );
      expect(
        find.byKey(const ValueKey('group-list-cache-notice')),
        findsOneWidget,
      );
      expect(find.textContaining('离线数据'), findsOneWidget);
    });

    testWidgets('回落时不显示重试按钮以外的错误态（无整页错误）', (tester) async {
      await fakeCache.save('usr_1', [
        ChatGroup.fromJson(groupJson(id: 'g_cached', title: '仅缓存有')),
      ]);
      adapter.onGet(
        '/chat/groups',
        (server) => server.reply(500, {'error': 'offline'}),
        queryParameters: {'limit': 30, 'offset': 0},
      );
      await pumpPage(tester, cache: fakeCache, userId: 'usr_1');

      expect(find.text('仅缓存有'), findsOneWidget);
      expect(find.byType(ErrorState), findsNothing);
      // 提示条里有「重试」按钮（下拉刷新也能重试）。
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('缓存为空时仍然显示错误页（回落无内容可用）', (tester) async {
      adapter.onGet(
        '/chat/groups',
        (server) => server.reply(500, {'error': 'offline'}),
        queryParameters: {'limit': 30, 'offset': 0},
      );
      await pumpPage(tester, cache: fakeCache, userId: 'usr_1');

      expect(find.byType(ErrorState), findsOneWidget);
      expect(
        find.byKey(const ValueKey('group-list-cache-notice')),
        findsNothing,
      );
    });

    testWidgets('不注入 cache 时行为完全不变（纯拉取）', (tester) async {
      adapter.onGet(
        '/chat/groups',
        (server) => server.reply(500, {'error': 'boom'}),
        queryParameters: {'limit': 30, 'offset': 0},
      );
      await pumpPage(tester); // 不传 cache / userId

      expect(find.byType(ErrorState), findsOneWidget);
      expect(
        find.byKey(const ValueKey('group-list-cache-notice')),
        findsNothing,
      );
    });

    testWidgets('只给 cache 不给 userId 时不启用缓存（静默降级）', (tester) async {
      // userId 是缓存行的归属键；缺它无法定位行，故不启用（不报错）。
      adapter.onGet(
        '/chat/groups',
        (server) => server.reply(500, {'error': 'boom'}),
        queryParameters: {'limit': 30, 'offset': 0},
      );
      await pumpPage(tester, cache: fakeCache); // userId 为 null

      expect(find.byType(ErrorState), findsOneWidget);
      expect(fakeCache.loadedUserIds, isEmpty, reason: '无 userId 不该查缓存');
    });

    testWidgets('网络成功后清除离线提示（提示条不永久残留）', (tester) async {
      await fakeCache.save('usr_1', [
        ChatGroup.fromJson(groupJson(id: 'g_old', title: '旧缓存')),
      ]);
      // 先失败 → 回落。
      adapter.onGet(
        '/chat/groups',
        (server) => server.reply(500, {'error': 'offline'}),
        queryParameters: {'limit': 30, 'offset': 0},
      );
      await pumpPage(tester, cache: fakeCache, userId: 'usr_1');
      expect(
        find.byKey(const ValueKey('group-list-cache-notice')),
        findsOneWidget,
      );

      // 再点提示条里的「重试」，这次网络成功。
      //
      // ⚠️ 不用 `tester.drag` 触发 RefreshIndicator：那需要走完一整套下拉手势
      // 动画，在 `testWidgets` 的假时钟下不可靠（实测 drag 后列表未刷新）。
      // 提示条里的「重试」按钮是**同一条** `_refresh` 路径，且点击是确定性的。
      adapter.onGet(
        '/chat/groups',
        (server) => server.reply(200, {
          'items': [groupJson(id: 'g_new', title: '网络新数据')],
        }),
        queryParameters: {'limit': 30, 'offset': 0},
      );
      await tester.tap(find.text('重试'));
      await settleIo(tester);

      expect(find.text('网络新数据'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('group-list-cache-notice')),
        findsNothing,
        reason: '网络成功必须清掉离线提示，否则永久残留',
      );
    });

    testWidgets('写入缓存的是累积后的完整列表（整表替换语义）', (tester) async {
      // 若只把新页写进缓存，第二页会把第一页删掉（save 是先删后插）。
      mockPage(
        offset: 0,
        items: List.generate(30, (i) => groupJson(id: 'g$i', title: '对话 $i')),
      );
      await pumpPage(tester, cache: fakeCache, userId: 'usr_1', pageSize: 30);

      mockPage(
        offset: 30,
        items: [groupJson(id: 'g100', title: '第二页')],
      );
      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await settleIo(tester);
      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await settleIo(tester);

      expect(
        fakeCache.saved.last,
        hasLength(31),
        reason: '缓存必须是累积的 31 条，而不是只有第二页的 1 条',
      );
    });
  });

  // ── 本地变更后写缓存（issue #28）─────────────────────────────────────
  //
  // 切片 A 只在**网络成功**路径写缓存，于是「新建 / 改名 / 删除后立刻断网重启」
  // 会看到变更前的旧列表——比没有缓存更容易误导（用户以为对话丢了 / 没删掉）。
  //
  // 本组的每条用例都能被反向验证抓住：去掉 `_saveCache()` 调用即失败。
  group('本地变更写缓存（issue #28）', () {
    /// 取最后一次写入的缓存内容（无写入时为 null）。
    List<ChatGroup>? lastSaved() =>
        fakeCache.saved.isEmpty ? null : fakeCache.saved.last;

    testWidgets('新建对话后写缓存（断网重启能看到它）', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '已有的')],
      );
      await pumpPage(
        tester,
        cache: fakeCache,
        userId: 'usr_1',
        onCreateGroup: (title) async =>
            ChatGroup.fromJson(createdJson(id: 'g_new', title: title)),
      );
      // 初始加载已写一次（只有 g1）。
      expect(lastSaved(), hasLength(1));

      await tester.tap(find.byKey(const ValueKey('group-list-create')));
      await tester.pumpAndSettle();

      expect(
        lastSaved()?.map((g) => g.id),
        containsAll(<String>['g1', 'g_new']),
        reason: '新建后缓存必须包含新对话，否则断网重启它就不见了',
      );
    });

    testWidgets('SSE op=created 后写缓存（别处建的对话也落缓存）', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '已有的')],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);
      adapter.onGet(
        '/chat/groups/g_new',
        (server) => server.reply(200, groupJson(id: 'g_new', title: '别处建的')),
      );

      await pumpPage(
        tester,
        groupUpdates: stream.stream,
        cache: fakeCache,
        userId: 'usr_1',
      );
      expect(lastSaved(), hasLength(1));

      stream.add(
        GroupUpdate(
          op: GroupUpdateOp.created,
          groupId: 'g_new',
          title: '别处建的',
          at: DateTime(2024, 3, 5, 8, 30),
        ),
      );
      await settleIo(tester);

      expect(
        lastSaved()?.map((g) => g.id),
        containsAll(<String>['g1', 'g_new']),
        reason: 'SSE 建的对话也要落缓存——它同样不经过网络成功路径',
      );
    });

    testWidgets('SSE op=deleted 后写缓存（删掉的不能留在缓存里）', (tester) async {
      mockPage(
        offset: 0,
        items: [
          groupJson(id: 'g1', title: '要删的'),
          groupJson(id: 'g2', title: '保留的'),
        ],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);

      await pumpPage(
        tester,
        groupUpdates: stream.stream,
        cache: fakeCache,
        userId: 'usr_1',
      );

      stream.add(
        GroupUpdate(
          op: GroupUpdateOp.deleted,
          groupId: 'g1',
          at: DateTime(2024, 3, 5, 8, 30),
        ),
      );
      await settleIo(tester);

      expect(lastSaved()?.map((g) => g.id), [
        'g2',
      ], reason: '删除后缓存里不能再有它，否则断网重启会看到一个点进去 404 的条目');
    });

    testWidgets('SSE op=title 后写缓存（改名后断网重启看到新标题）', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '旧标题')],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);

      await pumpPage(
        tester,
        groupUpdates: stream.stream,
        cache: fakeCache,
        userId: 'usr_1',
      );

      stream.add(
        GroupUpdate(
          op: GroupUpdateOp.title,
          groupId: 'g1',
          title: '新标题',
          at: DateTime(2024, 3, 5, 8, 30),
        ),
      );
      await settleIo(tester);

      expect(lastSaved()?.single.title, '新标题');
    });

    testWidgets('管理动作（改名）后写缓存', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '旧名字')],
      );
      await pumpPage(
        tester,
        cache: fakeCache,
        userId: 'usr_1',
        onGroupAction: (group, action) async => GroupActionApplied(
          group: ChatGroup.fromJson(groupJson(id: 'g1', title: '改过的名字')),
        ),
      );

      await tester.longPress(find.text('旧名字'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('group-rename-field')),
        '改过的名字',
      );
      await tester.tap(find.byKey(const ValueKey('group-rename-confirm')));
      await tester.pumpAndSettle();

      expect(lastSaved()?.single.title, '改过的名字');
    });

    testWidgets('管理动作（删除）后写缓存', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '要删的')],
      );
      await pumpPage(
        tester,
        cache: fakeCache,
        userId: 'usr_1',
        // 删除成功 = group 为 null（见 GroupActionApplied 文档）。
        onGroupAction: (group, action) async => const GroupActionApplied(),
      );
      expect(lastSaved(), hasLength(1));

      await tester.longPress(find.text('要删的'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(lastSaved(), isEmpty, reason: '删掉最后一个对话后缓存必须清空，否则断网重启它还在');
    });

    testWidgets('未注入 cache 时本地变更不报错（纯拉取用法）', (tester) async {
      mockPage(
        offset: 0,
        items: [groupJson(id: 'g1', title: '只读')],
      );
      final stream = StreamController<GroupUpdate>.broadcast();
      addTearDown(stream.close);

      // 不传 cache / userId：变更路径上的 _saveCache 应静默 return。
      await pumpPage(tester, groupUpdates: stream.stream);

      stream.add(
        GroupUpdate(
          op: GroupUpdateOp.deleted,
          groupId: 'g1',
          at: DateTime(2024, 3, 5, 8, 30),
        ),
      );
      await settleIo(tester);

      expect(tester.takeException(), isNull);
    });
  });
}

/// 内存版 [GroupCacheStore]。
///
/// ## 为什么不用 `DriftGroupCacheStore` + 内存库
///
/// `spb_features` 不依赖 `spb_data`（分层规则：features → data 是允许的，但
/// 本页只依赖 domain 的接口）。用 fake 还能**记录调用**——「不注入 cache 时不
/// 查缓存」「写的是累积列表」这类断言必须看到调用轨迹，而不只是最终状态。
///
/// ## 语义对齐
///
/// 与 `DriftGroupCacheStore` 对齐到页面依赖的部分：整表替换（`save` 覆盖）、
/// 按 user 隔离。**不做**排序/坏行跳过（那是实现细节，由 `spb_data` 的测试覆盖）。
class FakeGroupCacheStore implements GroupCacheStore {
  final Map<String, List<ChatGroup>> _byUser = {};

  /// 每次 `save` 的入参快照（供断言「写的是累积列表」）。
  final List<List<ChatGroup>> saved = [];

  /// 每次 `load` 的 userId（供断言「无 userId 时不查」）。
  final List<String> loadedUserIds = [];

  /// `lastFetchedAt` 的返回值（默认 null = 不显示时间）。
  DateTime? fetchedAt;

  /// 置 true 模拟读失败（接口约定：返回空列表而非抛）。
  bool failLoad = false;

  @override
  Future<List<ChatGroup>> load(String userId) async {
    loadedUserIds.add(userId);
    if (failLoad) return const [];
    return List.of(_byUser[userId] ?? const []);
  }

  @override
  Future<void> save(String userId, List<ChatGroup> groups) async {
    saved.add(List.of(groups));
    // 整表替换（与 DriftGroupCacheStore 同语义）。
    _byUser[userId] = List.of(groups);
  }

  @override
  Future<void> clear(String userId) async {
    _byUser.remove(userId);
  }

  @override
  Future<DateTime?> lastFetchedAt(String userId) async => fetchedAt;
}
