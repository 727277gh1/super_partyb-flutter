import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:path/path.dart' as p;

import 'package:drift/native.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

import 'package:spb_desktop/providers.dart';
import 'package:spb_desktop/router.dart';

import 'support/desktop_harness.dart';

/// 确认通知 / 小程序工作台 / 习惯 / 侧边栏 / 任务编辑 / 交付物 / 导入会话
///
/// ⚠️ 本文件由 `widget_test.dart` 按顶层用例边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/desktop_harness.dart`。
void main() {
  group('确认卡到达时发 OS 通知（issue #21）', () {
    /// 推一帧 confirmation_required。
    void pushConfirmation(
      FakeSseClient sse, {
      String eventId = 'evt_n1',
      String confirmationId = 'conf_n1',
      String groupId = 'grp_n',
      String question = '要部署到生产吗？',
    }) {
      sse.push('confirmation_required', {
        'eventId': eventId,
        'eventType': 'confirmation_required',
        'groupId': groupId,
        'turnId': 'turn_n1',
        'userId': 'usr_REAL',
        'seq': 1,
        'createdAt': '2026-01-01T00:00:00Z',
        'payload': {
          'confirmation_id': confirmationId,
          'question': question,
          'options': ['继续', '取消'],
        },
      });
    }

    /// 起一个「已进入某对话页」的测试环境（通知判定挂在对话页的 items 流上）。
    Future<TestHarness> pumpInChat(
      WidgetTester tester, {
      required FakeSseClient sse,
      required NotificationSink sink,
      bool focused = false,
      String groupId = 'grp_n',
    }) async {
      final h = await pumpApp(
        tester,
        sseClient: sse,
        notificationSink: sink,
        windowFocused: focused,
        beforePump: (adapter) {
          adapter.onGet(
            '/api/auth/me',
            (server) => server.reply(200, {
              'id': 'usr_REAL',
              'email': 'a@b.c',
              'name': 'Test',
              'role': 'member',
              'roles': ['member'],
              'permissions': <String>[],
              'status': 'active',
            }),
          );
          adapter.onGet(
            '/chat/groups/$groupId',
            (server) => server.reply(200, {
              'id': groupId,
              'user_id': 'usr_REAL',
              'title': '通知测试',
            }),
          );
          adapter.onGet(
            '/chat/groups/$groupId/timeline',
            (server) => server.reply(200, {
              'items': <Map<String, dynamic>>[],
              'next_before_global_seq': '',
            }),
            queryParameters: {'limit': 200},
          );
          adapter.onGet(
            '/users/usr_REAL/chat/messages/pending',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'group_id': groupId, 'limit': 20},
          );
        },
      );
      h.router.go(SpbRoutes.chat(groupId));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      return h;
    }

    /// 推帧后结算（归约 → items 流 → 通知判定）。
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('新的确认卡到达 → 发一条通知（窗口在后台）', (tester) async {
      final sse = FakeSseClient();
      final sink = RecordingNotificationSink();
      await pumpInChat(tester, sse: sse, sink: sink, focused: false);

      pushConfirmation(sse);
      await settle(tester);

      expect(sink.sent, hasLength(1));
      expect(sink.sent.single.title, '需要你确认');
      expect(sink.sent.single.body, '要部署到生产吗？');
      expect(sink.sent.single.payload, '/chat/grp_n');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('窗口聚焦中 → 不发通知（不打扰正在看对话的用户）', (tester) async {
      final sse = FakeSseClient();
      final sink = RecordingNotificationSink();
      await pumpInChat(tester, sse: sse, sink: sink, focused: true);

      pushConfirmation(sse);
      await settle(tester);

      expect(sink.sent, isEmpty);
      expect(sink.permissionCalls, 0, reason: '不发就不该请求权限');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('同 id 重复推送（SSE 重连回放）→ 只发一次', (tester) async {
      final sse = FakeSseClient();
      final sink = RecordingNotificationSink();
      await pumpInChat(tester, sse: sse, sink: sink, focused: false);

      pushConfirmation(sse, eventId: 'evt_n1');
      await settle(tester);
      // 回放：同一张确认卡，**新的 eventId**（回放会重发事件）。
      pushConfirmation(sse, eventId: 'evt_n1_replay');
      await settle(tester);

      expect(sink.sent, hasLength(1), reason: '同一张卡回放不得重复弹');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('权限被拒 → 不发通知（静默降级，不崩）', (tester) async {
      final sse = FakeSseClient();
      final sink = RecordingNotificationSink(granted: false);
      await pumpInChat(tester, sse: sse, sink: sink, focused: false);

      pushConfirmation(sse);
      await settle(tester);

      expect(sink.sent, isEmpty);
      expect(sink.permissionCalls, 1);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('两张不同的确认卡 → 各发一条', (tester) async {
      final sse = FakeSseClient();
      final sink = RecordingNotificationSink();
      await pumpInChat(tester, sse: sse, sink: sink, focused: false);

      pushConfirmation(sse, eventId: 'evt_a', confirmationId: 'conf_a');
      pushConfirmation(sse, eventId: 'evt_b', confirmationId: 'conf_b');
      await settle(tester);

      expect(sink.sent.map((n) => n.id), ['conf_a', 'conf_b']);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('普通消息（非确认卡）不触发通知', (tester) async {
      final sse = FakeSseClient();
      final sink = RecordingNotificationSink();
      await pumpInChat(tester, sse: sse, sink: sink, focused: false);

      sse.push('message', {
        'eventId': 'evt_msg',
        'eventType': 'message',
        'groupId': 'grp_n',
        'turnId': 'turn_n1',
        'userId': 'usr_REAL',
        'seq': 1,
        'createdAt': '2026-01-01T00:00:00Z',
        'payload': {'text': '普通回复'},
      });
      // 必须再推 `done` 收尾：`message` 会让该 turn 进入「进行中」，控制器据此
      // 武装 per-turn 看门狗计时器（见 `ChatStreamController` 的 stale 机制）。
      // 不收尾就会留下 pending timer，测试框架报「A Timer is still pending」。
      sse.push('done', {
        'eventId': 'evt_done',
        'eventType': 'done',
        'groupId': 'grp_n',
        'turnId': 'turn_n1',
        'userId': 'usr_REAL',
        'seq': 2,
        'createdAt': '2026-01-01T00:00:01Z',
        'payload': <String, dynamic>{},
      });
      await settle(tester);

      expect(sink.sent, isEmpty);
      expect(sink.permissionCalls, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
  group('小程序工作台（桌面端接线）', () {
    testWidgets('对话列表点「工作台」进入工作列表', (tester) async {
      // 端到端验证 router 把首页的 onOpenWorks 接到了真实路由与端点。
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {
              'items': [workJson(id: 'w1', title: '桌面端工作')],
            }),
            queryParameters: {'status': 'active', 'limit': 20},
          );
        },
      );

      // 入口只在注入了 onOpenWorks 时出现（见 GroupListPage.onOpenWorks）。
      await tester.tap(find.byKey(const ValueKey('group-list-works')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.works,
        reason: '点工作台入口必须真的导航到工作列表，否则入口是摆设',
      );
      expect(find.text('桌面端工作'), findsOneWidget);
      expect(find.text('运行中'), findsOneWidget);
    });

    testWidgets('工作列表点条目进入详情（work.id 就是 group id）', (tester) async {
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {
              'items': [workJson(id: 'grp_w9', title: '报表工作')],
            }),
            queryParameters: {'status': 'active', 'limit': 20},
          );
          mockWorkDetail(adapter, 'grp_w9', title: '报表工作');
        },
      );

      h.router.go(SpbRoutes.works);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.byKey(const ValueKey('miniapp-work-grp_w9')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.work('grp_w9'),
        reason: 'work.id 就是 group id，直接用作路径参数',
      );
      expect(
        find.byKey(const ValueKey('miniapp-work-detail-page')),
        findsOneWidget,
      );
    });

    testWidgets('新建工作：POST /chat/miniapp/works 后进入新工作详情', (tester) async {
      // 端到端验证 router 把「点新建」接到了真实端点，且拿到返回的 workId 导航。
      Map<String, dynamic>? createBody;
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'status': 'active', 'limit': 20},
          );
          adapter.onPost(
            '/chat/miniapp/works',
            (server) => server.reply(201, {
              ...workDetailJson(id: 'grp_new', title: '新会话'),
              'dispatch': null,
            }),
            data: Matchers.any,
          );
          mockWorkDetail(adapter, 'grp_new', title: '新会话');
        },
      );
      h.dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/chat/miniapp/works') &&
                options.method == 'POST') {
              createBody = options.data is Map
                  ? Map<String, dynamic>.from(options.data as Map)
                  : null;
            }
            handler.next(options);
          },
        ),
      );

      h.router.go(SpbRoutes.works);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.byKey(const ValueKey('miniapp-works-create')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(createBody, isNotNull, reason: '必须真的发出建工作请求');
      expect(
        h.router.state.matchedLocation,
        SpbRoutes.work('grp_new'),
        reason: '新建后直接进详情——列表里一堆同名「新会话」看不出哪个是刚建的',
      );
    });

    testWidgets('两条工作台路由不会互相抢匹配', (tester) async {
      // `/miniapp/works` 是 2 段、`/miniapp/works/:workId` 是 3 段，段数不同。
      // 这条用例守住「将来有人把它改成嵌套子路由而引入歧义」。
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'status': 'active', 'limit': 20},
          );
          mockWorkDetail(adapter, 'grp_x');
        },
      );

      h.router.go(SpbRoutes.works);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('miniapp-works-page')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('miniapp-work-detail-page')),
        findsNothing,
      );

      h.router.go(SpbRoutes.work('grp_x'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.byKey(const ValueKey('miniapp-work-detail-page')),
        findsOneWidget,
      );
    });
  });
  group('习惯（桌面端接线）', () {
    /// `/api/habits` 列表项（sqlc camelCase 形态）。
    Map<String, dynamic> habitJson({
      String id = 'hp_1',
      String topicKey = 'weekly-report',
      String status = 'active',
    }) => {
      'id': id,
      'userId': 'usr_1',
      'originGroupId': 'grp_1',
      'topicKey': topicKey,
      'triggerType': 'time_based',
      'triggerConfigJson': '{"weekday":[1],"times":[{"hour":9,"minute":0}]}',
      'acceptanceLevel': 'suggest_only',
      'sourceType': 'manual',
      'status': status,
      'triggerCount': 2,
      'confidence': 0.5,
      'nextFireAt': {'Time': '0001-01-01T00:00:00Z', 'Valid': false},
    };

    /// `/api/habits/runs` 列表项（snake_case + `run_id`）。
    Map<String, dynamic> runJson({
      String runId = 'run_1',
      String? turnId = 'turn_9',
    }) => {
      'run_id': runId,
      'pattern_id': 'hp_1',
      'topic_key': 'weekly-report',
      'trigger_reason': 'due_rule',
      'outcome': 'completed',
      'created_at': '2024-03-05T08:09:10Z',
      'delivery_group_id': 'grp_1',
      'delivery_group_title': null,
      'turn_id': turnId,
      'reply_text': '已生成周报草稿。',
      'is_manual': false,
    };

    testWidgets('对话列表点「习惯」进入习惯页（两个 Tab 都拉到数据）', (tester) async {
      // 端到端验证 router 把 onOpenHabits 接到真实路由与两个端点。
      //
      // 两个 Tab 都要 mock：页面首次构建时两个 FutureProvider 都会被监听到
      // （TabBarView 用 IndexedStack 语义保留两个子页），漏一个会留下未结算请求。
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/api/habits',
            (server) => server.reply(200, {
              'items': [habitJson()],
            }),
            queryParameters: {'limit': 50, 'offset': 0},
          );
          adapter.onGet(
            '/api/habits/runs',
            (server) => server.reply(200, {
              'items': [runJson()],
            }),
            queryParameters: {'limit': 50},
          );
        },
      );

      // 入口只在注入了 onOpenHabits 时出现（见 GroupListPage.onOpenHabits）。
      await tester.tap(find.byKey(const ValueKey('group-list-habits')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.habits,
        reason: '点习惯入口必须真的导航到习惯页，否则入口是摆设',
      );
      expect(find.text('weekly report'), findsOneWidget);
    });

    testWidgets('未注入 habit 回调时习惯页仍可浏览（只读不炸）', (tester) async {
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/api/habits',
            (server) => server.reply(200, {
              'items': [habitJson()],
            }),
            queryParameters: {'limit': 50, 'offset': 0},
          );
          adapter.onGet(
            '/api/habits/runs',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'limit': 50},
          );
        },
      );

      h.router.go(SpbRoutes.habits);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(tester.takeException(), isNull);
      expect(find.text('weekly report'), findsOneWidget);
    });
  });
  group('侧边栏（桌面端接线：交付物 / 待办 / 目标 / 任务 / 续跑 / 诊断）', () {
    /// 进入对话页并补齐必要的 mock（/me + timeline + pending）。返回 fake UFS API
    /// 以观察侧边栏的取数。
    Future<FakeUfsApi> openChat(
      WidgetTester tester,
      SseClient sse, {
      String groupId = 'grp_x',
    }) async {
      final ufs = FakeUfsApi();
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat(groupId),
        mockGroups: false,
        sseClient: sse,
        ufsApi: ufs,
        beforePump: (adapter) {
          adapter.onGet(
            '/api/auth/me',
            (server) => server.reply(200, {
              'id': 'usr_REAL',
              'email': 'a@b.c',
              'name': 'Test',
              'role': 'member',
              'roles': ['member'],
              'permissions': <String>[],
              'status': 'active',
            }),
          );
          adapter.onGet(
            '/chat/groups/$groupId/timeline',
            (server) => server.reply(200, {
              'items': <Map<String, dynamic>>[],
              'next_before_global_seq': '',
            }),
            queryParameters: {'limit': 200},
          );
          adapter.onGet(
            '/users/usr_REAL/chat/messages/pending',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'group_id': groupId, 'limit': 20},
          );
        },
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      return ufs;
    }

    /// 把 tab 条横向滚到露出 [label] 那个 tab。
    ///
    /// ## 为什么必须滚动
    ///
    /// 侧边栏宽 320px，tab 条是**横向可滚的** `ListView.builder`。它的子项是
    /// **懒构建**的：超出 `cacheExtent`（默认 250px）的 tab 根本不在树里，
    /// `find.byKey` 会得到 0 个——那不是「tab 被删了」，而是「还没构建」。
    /// tab 数量增加到 7 个后，「诊断」正好落到可视区 + cacheExtent 之外。
    ///
    /// 故断言尾部 tab 之前必须先滚到它——`scrollUntilVisible` 会驱动
    /// `ListView` 构建出目标项。真实用户横向滚动一下也能看到，这是
    /// **测试驱动方式的问题，不是 UI 缺陷**。
    Future<void> revealTab(WidgetTester tester, String label) async {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('sidebar-tab-$label')),
        80,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('sidebar-tabbar')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('默认不展开：开关存在但侧边栏不可见，未取数', (tester) async {
      final sse = FakeSseClient();
      final ufs = await openChat(tester, sse);

      // AppBar 里有侧边栏开关。
      final toggle = find.byKey(const ValueKey('toggle-deliverables'));
      expect(toggle, findsOneWidget);

      // 未取数：侧边栏默认折叠，autoDispose provider 不该被读。
      expect(ufs.listCalls, isEmpty);
      // 侧边栏 tab 也不在。
      expect(find.text('交付物'), findsNothing);
    });

    testWidgets('点开关展开侧边栏，按 group 前缀取数并渲染文件', (tester) async {
      final sse = FakeSseClient();
      final ufs = await openChat(tester, sse);
      ufs.entries = [ufsFile('grp_x', 'README.md')];

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      // 取数时用 group workspace 前缀。
      expect(ufs.listCalls, contains('/workspace/groups/grp_x'));
      // 文件名出现在侧边栏。
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('交付物'), findsOneWidget);
    });

    testWidgets('再点开关收起侧边栏', (tester) async {
      final sse = FakeSseClient();
      await openChat(tester, sse);

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();
      expect(find.text('交付物'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();
      expect(find.text('交付物'), findsNothing);
    });

    testWidgets('展开后各 tab 齐全（交付物 / 待办 / 设置 / 目标 / 任务 / 续跑 / 诊断）', (
      tester,
    ) async {
      final sse = FakeSseClient();
      await openChat(tester, sse);

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sidebar-tab-交付物')), findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar-tab-待办')), findsOneWidget);
      // 尾部 tab 在 320px 侧边栏里落在可视区外（tab 条横向可滚且懒构建），
      // 断言前先滚到它们。
      await revealTab(tester, '目标');
      expect(find.byKey(const ValueKey('sidebar-tab-目标')), findsOneWidget);
      await revealTab(tester, '续跑');
      expect(find.byKey(const ValueKey('sidebar-tab-续跑')), findsOneWidget);
      await revealTab(tester, '诊断');
      expect(find.byKey(const ValueKey('sidebar-tab-诊断')), findsOneWidget);
    });

    /// 把 tab 条横向滚到露出 [label] 那个 tab，然后点它。
    Future<void> tapTab(WidgetTester tester, String label) async {
      await revealTab(tester, label);
      await tester.tap(find.byKey(ValueKey('sidebar-tab-$label')));
      await tester.pumpAndSettle();
    }

    testWidgets('收起再展开侧边栏：滚动位置与选中的 tab 都保留', (tester) async {
      // ## 本用例防的是什么（2026-10 用户报障）
      //
      // 「切换侧边栏后滚动条位置会重新置顶」。根因是收起时
      // `if (!_showSidebar) return conversation;` 把整个 `ChatSidebar`
      // 从树里移除 → 所有面板的 Element 被销毁 → 再展开是全新的
      // `ListView`（`ScrollPosition.pixels` 归零），且 `_ChatSidebarState._index`
      // 也重置回第一个 tab。
      //
      // 修法是 `Offstage` 保留挂载。实测 `RenderOffstage.performLayout` 在
      // offstage 时**仍会 layout 子树**，只跳过 paint/hitTest/语义——故
      // State、Element、RenderObject、ScrollPosition 全部活着。
      //
      // ## 为什么必须在 router 层断言
      //
      // `ChatSidebar` 自己的测试用 `IndexedStack` 切换 tab，那里本来就不销毁
      // 子树（已绿）。真正的缺陷在**装配层**的「收起即移除」——页面级测试
      // 覆盖不到（与 §6.17 / §6.43 同一失败模式）。
      final sse = FakeSseClient();
      final ufs = await openChat(tester, sse);

      // 造足够多的文件，让交付物列表可滚动。
      ufs.entries = [
        for (var i = 0; i < 40; i++) ufsFile('grp_x', 'report-$i.md'),
      ];

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      // 切到「待办」tab（第二个），记下它。
      // 无待办时渲染的是 `todos-empty` 占位（不是 `todos-list`）。
      await tapTab(tester, '待办');
      expect(
        find.byKey(const ValueKey('todos-empty')),
        findsOneWidget,
        reason: '切到待办 tab 后应渲染其内容',
      );

      // 收起 → 展开。
      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      // 1) 选中的 tab 仍是「待办」（修复前会重置回「交付物」）。
      expect(
        find.byKey(const ValueKey('todos-empty')),
        findsOneWidget,
        reason: '收起再展开后应仍停在「待办」tab，而不是重置回「交付物」',
      );
      expect(
        find.byKey(const ValueKey('deliverables-tree')),
        findsNothing,
        reason: '不应退回「交付物」tab（它的树在待办 tab 下是 offstage）',
      );

      // 2) 没有重新取数（子树没被销毁 → initState 不会再跑）。
      final callsAfterRoundtrip = ufs.listCalls.length;
      expect(callsAfterRoundtrip, 1, reason: '收起再展开不应重新拉交付物清单（修复前会多一次）');
    });

    testWidgets('收起侧边栏后交付物树仍挂载（滚动位置不丢）', (tester) async {
      final sse = FakeSseClient();
      final ufs = await openChat(tester, sse);
      ufs.entries = [
        for (var i = 0; i < 60; i++) ufsFile('grp_x', 'report-$i.md'),
      ];

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      final tree = find.byKey(const ValueKey('deliverables-tree'));
      final scrollable = find.descendant(
        of: tree,
        matching: find.byType(Scrollable),
      );

      await tester.drag(tree, const Offset(0, -400));
      await tester.pumpAndSettle();
      final before = tester.state<ScrollableState>(scrollable).position.pixels;
      expect(before, greaterThan(0), reason: '先确认真的滚动了');

      // 收起 → 展开。
      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      final after = tester.state<ScrollableState>(scrollable).position.pixels;
      expect(after, before, reason: '收起再展开后滚动位置应保留（修复前归零，这正是用户报障现象）');
    });

    testWidgets('无待确认项时待办 tab 显示空提示，且不带徽标', (tester) async {
      final sse = FakeSseClient();
      await openChat(tester, sse);

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      // 无待办 → 无徽标（badge 0 不渲染）。
      expect(find.byKey(const ValueKey('sidebar-tab-待办')), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('门控关闭（发布构建）时「诊断」tab 整个消失，其余 tab 仍在', (tester) async {
      // ## 这个用例防的是什么
      //
      // 诊断面板展示工具调用入参与 gate 决策明细，是内部视图，不应随发布包
      // 分发。但此前全仓没有任何 `kReleaseMode` / `isRelease` 使用——发布包里
      // 它照样在。
      //
      // ## 为什么能在这里断言
      //
      // 若门控写成 `if (!SpbEnv.isRelease)`，测试跑在 JIT 下 `isRelease` 恒为
      // false，这个行为**根本无法验证**。故门控走 provider，测试可以把它置为
      // false（等价于发布构建）。
      final sse = FakeSseClient();
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_x'),
        mockGroups: false,
        sseClient: sse,
        ufsApi: FakeUfsApi(),
        showDebugPanel: false,
        beforePump: (adapter) {
          adapter.onGet(
            '/api/auth/me',
            (server) => server.reply(200, {
              'id': 'usr_REAL',
              'email': 'a@b.c',
              'name': 'Test',
              'role': 'member',
              'roles': ['member'],
              'permissions': <String>[],
              'status': 'active',
            }),
          );
          adapter.onGet(
            '/chat/groups/grp_x/timeline',
            (server) => server.reply(200, {
              'items': <Map<String, dynamic>>[],
              'next_before_global_seq': '',
            }),
            queryParameters: {'limit': 200},
          );
          adapter.onGet(
            '/users/usr_REAL/chat/messages/pending',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'group_id': 'grp_x', 'limit': 20},
          );
        },
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('sidebar-tab-诊断')),
        findsNothing,
        reason: '发布包不该暴露工具调用与 gate 决策诊断',
      );
      expect(
        find.byKey(const ValueKey('debug-panel')),
        findsNothing,
        reason: '面板本身也必须不在树里（不只是 tab 按钮隐藏）',
      );
      // 其余 tab 不受影响（门控只该拿掉诊断那一个）。
      expect(find.byKey(const ValueKey('sidebar-tab-交付物')), findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar-tab-待办')), findsOneWidget);
      await revealTab(tester, '续跑');
      expect(find.byKey(const ValueKey('sidebar-tab-续跑')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sidebar-tab-诊断')),
        findsNothing,
        reason: '滚到尾部后诊断仍不该存在',
      );
      // 默认落点仍是第一个 tab（删掉尾部 tab 不改索引语义）：
      // IndexedStack 显示的是 index 0 的「交付物」，其空态已渲染。
      final stack = tester.widget<IndexedStack>(
        find.byKey(const ValueKey('sidebar-content')),
      );
      expect(
        stack.index,
        0,
        reason: 'tabs 变短不该改变默认落点（initialIndex 语义与 tab 数量无关）',
      );
      expect(find.byKey(const ValueKey('deliverables-empty')), findsOneWidget);
    });

    testWidgets('门控打开（开发构建）时「诊断」tab 仍在', (tester) async {
      // 与上一条成对：证明「tab 消失」确实来自门控，而不是别的原因（例如
      // tab 被误删、或被挤出可视区而 find 不到——后者要靠滚动才可见，
      // 但 `findsOneWidget` 检查的是挂载，不是可见）。
      final sse = FakeSseClient();
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_x'),
        mockGroups: false,
        sseClient: sse,
        ufsApi: FakeUfsApi(),
        showDebugPanel: true,
        beforePump: (adapter) {
          adapter.onGet(
            '/api/auth/me',
            (server) => server.reply(200, {
              'id': 'usr_REAL',
              'email': 'a@b.c',
              'name': 'Test',
              'role': 'member',
              'roles': ['member'],
              'permissions': <String>[],
              'status': 'active',
            }),
          );
          adapter.onGet(
            '/chat/groups/grp_x/timeline',
            (server) => server.reply(200, {
              'items': <Map<String, dynamic>>[],
              'next_before_global_seq': '',
            }),
            queryParameters: {'limit': 200},
          );
          adapter.onGet(
            '/users/usr_REAL/chat/messages/pending',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'group_id': 'grp_x', 'limit': 20},
          );
        },
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      // 诊断在 tab 条尾部，懒构建，先滚到它。
      await revealTab(tester, '诊断');
      expect(
        find.byKey(const ValueKey('sidebar-tab-诊断')),
        findsOneWidget,
        reason: '开发构建下诊断入口必须可用',
      );
    });

    testWidgets('切到诊断 tab 显示工具调用 + gate 面板（两者空态）', (tester) async {
      final sse = FakeSseClient();
      await openChat(tester, sse);

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();
      await tapTab(tester, '诊断');

      // 诊断 tab = 工具调用 + gate 决策上下分栏（对齐 webapp 的 debug tab）。
      expect(find.byKey(const ValueKey('debug-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('toolcalls-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('gate-empty')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('目标历史 tab 已接线（列出历史目标）', (tester) async {
      final sse = FakeSseClient();
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_x'),
        mockGroups: false,
        sseClient: sse,
        ufsApi: FakeUfsApi(),
        beforePump: (adapter) {
          adapter.onGet(
            '/api/auth/me',
            (server) => server.reply(200, {
              'id': 'usr_REAL',
              'email': 'a@b.c',
              'name': 'Test',
              'role': 'member',
              'roles': ['member'],
              'permissions': <String>[],
              'status': 'active',
            }),
          );
          adapter.onGet(
            '/chat/groups/grp_x/timeline',
            (server) => server.reply(200, {
              'items': <Map<String, dynamic>>[],
              'next_before_global_seq': '',
            }),
            queryParameters: {'limit': 200},
          );
          adapter.onGet(
            '/users/usr_REAL/chat/messages/pending',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'group_id': 'grp_x', 'limit': 20},
          );
          // 历史目标列表（`GET /chat/groups/:id/goals`）——独立于 group 快照。
          adapter.onGet(
            '/chat/groups/grp_x/goals',
            (server) => server.reply(200, {
              'items': [
                {
                  'id': 'goal_1',
                  'group_id': 'grp_x',
                  'goal_text': '把 CI 修绿',
                  'status': 'active',
                  'tasks_source': 'manual',
                  'created_at': '2024-03-05T08:00:00Z',
                  'updated_at': '2024-03-05T08:00:00Z',
                },
              ],
            }),
            queryParameters: {'limit': 50},
          );
        },
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();
      await tapTab(tester, '目标');

      expect(
        find.text('把 CI 修绿'),
        findsOneWidget,
        reason: 'listGoals 已接线（此前全仓零引用）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('收起按钮（侧边栏头部）也能关闭侧边栏', (tester) async {
      final sse = FakeSseClient();
      await openChat(tester, sse);

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('sidebar-close')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sidebar-tab-交付物')), findsNothing);
    });
  });
  group('任务编辑接线（updateTask 走真实 router 装配）', () {
    /// 断言「router 真的把 onUpdateTask 接上了」。
    ///
    /// ## 为什么必须打真实 router
    ///
    /// 面板自身的测试（`goal_tasks_panel_test.dart`）用的是**手工构造的**
    /// 回调——它能验证面板行为，但无法发现「router 忘了注入 onUpdateTask」
    /// 这种错误，而那正是本仓库最常见的失败模式（能力实现了但没人调用：
    /// `updateTask` 此前全仓零引用）。故这里打 HTTP，断言请求真的发出去了。
    testWidgets('点编辑改标题保存 → PATCH 带新标题', (tester) async {
      final patch = <({String path, Object? body})>[];
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_x'),
        mockGroups: false,
        sseClient: FakeSseClient(),
        beforePump: (adapter) {
          adapter.onGet(
            '/api/auth/me',
            (server) => server.reply(200, {
              'id': 'usr_REAL',
              'email': 'a@b.c',
              'name': 'Test',
              'role': 'member',
              'roles': ['member'],
              'permissions': <String>[],
              'status': 'active',
            }),
          );
          // 带 current_goal + 一条任务的 group（任务 tab 才有内容可编辑）。
          adapter.onGet(
            '/chat/groups/grp_x',
            (server) => server.reply(200, {
              'id': 'grp_x',
              'user_id': 'usr_REAL',
              'title': '测试对话',
              'active_session': {
                'agent_id': 'agent_a',
                'session_id': 'up_1',
                'role': 'owner',
              },
              'current_goal': {
                'goal': {
                  'id': 'goal_1',
                  'group_id': 'grp_x',
                  'goal_text': '把 CI 修绿',
                  'status': 'active',
                  'tasks_source': 'manual',
                  'created_at': '2024-03-05T08:00:00Z',
                  'updated_at': '2024-03-05T08:00:00Z',
                },
                'tasks': [
                  {
                    'id': 'row_1',
                    'goal_id': 'goal_1',
                    'task_id': 'TASK-001',
                    'order_index': 0,
                    'title': '旧标题',
                    'description': '',
                    'status': 'pending',
                    'origin': 'llm',
                    'edited_by_user': false,
                    'created_at': '2024-03-05T08:00:00Z',
                    'updated_at': '2024-03-05T08:00:00Z',
                  },
                ],
                'progress': {
                  'total': 1,
                  'completed': 0,
                  'in_progress': 0,
                  'blocked': 0,
                  'error_stopped': 0,
                  'pending': 1,
                  'percent': 0,
                },
              },
            }),
          );
          adapter.onGet(
            '/chat/groups/grp_x/timeline',
            (server) => server.reply(200, {
              'items': <Map<String, dynamic>>[],
              'next_before_global_seq': '',
            }),
            queryParameters: {'limit': 200},
          );
          adapter.onGet(
            '/users/usr_REAL/chat/messages/pending',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'group_id': 'grp_x', 'limit': 20},
          );
          adapter.onPatch(
            '/chat/goals/goal_1/tasks/TASK-001',
            (server) => server.replyCallback(200, (options) {
              patch.add((path: options.path, body: options.data));
              return {
                'task': {
                  'id': 'row_1',
                  'goal_id': 'goal_1',
                  'task_id': 'TASK-001',
                  'order_index': 0,
                  'title': '新标题',
                  'description': '',
                  'status': 'pending',
                  'origin': 'llm',
                  'edited_by_user': true,
                  'created_at': '2024-03-05T08:00:00Z',
                  'updated_at': '2024-03-05T08:00:00Z',
                },
              };
            }),
            data: Matchers.any,
          );
        },
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      // 切到「任务」tab（它在 320px 侧边栏里落在可视区外，需先横滚）。
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('sidebar-tab-任务')),
        80,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('sidebar-tabbar')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-tab-任务')));
      await tester.pumpAndSettle();

      // 编辑入口存在（证明 router 注入了 onUpdateTask）。
      expect(
        find.byKey(const ValueKey('goal-task-edit-TASK-001')),
        findsOneWidget,
        reason: '未注入 onUpdateTask 时该按钮整个不渲染',
      );

      await tester.tap(find.byKey(const ValueKey('goal-task-edit-TASK-001')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('goal-task-edit-title')),
        '新标题',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('goal-task-edit-save')));
      await tester.pumpAndSettle();

      expect(patch, hasLength(1), reason: 'updateTask 必须真的发出请求');
      expect(patch.single.path, '/chat/goals/goal_1/tasks/TASK-001');
      final body = patch.single.body as Map<String, dynamic>;
      expect(body['title'], '新标题');
      // '' = 清除（不是 null = 不改）。
      expect(body['description'], '');
      expect(tester.takeException(), isNull);
    });
  });
  group('交付物「已同步则直接打开」（同步索引打通）', () {
    /// 最近一次 [seedSyncState] 建好的库（供 pumpApp 的 database 参数使用）。
    late AppDatabase seededDb;

    /// 建临时同步目录 + 落一个真实文件 + 在库里写入「已同步」记录与目录绑定。
    ///
    /// ## 为什么整段包在 `tester.runAsync` 里
    ///
    /// `testWidgets` 的测试体跑在 `FakeAsync` 区域：真实文件 IO（
    /// `createTemp` / `writeAsString`）与真实事件循环绑定，fake 时钟不会推进它，
    /// 直接 `await` 会**挂死**（实测：10 分钟超时后才报 `TimeoutException`）。
    /// `runAsync` 临时切回真实异步，专用于这类测试前置副作用。
    ///
    /// ## 为什么要落**真实文件**
    ///
    /// provider 会 `File(abs).existsSync()` 校验（索引记的是「曾经同步过」，
    /// 用户可能手动删了）。不建真文件的话菜单项恒为禁用，用例会以
    /// 「实现看起来没生效」的形式失败。
    Future<Directory> seedSyncState(
      WidgetTester tester, {
      required String gid,
      required String rel,
      bool markSynced = true,
    }) async {
      late Directory root;
      late AppDatabase db;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('spb-sync-');
        if (markSynced) {
          final file = File(p.join(root.path, gid, rel));
          await file.parent.create(recursive: true);
          await file.writeAsString('# 已同步的交付物\n');
        }
        db = AppDatabase(NativeDatabase.memory());
        final store = DriftSyncStateStore(db);
        // 先绑目录再写状态：bindLocalRoot 在目录**变化**时会清空状态，
        // 顺序反了会把刚写入的记录清掉。
        await store.bindLocalRoot(root.path);
        if (markSynced) {
          await store.save(
            workspaceStateKey,
            SyncState(
              cursor: '2026-01-01T00:00:00Z',
              files: {'$gid/$rel': const SyncedFile(size: 21)},
            ),
          );
        }
      });
      // 同步删除（不用异步版本）：tearDown 阶段可能已不在 runAsync 区域内。
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
        db.close();
      });
      // 把 db 也带出去：pumpApp 要它作为 appDatabaseProvider 的 override。
      seededDb = db;
      return root;
    }

    group('离线写队列装配（issue #30）', () {
      testWidgets('outboxQueueProvider 用注入的 AppDatabase（同一内存库）', (
        tester,
      ) async {
        // ## 这条为什么值得单独测
        //
        // 装配层的错误（provider 忘了 override、或指向了另一个 db）在单测里
        // 全都看不见：`spb_domain` 的队列测试用内存 store，`spb_data` 的
        // store 测试用内存 db，只有这里才验证「两者真的接在一起」。
        //
        // 反向验证：把 `outboxStoreProvider` 的 `appDatabaseProvider` 换成
        // 新开的 `AppDatabase(NativeDatabase.memory())`，本用例会失败。
        final harness = await pumpApp(tester);
        final queue = harness.container.read(outboxQueueProvider);
        expect(queue, isNotNull);

        // store 确实用的是注入的那个 db：直接写一行，再让队列 load 出来。
        await tester.runAsync(() async {
          await DriftOutboxStore(harness.container.read(appDatabaseProvider))
              .upsert(
                OutboxEntry(
                  id: 'req-装配',
                  userId: 'usr_REAL',
                  input: '装配层验证',
                  createdAt: DateTime.utc(2026),
                  nextAttemptAt: DateTime.utc(2026),
                ),
              );
          await queue.load('usr_REAL');
        });
        expect(queue.snapshot.map((e) => e.input), ['装配层验证']);

        await queue.dispose();
      });

      test('outboxQueueProvider **不**是 autoDispose（重试计时器要活过对话页）', () {
        // ## 为什么判据是 `isAutoDispose` 而不是别的
        //
        // Riverpod 3 里 `Provider.autoDispose(...)` 返回的**也是** `Provider`
        // （只是 `isAutoDispose: true`），故静态类型断言没有区分力。运行期判据
        // 也踩过两个坑：
        //  - `identical(read(), read())`：`read` 不留监听者，而 autoDispose 的
        //    释放条件是「没有监听者」——autoDispose 在 read 路径上根本不会被
        //    回收，两种实现都恒等（空转）；
        //  - 「释放监听后看 `entries` 是否 done」：会把测试拖进 Riverpod 的
        //    调度细节，实测直接挂死。
        //
        // `isAutoDispose` 是 Riverpod 自己的字段，正是我们要表达的那个语义。
        //
        // 语义：队列持有重试计时器，而 `chatStreamControllerProvider` 是
        // `autoDispose.family`（离开对话页即释放）。队列若随页面释放，用户
        // 「断网发一条 → 退出对话 → 网络恢复」后消息永远不会被重试。
        expect(
          outboxQueueProvider.isAutoDispose,
          isFalse,
          reason: '改成 Provider.autoDispose 会让重试计时器随页面一起消失',
        );
      });
    });

    /// 进入某个 group 的对话页所需的 mock（含侧边栏依赖的两个端点）。
    void mockChat(DioAdapter adapter, String gid) {
      adapter.onGet(
        '/api/auth/me',
        (server) => server.reply(200, {
          'id': 'usr_REAL',
          'email': 'a@b.c',
          'name': 'Test',
          'role': 'member',
          'roles': ['member'],
          'permissions': <String>[],
          'status': 'active',
        }),
      );
      adapter.onGet(
        '/chat/groups/$gid/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );
      adapter.onGet(
        '/users/usr_REAL/chat/messages/pending',
        (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
        queryParameters: {'group_id': gid, 'limit': 20},
      );
    }

    testWidgets('已同步的交付物不触发下载即可打开', (tester) async {
      const gid = 'grp_sync';
      const rel = 'reports/spec.md';
      final root = await seedSyncState(tester, gid: gid, rel: rel);

      final sse = FakeSseClient();
      final caps = FakeDesktopCapabilities();
      final ufs = FakeUfsApi();
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat(gid),
        mockGroups: false,
        sseClient: sse,
        ufsApi: ufs,
        capabilities: caps,
        database: seededDb,
        beforePump: (adapter) => mockChat(adapter, gid),
      );
      ufs.entries = [ufsFile(gid, rel)];

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();
      expect(find.text('spec.md'), findsOneWidget);

      // 不点「下载」，直接打开。
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      final item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '用默认程序打开'),
      );
      expect(item.enabled, isTrue, reason: '已同步的文件应可直接打开（无需下载）');

      await tester.tap(find.text('用默认程序打开'));
      await tester.pumpAndSettle();

      expect(caps.openedPaths, hasLength(1));
      expect(caps.openedPaths.single, p.join(root.path, gid, rel));
      // 关键断言：没有发生下载（UFS 下载端点一次都没被请求）。
      expect(ufs.downloadCalls, isEmpty, reason: '已同步的文件不应触发下载');
    });

    testWidgets('已同步的交付物可直接「定位」（不触发下载，且传的是文件路径）', (tester) async {
      // ## 这条防的是什么
      //
      // 修复前「在文件管理器中定位」对**文件**恒失败：`revealPath` 用
      // `Directory(path).exists()` 校验，而它对文件恒为 false（实测）——
      // 于在 spawn 之前就返回了，用户看到「无法定位文件」。
      //
      // 这里从**真实 router 装配**出发（不是页面测试自己传参），断言
      // `caps.revealedPaths` 收到的是**文件的绝对路径**。
      const gid = 'grp_sync_reveal';
      const rel = 'reports/spec.md';
      final root = await seedSyncState(tester, gid: gid, rel: rel);

      final sse = FakeSseClient();
      final caps = FakeDesktopCapabilities();
      final ufs = FakeUfsApi();
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat(gid),
        mockGroups: false,
        sseClient: sse,
        ufsApi: ufs,
        capabilities: caps,
        database: seededDb,
        beforePump: (adapter) => mockChat(adapter, gid),
      );
      ufs.entries = [ufsFile(gid, rel)];

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('在文件管理器中定位'));
      await tester.pumpAndSettle();

      expect(caps.revealedPaths, hasLength(1));
      expect(caps.revealedPaths.single, p.join(root.path, gid, rel));
      expect(ufs.downloadCalls, isEmpty, reason: '已同步的文件不应触发下载');
    });
  });
  group('导入会话（粘贴凭证 → 落盘 → 请求带 Bearer）', () {
    testWidgets('导入合法会话后状态变为已登录', (tester) async {
      // 端到端验证桌面端登录闭环：这是全仓库最高价值的缺口——SSO 在系统浏览器
      // 完成，Flutter 读不到浏览器 Cookie，故「粘贴导入」是唯一入口。
      final store = InMemoryTokenStore();
      final h = await pumpApp(
        tester,
        tokenStore: store,
        initialLocation: SpbRoutes.login,
      );

      expect(
        h.container.read(authStateProvider).isAuthenticated,
        isFalse,
        reason: '前置条件：导入前必须是未登录，否则本用例空洞通过',
      );

      final err = await h.container
          .read(authControllerProvider)
          .importSession('id_token=test-id-token; refresh_token=test-refresh');

      expect(err, isNull, reason: '合法凭证不该报错');
      expect(
        h.container.read(authStateProvider).isAuthenticated,
        isTrue,
        reason: '导入后必须变为已登录，否则用户仍被守卫挡在登录页',
      );

      final stored = await store.read();
      expect(stored!.accessToken, 'test-id-token');
      expect(stored.refreshToken, 'test-refresh');
    });

    testWidgets('导入后请求头带上 Authorization: Bearer <token>', (tester) async {
      // 这是「闭环」的最后一环：光落盘不够，请求必须真的带上凭证，
      // 否则服务端仍然 401，用户看到的还是登录页。
      //
      // ## 为什么不能用 `pumpApp` 的 harness
      //
      // `pumpApp` 把 `dioProvider` override 成裸 dio（只挂 `DioAdapter`，
      // **没有 AuthInterceptor**）——那套 dio 是为了让页面里的请求可被 mock。
      // 用它断言「带 Bearer」是**空洞**的：拦截器根本不在链上（实测
      // `Authorization` 恒为 null）。
      //
      // 故这里自建容器，**只** override 凭证存储，让 `dioProvider` 用生产实现
      // （带真实 `AuthInterceptor`）。这才能证明「凭证 → 请求头」真的通。
      final store = InMemoryTokenStore();
      final container = ProviderContainer(
        overrides: [tokenStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      final dio = container.read(dioProvider);
      final adapter = DioAdapter(dio: dio);
      addTearDown(dio.close);

      final seen = <String, String?>{};
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            seen['Authorization'] = options.headers['Authorization'] as String?;
            seen['X-User-ID'] = options.headers['X-User-ID'] as String?;
            handler.next(options);
          },
        ),
      );

      // ## 必须先等启动时的 restore() 落定（这是**真实的竞态**，不是测试噪音）
      //
      // `AuthStateNotifier.build()` 会 `unawaited(restore())`。那一刻 store 还是
      // 空的，于是这次 restore 会走「清理残留凭证」分支：它 await 完
      // `currentAccessToken()` 后**再次读 store**，若此时已经不为空（比如我们
      // 刚导入完），就判定为「残留」并调 `logout()` —— **把刚写入的凭证清掉**。
      //
      // 实测：不等的话 `importSession` 返回 null（成功）但 store 立刻变空。
      // 真实使用中用户不可能在启动那一瞬完成粘贴，故影响可忽略；但测试必须
      // 建立确定的前置状态，否则断言毫无意义。
      await tester.runAsync(() async {
        while (container.read(authStateProvider).status == AuthStatus.unknown) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });

      final err = await container
          .read(authControllerProvider)
          .importSession('id_token=test-id-token');
      expect(err, isNull, reason: '前置条件：导入必须成功');
      expect(
        (await store.read())?.accessToken,
        'test-id-token',
        reason: '凭证必须真的落盘，否则后面的请求头断言是空洞的',
      );

      adapter.onGet(
        '/chat/groups',
        (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
        queryParameters: {'limit': 50, 'offset': 0},
      );

      // 必须包在 `runAsync` 里：内部 await 一个 dio 请求，而 dio 的 mock
      // 响应依赖真实 Timer——widget test 的假时钟不会推进它（实测：不包会
      // 卡满 10 分钟超时）。仓库内既有用例已记录同一陷阱。
      await tester.runAsync(() => container.read(chatApiProvider).listGroups());

      expect(
        seen.containsKey('Authorization'),
        isTrue,
        reason: '请求必须真的发出，否则下面的断言是空洞的',
      );
      expect(
        seen['Authorization'],
        'Bearer test-id-token',
        reason: '凭证必须出现在 Authorization 头，否则服务端仍 401',
      );
      expect(seen['X-User-ID'], isNull, reason: '客户端不得自选身份（X-User-ID 由网关注入）');
    });

    testWidgets('认不出的内容报错且不落盘（不造无效凭证）', (tester) async {
      final store = InMemoryTokenStore();
      final h = await pumpApp(tester, tokenStore: store);

      // 注意：不能拿「一个随便的单词」当反例——单段且无 `=` 的输入会被当作
      // **裸 token**（那是受支持的形态）。真正的反例是「有键值对但没有可用
      // 的 token 键」。
      final err = await h.container
          .read(authControllerProvider)
          .importSession('session_id=abc; csrf=def');

      expect(err, isNotNull, reason: '必须给出可操作的错误，而不是静默失败');
      expect(
        await store.read(),
        isNull,
        reason: '认不出时绝不能落盘——那会造出一个「已登录但请求全 401」的假状态',
      );
      expect(h.container.read(authStateProvider).isAuthenticated, isFalse);
    });

    testWidgets('登录页展示导入入口与输入框', (tester) async {
      await pumpApp(
        tester,
        tokenStore: InMemoryTokenStore(),
        initialLocation: SpbRoutes.login,
      );

      expect(
        find.byKey(const ValueKey('login-import-session')),
        findsOneWidget,
        reason: '桌面端必须有这个入口，否则登录无法闭环',
      );

      // 默认收起：SSO 是主路径，导入是备选。
      expect(find.byKey(const ValueKey('login-import-field')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('login-import-session')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-import-field')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('login-import-confirm')),
        findsOneWidget,
      );
    });
  });
}
