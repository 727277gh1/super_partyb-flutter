import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
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
    int pageSize = 30,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GroupListPage(
          api: api,
          onOpenGroup: onOpenGroup,
          pageSize: pageSize,
        ),
      ),
    );
    await settleIo(tester);
  }

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
}
