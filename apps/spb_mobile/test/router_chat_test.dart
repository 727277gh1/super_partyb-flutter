import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_features/spb_features.dart';

import 'package:spb_mobile/providers.dart';
import 'package:spb_mobile/router.dart';

import 'support/mobile_harness.dart';

/// 悬浮输入窗 / 小程序工作台 / 任务编辑 / 登录重定向 / 停止生成 / 反馈 / 重连
///
/// ⚠️ 本文件由 `widget_test.dart` 按顶层用例边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/mobile_harness.dart`。
void main() {
  group('带附件的悬浮输入窗（/overlay）', () {
    /// 造一个真实存在的临时文件并 mock 系统文件选择器返回它。
    ///
    /// ## 为什么要用**真实文件**而不是 `DroppedFile.fromBytes`
    ///
    /// 本组要验证的是「文件选择器 → 附件列表 → 提交带 file_id」这条**移动端
    /// 特有**的链路（手机没有拖拽）。文件选择器只能返回磁盘路径，而
    /// `_addFiles` 会读 `length()`——文件不存在会被标记 size=-1 并禁用提交。
    /// 用字节来源就绕过了「路径从哪来」这个正是被测的环节。
    ({Directory dir, File file}) makeTempFile(String name) {
      final dir = Directory.systemTemp.createTempSync('mobile-overlay');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/$name')
        ..writeAsBytesSync(List.filled(32, 7));
      return (dir: dir, file: file);
    }

    /// mock `file_selector` 的通道，让它返回 [paths]。
    ///
    /// 通道名与 method 取自 `file_selector_platform_interface` 的
    /// `MethodChannelFileSelector`（`plugins.flutter.io/file_selector` +
    /// `openFile`）。移动端无原生侧，不 mock 的话会抛
    /// MissingPluginException 并被 `pickFilesForOverlay` 静默吞成空列表——
    /// 用例会以「没添加任何附件」的形式失败，而看不出根因。
    void mockFileSelector(WidgetTester tester, List<String> paths) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        (call) async => call.method == 'openFile' ? paths : null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          null,
        );
      });
    }

    testWidgets('/overlay 渲染带附件的输入窗（附件入口可用，不带标签栏）', (tester) async {
      final h = await pumpApp(tester);

      h.router.go(SpbRoutes.overlay);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('overlay-input')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('overlay-attach')),
        findsOneWidget,
        reason: '移动端无拖拽，但有系统文件选择器——这个入口必须存在',
      );
      // 移动端注入 NoopDragDropCapability（不伪造拖拽），故不展示拖拽区。
      // 但附件功能不受影响：按钮走 pickFilesForOverlay。
      expect(find.textContaining('拖入'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing, reason: '整屏临时页不应占据标签分支');
    });

    testWidgets('点「添加文件」→ 选中的文件进入待发列表', (tester) async {
      final tmp = makeTempFile('报告.pdf');
      mockFileSelector(tester, [tmp.file.path]);
      final h = await pumpApp(tester);

      h.router.go(SpbRoutes.overlay);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('overlay-attach')));
      // ⚠️ 必须 runAsync：`_addFiles` 里的 `f.length()` 是真实文件 I/O，
      // 而 testWidgets 跑在 fake async 里，真实 I/O 的 Future 不会被推进。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('报告.pdf'),
        findsOneWidget,
        reason: '选中的文件必须出现在附件列表（说明文件选择器接线生效）',
      );
    });

    testWidgets('带附件提交 → 上传得 file_id 后入队（wire 契约 file_id 必填）', (tester) async {
      final tmp = makeTempFile('截图.png');
      mockFileSelector(tester, [tmp.file.path]);

      // 捕获入队请求体：断言带的是 **file_id**（服务端生成的句柄），
      // 而不是展示用的文件名——后者是历史上出过的错（见 use case 类文档）。
      Map<String, dynamic>? enqueueBody;

      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onPost(
            '/me/quick-capture/attachments',
            (server) => server.reply(201, {
              'file_id': 'ufs_file_abc',
              'file_name': '截图.png',
              'size': 32,
              'mime_type': 'image/png',
            }),
            data: Matchers.any,
          );
          adapter.onPost(
            '/me/quick-capture/enqueue',
            (server) => server.reply(202, {'accepted': true}),
            data: Matchers.any,
          );
        },
      );
      h.dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/me/quick-capture/enqueue')) {
              enqueueBody = options.data is Map
                  ? Map<String, dynamic>.from(options.data as Map)
                  : null;
            }
            handler.next(options);
          },
        ),
      );

      h.router.go(SpbRoutes.overlay);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('overlay-attach')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      // 只有附件、无文本，也应可提交。
      await tester.tap(find.byKey(const ValueKey('overlay-submit')));
      // ⚠️ 必须 runAsync：提交走 `MultipartFile.fromFile`，从磁盘**真实读**
      // 文件；fake async 不会推进这类 I/O，pumpAndSettle 会一直等到超时。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();

      expect(enqueueBody, isNotNull, reason: '提交必须真的发出入队请求（否则附件上传了却没投递）');
      expect(enqueueBody!['attachments'], [
        'ufs_file_abc',
      ], reason: '附件必须用服务端返回的 file_id 作句柄，而不是文件名或路径');
    });
  });
  group('小程序工作台路由（/miniapp/*，整屏页在 shell 之外）', () {
    testWidgets('/miniapp/works 渲染工作列表且不带底部标签栏', (tester) async {
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {
              'items': [
                {
                  'id': 'w1',
                  'title': '移动端工作',
                  'status': 'running',
                  'status_label': '运行中',
                  'progress': {'total': 2, 'completed': 1, 'percent': 50},
                  'pending_confirmation_count': 0,
                  'latest_summary': null,
                  'latest_artifact': null,
                  'created_at': '2024-03-05T08:09:10Z',
                  'updated_at': '2024-03-05T08:09:12Z',
                },
              ],
            }),
            queryParameters: {'status': 'active', 'limit': 20},
          );
        },
      );

      h.router.go(SpbRoutes.works);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('移动端工作'), findsOneWidget);
      expect(find.text('运行中'), findsOneWidget);
      // 整屏页：不应带底部标签栏（沿用 quick-capture 的先例）。
      expect(
        find.byType(NavigationBar),
        findsNothing,
        reason: '工作台是整屏页，不应占据标签分支',
      );
    });

    testWidgets('点工作条目进入 /miniapp/works/:workId 详情', (tester) async {
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {
              'items': [
                {
                  'id': 'grp_w9',
                  'title': '报表工作',
                  'status': 'running',
                  'status_label': '运行中',
                  'progress': {'total': 1, 'completed': 0, 'percent': 0},
                  'pending_confirmation_count': 0,
                  'created_at': '2024-03-05T08:09:10Z',
                  'updated_at': '2024-03-05T08:09:12Z',
                },
              ],
            }),
            queryParameters: {'status': 'active', 'limit': 20},
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_w9',
            (server) => server.reply(200, {
              'work': {
                'id': 'grp_w9',
                'title': '报表工作',
                'status': 'running',
                'status_label': '运行中',
                'progress': {'total': 1, 'completed': 0, 'percent': 0},
                'steps': <Map<String, dynamic>>[],
                'pending_confirmations': <Map<String, dynamic>>[],
                'artifacts': <Map<String, dynamic>>[],
                'recent_events': <Map<String, dynamic>>[],
                'can_send_message': true,
                'can_stop': true,
                'can_complete': true,
              },
            }),
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_w9/events',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'limit': 100},
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_w9/artifacts',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          );
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

    testWidgets('工作台新建：POST /chat/miniapp/works 后进入新工作详情', (tester) async {
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
              'work': {
                'id': 'grp_new',
                'title': '新会话',
                'status': 'running',
                'status_label': '运行中',
                'progress': {'total': 0, 'completed': 0, 'percent': 0},
                'steps': <Map<String, dynamic>>[],
                'pending_confirmations': <Map<String, dynamic>>[],
                'artifacts': <Map<String, dynamic>>[],
                'recent_events': <Map<String, dynamic>>[],
                'can_send_message': true,
                'can_stop': true,
                'can_complete': true,
              },
              'dispatch': null,
            }),
            data: Matchers.any,
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_new',
            (server) => server.reply(200, {
              'work': {
                'id': 'grp_new',
                'title': '新会话',
                'status': 'running',
                'status_label': '运行中',
                'progress': {'total': 0, 'completed': 0, 'percent': 0},
                'steps': <Map<String, dynamic>>[],
                'pending_confirmations': <Map<String, dynamic>>[],
                'artifacts': <Map<String, dynamic>>[],
                'recent_events': <Map<String, dynamic>>[],
                'can_send_message': true,
                'can_stop': true,
                'can_complete': true,
              },
            }),
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_new/events',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'limit': 100},
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_new/artifacts',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          );
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

      expect(createBody, isNotNull, reason: '必须真的发出新建请求');
      expect(
        createBody!.containsKey('template_id'),
        isFalse,
        reason: '服务端 template_id 可选；传空会让 metadata 里多一个无意义的空值',
      );
      expect(
        h.router.state.matchedLocation,
        SpbRoutes.work('grp_new'),
        reason: '新建后应进入新工作详情（新工作标题是占位符，列表里分不出来）',
      );
    });

    testWidgets('工作详情上传：multipart 打到 /works/:id/files，字段名为 file', (
      tester,
    ) async {
      // 断言真实请求形状：服务端 `c.FormFile("file")`，字段名不对会 400
      // 「缺少 file」。这是「上传按钮存在」之外的实质验证。
      final tmp = Directory.systemTemp.createTempSync('mobile-work-upload');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final file = File('${tmp.path}/报告.pdf')
        ..writeAsBytesSync(const [1, 2, 3, 4]);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        (call) async => call.method == 'openFile' ? [file.path] : null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          null,
        );
      });

      String? uploadPath;
      Object? uploadBody;
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          // ⚠️ 三个 GET 必须也 mock：详情页并发拉 detail/events/artifacts，
          // 任一失败就进错误分支（那棵树里**没有**上传按钮），
          // 于是 `tap` 找不到目标、上传链路根本不会触发。
          adapter.onGet(
            '/chat/miniapp/works/grp_up',
            (server) => server.reply(200, {
              'work': {
                'id': 'grp_up',
                'title': '上传用工作',
                'status': 'running',
                'status_label': '运行中',
                'progress': {'total': 0, 'completed': 0, 'percent': 0},
                'steps': <Map<String, dynamic>>[],
                'pending_confirmations': <Map<String, dynamic>>[],
                'artifacts': <Map<String, dynamic>>[],
                'recent_events': <Map<String, dynamic>>[],
                'can_send_message': true,
                'can_stop': true,
                'can_complete': true,
              },
            }),
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_up/events',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'limit': 100},
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_up/artifacts',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          );
          adapter.onPost(
            '/chat/miniapp/works/grp_up/files',
            (server) => server.reply(201, {
              'work_id': 'grp_up',
              'artifact': {
                'id': 'a1',
                'work_id': 'grp_up',
                'name': '报告.pdf',
                'type': 'document',
                'mime_type': 'application/pdf',
                'size_bytes': 4,
                'preview_mode': '',
              },
              'upload': {'relative_path': '报告.pdf'},
            }),
            data: Matchers.any,
          );
        },
      );
      h.dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.contains('/files')) {
              uploadPath = options.path;
              uploadBody = options.data;
            }
            handler.next(options);
          },
        ),
      );

      h.router.go(SpbRoutes.work('grp_up'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      // ⚠️ 整条链路必须在**一个** runAsync 里：平台通道与文件 I/O 只在真实
      // 时区完成；把 tap 留在 FakeAsync 时区会让 await 永远不推进
      // （实测 uploadPath 恒为 null，且页面不报错）。
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('miniapp-work-upload')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(
        uploadPath,
        contains('/chat/miniapp/works/grp_up/files'),
        reason: 'workId 必须来自路由参数（family 键写错会打到别的 work）',
      );
      expect(
        uploadBody,
        isA<FormData>(),
        reason: '必须是 multipart（服务端 c.FormFile 读 multipart 表单）',
      );
      final form = uploadBody! as FormData;
      expect(
        form.files.map((e) => e.key),
        contains('file'),
        reason: '字段名必须叫 file，否则服务端 400「缺少 file」',
      );
    });

    testWidgets('/miniapp/works 与 /miniapp/works/:workId 不互相抢匹配', (
      tester,
    ) async {
      // ## 这个测试防的是什么
      //
      // 两条路径段数不同（2 段 vs 3 段），故当前实现下不会歧义——**实测**
      // 即使把 `:workId` 那条写在前面，`/miniapp/works` 仍匹配到列表页。
      //
      // 这条用例是**回归护栏**：若将来有人把详情页改成 `works` 的嵌套子路由
      // （`path: ':workId'`），或把列表改成通配前缀，就会产生歧义——那时
      // 访问 `/miniapp/works` 可能被详情页抢走，workId 变空串、页面去请求
      // `/works/`，表现为「列表页一打开就是错误」。
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'status': 'active', 'limit': 20},
          );
        },
      );

      h.router.go(SpbRoutes.works);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(h.router.state.matchedLocation, SpbRoutes.works);
      expect(find.byKey(const ValueKey('miniapp-works-page')), findsOneWidget);
    });

    testWidgets('对话列表有工作台入口（点了能到 /miniapp/works）', (tester) async {
      final h = await pumpApp(tester);

      expect(find.byKey(const ValueKey('group-list-works')), findsOneWidget);

      h.router.go(SpbRoutes.works);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(h.router.state.matchedLocation, SpbRoutes.works);
    });
  });
  group('任务编辑接线（updateTask 走真实 router 装配）', () {
    /// 断言移动端的底部弹层真的把 `onUpdateTask` 接上了。
    ///
    /// 与桌面端同名用例同一取向：面板自身测试用手工回调，无法发现「router
    /// 忘了注入」——而那正是本仓库最常见的失败模式（`updateTask` 此前全仓
    /// 零引用）。故这里打 HTTP 断言请求真的发出去了。
    testWidgets('任务清单弹层里点编辑改标题保存 → PATCH 带新标题', (tester) async {
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

      // 打开任务清单底部弹层。
      await tester.tap(find.byKey(const ValueKey('open-goal-tasks')));
      await tester.pumpAndSettle();

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
      expect(body['description'], '');
      expect(tester.takeException(), isNull);
    });
  });
  group('未认证重定向（登录页 + /login 路由）', () {
    testWidgets('未认证访问 / 被重定向到 /login（且不带标签栏）', (tester) async {
      // 回归防线：守卫必须真的生效。若没接上，未登录用户会看到列表页，
      // 然后在里面报一堆 401。
      final h = await pumpApp(
        tester,
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
      );

      expect(h.router.state.matchedLocation, SpbRoutes.login);
      expect(find.byKey(const ValueKey('login-sso-button')), findsOneWidget);
      expect(find.text('使用 SSO 登录'), findsOneWidget);
      // 登录页在 shell 之外：整屏页面不应带底部标签栏。
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('未认证深链 /chat/grp_x 也被重定向到 /login', (tester) async {
      final h = await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_x'),
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
      );

      expect(h.router.state.matchedLocation, SpbRoutes.login);
      expect(find.byKey(const ValueKey('login-sso-button')), findsOneWidget);
    });

    testWidgets('重定向时带上原目标路径（from 参数）', (tester) async {
      final h = await pumpApp(
        tester,
        initialLocation: SpbRoutes.settings,
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
      );

      expect(h.router.state.matchedLocation, SpbRoutes.login);
      expect(h.router.state.uri.queryParameters['from'], SpbRoutes.settings);
    });

    testWidgets('已认证时访问 /login 被送回对话列表', (tester) async {
      final h = await pumpApp(tester, initialLocation: SpbRoutes.login);

      expect(h.router.state.matchedLocation, SpbRoutes.conversations);
      expect(find.byKey(const ValueKey('login-sso-button')), findsNothing);
    });

    testWidgets('登录页点击 SSO 按钮把 signInAction 的失败原因显示出来', (tester) async {
      // 验证「点按钮 → 走 signIn → 失败文案展示」这条链路完整。
      //
      // 注意：移动端真实登录会去打开系统浏览器（平台通道，单测环境不可用），
      // 故这里注入一个返回错误的假实现。真实 `mobileSignIn` 的 URL 构造、
      // state/verifier 暂存、回调解析由 `test/auth_deeplink_test.dart` 覆盖。
      await pumpApp(
        tester,
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
        signInAction: () async =>
            'OIDC client_id 未配置（--dart-define=SPB_OIDC_CLIENT_ID）',
      );

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
      expect(find.textContaining('client_id'), findsOneWidget);
    });

    testWidgets('凭证落盘后状态推进到已登录', (tester) async {
      final store = InMemoryTokenStore();
      final h = await pumpApp(tester, tokenStore: store, mockGroups: false);

      expect(h.container.read(authStateProvider).isUnauthenticated, isTrue);

      await store.write(freshTokens());
      h.container.read(authStateProvider.notifier).signedIn();
      await tester.pumpAndSettle();

      expect(h.container.read(authStateProvider).isAuthenticated, isTrue);
    });
  });

  testWidgets('对话页停止生成：router 把 turnId 接到 POST /chat/turns/:id/cancel', (
    tester,
  ) async {
    // 只验证 **router 的接线**：直接取树上 `ConversationPage` 的回调调一下，
    // 不依赖 SSE 事件（原因见桌面端同一用例的说明：`_focus` 用 `ref.read`、
    // `build` 用 `ref.watch`，对 autoDispose.family 而言不是同一实例，是既有 bug）。
    // 「何时可点、传哪个 turnId」由 spb_features 的测试覆盖。
    final hitPaths = <String>[];
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
        // `replyCallback` 只在**请求真的到达**时被调用，因此记录的路径就是
        // 实际发出的请求（`adapter.history` 存的是**已注册的 mock**）。
        adapter.onPost(
          '/chat/turns/turn_9/cancel',
          (server) => server.replyCallback(200, (options) {
            hitPaths.add(options.path);
            return {'status': 'cancelled'};
          }),
          data: Matchers.any,
        );
      },
    );

    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    final page = tester.widget<ConversationPage>(find.byType(ConversationPage));
    expect(
      page.onCancelTurn,
      isNotNull,
      reason: 'router 必须注入 onCancelTurn，否则页面上不会出现停止按钮',
    );

    // 必须包在 `runAsync` 里：回调内部 await 一个 dio 请求，在 FakeAsync 时区
    // 直接 await 会死锁（dio 的 mock 响应靠真实事件循环完成）。
    await tester.runAsync(() => page.onCancelTurn!('turn_9'));
    await tester.pump();

    expect(hitPaths, [
      '/chat/turns/turn_9/cancel',
    ], reason: 'turnId 必须原样透传到路径，且只发一次请求');
  });

  testWidgets('对话页归属反馈：router 把 token 接到 POST /chat/feedback/:token/resolve', (
    tester,
  ) async {
    // 只验证 **router 的接线**（理由同上一条「停止生成」用例）。
    // 移动端与桌面端共用同一条回执语义：可视化渠道直接解决，不经消息通道。
    final hit = <(String, Object?)>[];
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
        adapter.onPost(
          '/chat/feedback/tok_fb1/resolve',
          (server) => server.replyCallback(200, (options) {
            hit.add((options.path, options.data));
            return <String, dynamic>{};
          }),
          data: Matchers.any,
        );
      },
    );

    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    final page = tester.widget<ConversationPage>(find.byType(ConversationPage));
    expect(
      page.onResolveFeedback,
      isNotNull,
      reason: 'router 必须注入 onResolveFeedback，否则反馈卡按钮会被禁用',
    );

    await tester.runAsync(() async {
      page.onResolveFeedback!('tok_fb1', false);
      // onResolveFeedback 返回 void（页面内 fire-and-forget），真实 dio 往返
      // 需要真实事件循环跑完——短 delay 会拿不到请求。
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(hit, hasLength(1), reason: '必须真的发出一次回执请求');
    expect(hit.single.$1, '/chat/feedback/tok_fb1/resolve');
    expect(hit.single.$2, containsPair('correct', false));
  });

  testWidgets('对话页重连：router 注入 onReconnect 且打到同一条 SSE 连接', (tester) async {
    // 只验证 **router 的接线**：注入的 onReconnect 必须调用**已连接的那个**
    // 控制器的 reconnect()。
    //
    // ## 这条用例抓不住什么（已实测，勿误信）
    //
    // 它**抓不住**「family 键写错成 groupId」：`sseClientProvider` 是跨对话共享
    // 的单例，`reconnect()` 最终就是 `_sse.resume()`，而共享 client 上确实有
    // `_path`——换哪个 family 条目都能连通。故这里不宣称覆盖该场景；键的正确性
    // 靠「注入点与 `ref.watch` 在同一 build 里取自同一变量」来保证（见 router 注释）。
    final sse = FakeSseClient();
    await pumpApp(
      tester,
      initialLocation: SpbRoutes.chat('grp_x'),
      mockGroups: false,
      sseClient: sse,
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

    expect(sse.connectedPaths, [
      '/users/usr_REAL/chat/stream',
    ], reason: '前置条件：必须先真的连上，否则 resume 会早退');

    final page = tester.widget<ConversationPage>(find.byType(ConversationPage));
    expect(
      page.onReconnect,
      isNotNull,
      reason: 'router 必须注入 onReconnect，否则指示器永远不可点',
    );

    page.onReconnect!();
    await tester.pump();

    expect(
      sse.resumeCount,
      1,
      reason: '必须打到已连接的那个控制器（family 键应为 userId，不是 groupId）',
    );
  });
}
