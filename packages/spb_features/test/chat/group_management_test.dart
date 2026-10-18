import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 对话**分组**（group）管理的交互测试。
///
/// ## 这个测试防的是什么
///
/// 管理动作的**意图收集**（菜单 → 对话框 → 确认）与**结果反映**（列表更新）
/// 都发生在页面里，而两者都容易出错：
///
/// - 菜单项漏挂动作 → 点了没反应（`showMenu` 返回 null，静默什么都不做）；
/// - 「重命名」把空标题发出去 → 服务端 400，用户看到莫名其妙的失败；
/// - 「删除」不确认 → 一次误触永久删掉对话；
/// - 失败时静默成功 → 用户以为删掉了，实际还在。
///
/// 故这里对每个动作都断言「回调收到的**具体参数**」，而不只是「回调被调用过」。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
  });

  /// `groupRowToDict` 的真实输出形状。
  Map<String, dynamic> groupJson({
    required String id,
    String title = '某个对话',
    String status = 'active',
  }) => {
    'id': id,
    'user_id': 'usr_1',
    'title': title,
    'status': status,
    'created_at': '2024-03-05T08:00:00Z',
    'updated_at': '2024-03-05T08:09:10Z',
  };

  void mockGroups(List<Map<String, dynamic>> items) {
    adapter.onGet(
      '/chat/groups',
      (server) => server.reply(200, {'items': items}),
      queryParameters: {'limit': 30, 'offset': 0},
    );
  }

  /// 等 dio mock 落地（见 group_list_page_test.dart 里同一处说明：
  /// 必须 `pump(Duration)` 推进假时钟，`runAsync` 不会推进它）。
  Future<void> settleIo(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    GroupActionHandler? onGroupAction,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GroupListPage(api: api, onGroupAction: onGroupAction),
      ),
    );
    await settleIo(tester);
  }

  /// 记录回调收到的 (group, action)。
  late List<(ChatGroup, GroupAction)> calls;
  late GroupActionHandler handler;

  /// 每次用例前重置记录器。
  ///
  /// ## 为什么让 handler 返回「原样应用」
  ///
  /// 默认行为是「服务端接受了，且没返回新对象」——足以覆盖「回调参数正确」
  /// 与「删除后移除条目」两类断言。需要特定结果的用例显式传自己的 handler。
  void useRecorder({
    GroupActionResult Function(ChatGroup group, GroupAction action)? respond,
  }) {
    calls = [];
    handler = (group, action) async {
      calls.add((group, action));
      return respond?.call(group, action) ?? const GroupActionApplied();
    };
  }

  /// 长按条目打开管理菜单。
  Future<void> openMenu(WidgetTester tester, String title) async {
    await tester.longPress(find.text(title));
    await tester.pumpAndSettle();
  }

  group('对话分组管理：菜单', () {
    testWidgets('未注入回调时不展示管理入口（长按无菜单）', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '只读对话')]);
      // 不传 onGroupAction：只读用法。
      await pumpPage(tester);

      await tester.longPress(find.text('只读对话'));
      await tester.pumpAndSettle();

      expect(find.text('重命名'), findsNothing);
      expect(find.text('删除'), findsNothing);
    });

    testWidgets('长按打开菜单：含重命名 / 归档 / 删除', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '某对话')]);
      useRecorder();
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '某对话');

      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('归档'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('取消归档'), findsNothing);
    });

    testWidgets('已归档的分组菜单显示「取消归档」而非「归档」', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '旧对话', status: 'archived')]);
      useRecorder();
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '旧对话');

      expect(find.text('取消归档'), findsOneWidget);
      expect(find.text('归档'), findsNothing);
    });
  });

  group('对话分组管理：动作回调参数', () {
    testWidgets('点「归档」→ 回调收到 (该 group, ArchiveGroup)', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '要归档的')]);
      useRecorder();
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '要归档的');
      await tester.tap(find.text('归档'));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.$1.id, 'g1');
      expect(calls.single.$2, isA<ArchiveGroup>());
    });

    testWidgets('点「取消归档」→ 回调收到 UnarchiveGroup', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '已归档的', status: 'archived')]);
      useRecorder();
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '已归档的');
      await tester.tap(find.text('取消归档'));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.$2, isA<UnarchiveGroup>());
    });

    testWidgets('重命名：输入新标题后回调收到 RenameGroup(新标题)', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '旧名字')]);
      useRecorder();
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '旧名字');
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('group-rename-field')),
        '新名字',
      );
      await tester.tap(find.byKey(const ValueKey('group-rename-confirm')));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.$2, isA<RenameGroup>());
      expect((calls.single.$2 as RenameGroup).title, '新名字');
    });

    testWidgets('重命名：标题会被 trim', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '旧名字')]);
      useRecorder();
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '旧名字');
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('group-rename-field')),
        '  带空格  ',
      );
      await tester.tap(find.byKey(const ValueKey('group-rename-confirm')));
      await tester.pumpAndSettle();

      expect((calls.single.$2 as RenameGroup).title, '带空格');
    });

    testWidgets('重命名：取消不发请求', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '旧名字')]);
      useRecorder();
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '旧名字');
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(calls, isEmpty, reason: '取消是明确的「什么都不做」');
    });

    testWidgets('重命名：空标题（或纯空格）不发请求', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '旧名字')]);
      useRecorder();
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '旧名字');
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('group-rename-field')),
        '   ',
      );
      await tester.tap(find.byKey(const ValueKey('group-rename-confirm')));
      await tester.pumpAndSettle();

      expect(calls, isEmpty, reason: '空标题服务端会 400，本地直接拦掉，别让用户看到无意义的失败');
    });

    testWidgets('重命名：标题未改动不发请求', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '旧名字')]);
      useRecorder();
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '旧名字');
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      // 不动输入框，直接保存。
      await tester.tap(find.byKey(const ValueKey('group-rename-confirm')));
      await tester.pumpAndSettle();

      expect(calls, isEmpty, reason: '没改动就不该产生一次往返');
    });

    testWidgets('删除：确认后回调收到 DeleteGroup', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '要删的')]);
      useRecorder();
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '要删的');
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      // 必须经过确认框（删除不可恢复）。
      expect(find.byKey(const ValueKey('group-delete-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('group-delete-confirm')));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.$2, isA<DeleteGroup>());
    });

    testWidgets('删除：在确认框取消则完全不发请求', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '要删的')]);
      useRecorder();
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '要删的');
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(calls, isEmpty, reason: '一次误触不该永久删掉对话');
      // 条目仍在。
      expect(find.text('要删的'), findsOneWidget);
    });
  });

  group('对话分组管理：结果反映到列表', () {
    testWidgets('改名成功 → 条目换成服务端返回的权威标题', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '旧名字')]);
      useRecorder(
        respond: (group, action) => GroupActionApplied(
          // 服务端返回的权威对象（不是本地拼的）。
          group: ChatGroup.fromJson(groupJson(id: 'g1', title: '服务端新名字')),
        ),
      );
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '旧名字');
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('group-rename-field')),
        '我输入的名字',
      );
      await tester.tap(find.byKey(const ValueKey('group-rename-confirm')));
      await tester.pumpAndSettle();

      // 用服务端返回值而非用户输入——保证列表与服务端一致。
      expect(find.text('服务端新名字'), findsOneWidget);
      expect(find.text('我输入的名字'), findsNothing);
    });

    testWidgets('归档成功 → 条目出现「已归档」标记', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '某对话')]);
      useRecorder(
        respond: (group, action) => GroupActionApplied(
          group: ChatGroup.fromJson(
            groupJson(id: 'g1', title: '某对话', status: 'archived'),
          ),
        ),
      );
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '某对话');
      await tester.tap(find.text('归档'));
      await tester.pumpAndSettle();

      expect(find.text('已归档'), findsOneWidget);
    });

    testWidgets('删除成功（group 为 null）→ 条目从列表移除', (tester) async {
      mockGroups([
        groupJson(id: 'g1', title: '要删的'),
        groupJson(id: 'g2', title: '保留的'),
      ]);
      useRecorder(respond: (_, _) => const GroupActionApplied());
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '要删的');
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('group-delete-confirm')));
      await tester.pumpAndSettle();

      expect(find.text('要删的'), findsNothing);
      expect(find.text('保留的'), findsOneWidget, reason: '只移除目标条目');
    });

    testWidgets('失败（GroupActionRejected）→ 展示服务端给的原因', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '要删的')]);
      useRecorder(respond: (_, _) => const GroupActionRejected('没有权限删除这个对话'));
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '要删的');
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('group-delete-confirm')));
      await tester.pumpAndSettle();

      expect(find.text('没有权限删除这个对话'), findsOneWidget);
      // 失败不得移除条目：用户以为删掉了，实际还在。
      expect(find.text('要删的'), findsOneWidget);
    });

    testWidgets('回调抛异常（网络失败）→ 展示提示且不崩溃、不移除条目', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '要删的')]);
      useRecorder();
      // 覆盖成抛异常。
      handler = (group, action) async =>
          throw const NetworkError('连接超时', retryable: true);
      await pumpPage(tester, onGroupAction: handler);

      await openMenu(tester, '要删的');
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('group-delete-confirm')));
      await tester.pumpAndSettle();

      expect(find.text('连接超时'), findsOneWidget);
      expect(find.text('要删的'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('对话分组管理：防重复提交', () {
    testWidgets('动作进行中时再长按不打开菜单（避免第二次删除得到 404）', (tester) async {
      mockGroups([groupJson(id: 'g1', title: '某对话')]);
      final gate = Completer<void>();
      calls = [];
      handler = (group, action) async {
        calls.add((group, action));
        await gate.future;
        return const GroupActionApplied();
      };
      await pumpPage(tester, onGroupAction: handler);

      // 第一次：点归档，回调挂起。
      await openMenu(tester, '某对话');
      await tester.tap(find.text('归档'));
      await tester.pump();

      // 动作进行中：再长按不应出现菜单。
      await tester.longPress(find.text('某对话'));
      await tester.pumpAndSettle();
      expect(find.text('删除'), findsNothing);
      expect(calls, hasLength(1));

      // 放行，避免测试结束时留下未结算的 Future。
      gate.complete();
      await tester.pumpAndSettle();
    });
  });
}
