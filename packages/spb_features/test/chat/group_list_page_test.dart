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
    Stream<GroupUpdate>? groupUpdates,
    VoidCallback? onOpenHabits,
    int pageSize = 30,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GroupListPage(
          api: api,
          onOpenGroup: onOpenGroup,
          onCreateGroup: onCreateGroup,
          groupUpdates: groupUpdates,
          onOpenHabits: onOpenHabits,
          pageSize: pageSize,
        ),
      ),
    );
    await settleIo(tester);
  }

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

  testWidgets('新建对话：输入标题后回调收到 trim 后的标题', (tester) async {
    final titles = <String>[];
    mockPage(
      offset: 0,
      items: [groupJson(id: 'g1', title: '已有的')],
    );
    await pumpPage(
      tester,
      onCreateGroup: (title) async {
        titles.add(title);
        return ChatGroup.fromJson(createdJson(title: title));
      },
    );

    await tester.tap(find.byKey(const ValueKey('group-list-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('group-create-field')),
      '  新对话  ',
    );
    // ⚠️ 必须 pump 一帧再点确认：确认按钮的可用性由 `ValueListenableBuilder`
    // 监听输入框决定，而 `tester.enterText` **不推进帧**（它只调
    // `testTextInput.enterText` + `idle()`），此时树上的按钮还是「初始为空」
    // 那个**禁用**实例，`tap` 会静默失效（实测：不 pump 则回调一次都不发）。
    // 真实使用中每帧都在推进，故这不是实现缺陷。
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('group-create-confirm')));
    await tester.pumpAndSettle();

    expect(titles, hasLength(1));
    expect(titles.single, '新对话', reason: '首尾空白要去掉，否则列表里会出现看不见的前导空格');
  });

  testWidgets('新建对话：成功后把新对话插到列表最前并进入该对话', (tester) async {
    final opened = <ChatGroup>[];
    mockPage(
      offset: 0,
      items: [groupJson(id: 'g1', title: '已有的')],
    );
    await pumpPage(
      tester,
      onOpenGroup: opened.add,
      onCreateGroup: (title) async =>
          ChatGroup.fromJson(createdJson(id: 'g_new', title: title)),
    );

    await tester.tap(find.byKey(const ValueKey('group-list-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('group-create-field')),
      '刚建的',
    );
    // 先 pump 一帧让确认按钮解除禁用（理由见「trim 后的标题」用例）。
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('group-create-confirm')));
    await tester.pumpAndSettle();

    // 列表里能看到新项（不必等下拉刷新）。
    expect(find.text('刚建的'), findsOneWidget);
    // 直接进入该对话——建完还停在列表页会让用户多一步。
    expect(opened, hasLength(1));
    expect(opened.single.id, 'g_new');
  });

  testWidgets('新建对话：取消不发请求', (tester) async {
    var called = 0;
    mockPage(offset: 0, items: [groupJson(id: 'g1')]);
    await pumpPage(
      tester,
      onCreateGroup: (title) async {
        called++;
        return ChatGroup.fromJson(createdJson());
      },
    );

    await tester.tap(find.byKey(const ValueKey('group-list-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(called, 0, reason: '取消是明确的「什么都不做」');
  });

  testWidgets('新建对话：空标题时确认按钮禁用（连空格也算空）', (tester) async {
    var called = 0;
    mockPage(offset: 0, items: [groupJson(id: 'g1')]);
    await pumpPage(
      tester,
      onCreateGroup: (title) async {
        called++;
        return ChatGroup.fromJson(createdJson());
      },
    );

    await tester.tap(find.byKey(const ValueKey('group-list-create')));
    await tester.pumpAndSettle();

    FilledButton confirmButton() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('group-create-confirm')),
    );

    // 初始为空 → 禁用。
    expect(confirmButton().onPressed, isNull);

    // 纯空格同样禁用：服务端会拒绝空标题，本地拦掉省一次必然失败的往返。
    await tester.enterText(
      find.byKey(const ValueKey('group-create-field')),
      '   ',
    );
    await tester.pump();
    expect(confirmButton().onPressed, isNull);

    // 填入真实标题后恢复可点。
    await tester.enterText(
      find.byKey(const ValueKey('group-create-field')),
      '有名字了',
    );
    await tester.pump();
    expect(confirmButton().onPressed, isNotNull);

    expect(called, 0, reason: '全程没有点下确认，不应产生任何请求');
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
    await tester.enterText(
      find.byKey(const ValueKey('group-create-field')),
      '会失败的',
    );
    // 先 pump 一帧让确认按钮解除禁用（理由见「trim 后的标题」用例）。
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('group-create-confirm')));
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
}
