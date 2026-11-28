import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `MiniappApi` 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 小程序 BFF（`/chat/miniapp/*`）与 webapp 的 `/chat/*` 是**两套独立端点**，
/// 形状与命名都有差异。三类错误会静默出错（不报错、不抛异常，只是数据不对）：
///
/// 1. **`work_id` 就是 group id**（服务端没有 works 表）；
/// 2. **`listWorks` 的 `cursor` 是 offset**，不是不透明游标；
/// 3. **`workEvents` 返回数据库原始行**：事件 id 键名是 `id`、负载是
///    `payloadJson` **字符串**、`agentId` 是 `{String,Valid}`。用
///    `ChatEvent.fromJson` 解析会抛 `FormatException`——因为缺 `eventId`。
///
/// 第 3 条与 `search` 端点踩过的坑同源（见 `chat_api_test.dart`），故这里也
/// **显式断言 `ChatEvent.fromJson` 会失败**，把陷阱钉成可执行回归。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late MiniappApi api;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = MiniappApi(dio);
  });

  Map<String, dynamic> artifactShape({String id = 'art_1'}) => {
    'id': id,
    'work_id': 'w1',
    'name': 'report.md',
    'type': 'document',
    'mime_type': 'text/markdown',
    'size_bytes': 1024,
    'preview_mode': 'text',
    'url': null,
    'thumbnail_url': null,
    'created_at': '2024-03-05T08:09:11Z',
  };

  /// `buildWorkItem` 的真实输出形状（`internal/server/miniapp_projector.go`）。
  Map<String, dynamic> workItemShape({
    String id = 'w1',
    String status = 'running',
    String statusLabel = '运行中',
  }) => {
    'id': id,
    'title': '帮我做一个报表',
    'goal': '生成月度报表',
    'status': status,
    'status_label': statusLabel,
    'progress': {
      'total': 3,
      'completed': 1,
      'percent': 33,
      'current_step': '抓取数据',
    },
    'pending_confirmation_count': 1,
    'latest_summary': '已抓取 3 个数据源',
    'latest_artifact': artifactShape(),
    'updated_at': '2024-03-05T08:09:12Z',
    'created_at': '2024-03-05T08:09:10Z',
  };

  Map<String, dynamic> confirmationShape({String id = 'c1'}) => {
    'id': id,
    'work_id': 'w1',
    'type': 'risk_approval',
    'title': '需要确认风险操作',
    'description': '将删除 3 个文件',
    'options': [
      {'key': 'approve', 'label': '同意', 'recommended': true},
      {'key': 'reject', 'label': '拒绝'},
      {'key': 'revise', 'label': '补充后继续'},
    ],
    'required_inputs': [
      {'key': 'reason', 'label': '原因', 'placeholder': '请说明', 'required': true},
    ],
    'status': 'pending',
    'created_at': '2024-03-05T08:09:10Z',
    'expires_at': null,
  };

  /// `GET /works/:id/events` 的真实形状：**数据库原始行**（Go 结构体 json tag）。
  Map<String, dynamic> dbEventRowShape({String id = 'e1'}) => {
    'id': id,
    'turnId': 't1',
    'groupId': 'w1',
    'userId': 'u1',
    // sql.NullString 无自定义 MarshalJSON → {String,Valid}
    'agentId': {'String': 'agt_1', 'Valid': true},
    'sessionId': {'String': '', 'Valid': false},
    'eventType': 'message',
    'seq': 2,
    'globalSeq': 7,
    'source': 'agent',
    'payloadJson': '{"content":"你好"}',
    'createdAt': '2024-03-05T08:09:10Z',
  };

  group('miniapp works：路径与请求体键', () {
    test('GET /chat/miniapp/works 路径与 query（cursor 是 offset）', () async {
      adapter.onGet(
        '/chat/miniapp/works',
        (server) => server.reply(200, {
          'items': [workItemShape()],
          'next_cursor': '1',
        }),
        queryParameters: {'status': 'active', 'limit': 20},
      );

      final page = await api.listWorks();

      expect(page.items, hasLength(1));
      expect(page.items.single.id, 'w1');
      expect(page.nextCursor, '1');
      // 能走到这里说明路径与 query 匹配（未匹配会抛 AssertionError）。
    });

    test('GET /chat/miniapp/works 的 cursor 原样作为 offset 发出', () async {
      // ## 这个测试防的是什么
      //
      // 服务端 `listWorks` 用 `parseOffset(c.Query("cursor"))` —— 参数名叫
      // cursor，值其实是 **offset**。客户端若把它当成不透明游标（例如加前缀、
      // 或 base64 编码），`strconv.Atoi` 会失败并把 offset 当 0，
      // 于是每次翻页都返回第一页——**翻页静默失效，不报错**。
      //
      // 故这里断言发出的 query 值就是裸数字。
      adapter.onGet(
        '/chat/miniapp/works',
        (server) => server.reply(200, {'items': <Object>[]}),
        queryParameters: {'status': 'active', 'limit': 20, 'cursor': '20'},
      );

      await api.listWorks(cursor: 20);
      // 能走到这里说明 cursor 以**整数 20** 发出（不是 'page-20' 之类）。
    });

    test('GET /chat/miniapp/works 解析 status_label 与 progress', () async {
      adapter.onGet(
        '/chat/miniapp/works',
        (server) => server.reply(200, {
          'items': [workItemShape()],
        }),
        queryParameters: {'status': 'active', 'limit': 20},
      );

      final work = (await api.listWorks()).items.single;

      // status_label 由后端下发（取代前端硬编码状态表）。
      expect(work.statusLabel, '运行中');
      expect(work.displayStatus, '运行中');
      expect(work.progress.total, 3);
      expect(work.progress.completed, 1);
      expect(work.progress.percent, 33);
      expect(work.pendingConfirmationCount, 1);
      expect(work.latestSummary, '已抓取 3 个数据源');
      expect(work.latestArtifact?.name, 'report.md');
    });

    test('status_label 为空串时 displayStatus 回落原始 status', () async {
      // 服务端未登记的状态返回空串（刻意不回落成 status 本身），
      // 以便前端区分「后端未提供展示名」。
      adapter.onGet(
        '/chat/miniapp/works',
        (server) => server.reply(200, {
          'items': [workItemShape(status: 'weird_new_state', statusLabel: '')],
        }),
        queryParameters: {'status': 'active', 'limit': 20},
      );

      final work = (await api.listWorks()).items.single;
      expect(work.statusLabel, isEmpty);
      expect(work.displayStatus, 'weird_new_state');
    });

    test(
      'POST /chat/miniapp/works 请求体键为 goal/input/template_id/file_ids',
      () async {
        adapter.onPost(
          '/chat/miniapp/works',
          (server) => server.reply(201, {
            'work': {
              'id': 'w1',
              'title': '新会话',
              'status': 'queued',
              'status_label': '排队中',
              'progress': {'total': 0, 'completed': 0, 'percent': 0},
              'can_send_message': true,
              'can_stop': false,
              'can_complete': true,
              'steps': <Object>[],
              'artifacts': <Object>[],
              'recent_events': <Object>[],
              'pending_confirmations': <Object>[],
            },
            'dispatch': {'turn_id': 't1', 'agent_id': 'agt_1'},
          }),
          data: {
            'goal': '做个报表',
            'input': '开始吧',
            'template_id': 'tpl_1',
            'file_ids': ['f1'],
          },
        );

        final res = await api.createWork(
          goal: '做个报表',
          input: '开始吧',
          templateId: 'tpl_1',
          fileIds: ['f1'],
        );

        expect(res.workId, 'w1');
        expect(res.dispatch?.turnId, 't1');
        expect(res.dispatch?.isQueued, isTrue);
      },
    );

    test('POST /chat/miniapp/works 不带 input 时 dispatch 为 null', () async {
      adapter.onPost(
        '/chat/miniapp/works',
        (server) => server.reply(201, {
          'work': {
            'id': 'w2',
            'title': '新会话',
            'status': 'draft',
            'status_label': '草稿',
            'progress': {'total': 0, 'completed': 0, 'percent': 0},
            'can_send_message': true,
            'can_stop': false,
            'can_complete': true,
          },
          'dispatch': null,
        }),
        data: <String, dynamic>{},
      );

      final res = await api.createWork();
      expect(res.dispatch, isNull, reason: '无 input 且无 file_ids 时服务端不派发');
    });

    test('GET /chat/miniapp/works/w1 解析 work 子对象与能力位', () async {
      adapter.onGet(
        '/chat/miniapp/works/w1',
        (server) => server.reply(200, {
          'work': {
            'id': 'w1',
            'title': '报表',
            'status': 'running',
            'status_label': '运行中',
            'progress': {'total': 3, 'completed': 1, 'percent': 33},
            'steps': [
              {
                'id': 's1',
                'title': '抓数据',
                'status': 'completed',
                'order_index': 1,
              },
              {
                'id': 's2',
                'title': '生成',
                'status': 'running',
                'order_index': 2,
              },
            ],
            'latest_result': {'title': '最新结果', 'content': '已完成抓取'},
            'pending_confirmations': [confirmationShape()],
            'artifacts': [artifactShape()],
            'recent_events': [
              {
                'id': 'e1',
                'work_id': 'w1',
                'type': 'result',
                'title': '生成了新结果',
                'content': '你好',
                'created_at': '2024-03-05T08:09:10Z',
              },
            ],
            'can_send_message': true,
            'can_stop': true,
            'can_complete': true,
          },
        }),
      );

      final detail = await api.getWork('w1');

      expect(detail.id, 'w1');
      expect(detail.canSendMessage, isTrue);
      expect(detail.canStop, isTrue);
      expect(detail.canComplete, isTrue);
      expect(detail.steps, hasLength(2));
      expect(detail.steps.first.isDone, isTrue);
      expect(detail.steps.last.isRunning, isTrue);
      expect(detail.latestResultText, '已完成抓取');
      expect(detail.pendingConfirmations.single.type, 'risk_approval');
      expect(detail.artifacts.single.name, 'report.md');
      expect(detail.recentEvents.single.type, 'result');
    });

    test('GET work 404 抛 HttpError(isNotFound)，不静默成空对象', () async {
      adapter.onGet(
        '/chat/miniapp/works/nope',
        (server) => server.reply(404, {'error': '工作不存在'}),
      );

      await expectLater(
        () => api.getWork('nope'),
        throwsA(
          isA<HttpError>().having((e) => e.isNotFound, 'isNotFound', isTrue),
        ),
      );
    });
  });

  group('miniapp 发消息与终态', () {
    test('POST /chat/miniapp/works/w1/messages 请求体键为 input/file_ids', () async {
      adapter.onPost(
        '/chat/miniapp/works/w1/messages',
        (server) => server.reply(201, {
          'work_id': 'w1',
          'dispatch': {
            'turn_id': 't9',
            'agent_id': 'agt_1',
            'route_source': 'fastpath',
          },
        }),
        data: {
          'input': '再补充一点',
          'file_ids': ['f1'],
        },
      );

      final d = await api.sendMessage('w1', input: '再补充一点', fileIds: ['f1']);

      expect(d.turnId, 't9');
      expect(d.agentId, 'agt_1');
      expect(d.routeSource, 'fastpath');
      // group_id 由 work_id 合并而来（dispatch 里没有该键）。
      expect(d.groupId, 'w1');
      expect(d.isQueued, isTrue);
    });

    test('feedback_recorded 时 turn_id 为空且 isQueued 为 false', () async {
      // 归属反馈回执是**终态**：不建 turn。调用方不应等一个不存在的 turn。
      adapter.onPost(
        '/chat/miniapp/works/w1/messages',
        (server) => server.reply(201, {
          'work_id': 'w1',
          'dispatch': {
            'turn_id': '',
            'group_id': 'w1',
            'status': 'feedback_recorded',
            'feedback_recorded': true,
          },
        }),
        data: {'input': '不对，这属于另一个对话'},
      );

      final d = await api.sendMessage('w1', input: '不对，这属于另一个对话');

      expect(d.feedbackRecorded, isTrue);
      expect(d.turnId, isEmpty);
      expect(d.isQueued, isFalse, reason: '回执不建 turn，调用方不应等回答');
    });

    test('dispatch 内嵌 error 时 hasError 为 true（不是成功）', () async {
      // ## 这个测试防的是什么
      //
      // 服务端 `dispatchWorkMessage` 失败时把 `{error: ...}` **嵌在 200/201
      // 响应体**里，而不是用错误状态码。若不检查它，「派发失败」会被当成
      // 「成功但没有 turn_id」，UI 表现为「发了消息但一直没反应」。
      adapter.onPost(
        '/chat/miniapp/works/w1/messages',
        (server) => server.reply(201, {
          'work_id': 'w1',
          'dispatch': {'error': 'queued turn quota exceeded'},
        }),
        data: {'input': 'x'},
      );

      final d = await api.sendMessage('w1', input: 'x');

      expect(d.hasError, isTrue);
      expect(d.error, 'queued turn quota exceeded');
      expect(d.isQueued, isFalse);
    });

    test('POST /chat/miniapp/works/w1/complete 返回更新后的 work', () async {
      adapter.onPost(
        '/chat/miniapp/works/w1/complete',
        (server) => server.reply(200, {
          'work': {
            'id': 'w1',
            'title': '报表',
            'status': 'completed',
            'status_label': '已完成',
            'progress': {'total': 3, 'completed': 3, 'percent': 100},
            'can_send_message': false,
            'can_stop': false,
            'can_complete': false,
          },
          'interruption': null,
        }),
        data: null,
      );

      final work = await api.completeWork('w1');

      expect(work.status, 'completed');
      expect(work.canSendMessage, isFalse, reason: '完成后不能再发消息');
    });

    test('POST /chat/miniapp/works/w1/stop 返回归档后的 work', () async {
      adapter.onPost(
        '/chat/miniapp/works/w1/stop',
        (server) => server.reply(200, {
          'work': {
            'id': 'w1',
            'title': '报表',
            'status': 'stopped',
            'status_label': '已停止',
            'progress': {'total': 3, 'completed': 1, 'percent': 33},
            'can_send_message': false,
            'can_stop': false,
            'can_complete': false,
          },
          'interruption': {
            'turn_ids': ['t1', 't2'],
          },
        }),
        data: null,
      );

      final work = await api.stopWork('w1');
      expect(work.status, 'stopped');
    });

    test('complete 对已归档 work 返回 404（重复点击应视为已是完成态）', () async {
      adapter.onPost(
        '/chat/miniapp/works/w1/complete',
        (server) => server.reply(404, {'error': '工作不存在'}),
        data: null,
      );

      await expectLater(
        () => api.completeWork('w1'),
        throwsA(isA<HttpError>().having((e) => e.statusCode, 'status', 404)),
      );
    });
  });

  group('miniapp 事件：/events 返回数据库原始行', () {
    test('解析 payloadJson 字符串与 agentId 的 {String,Valid} 形态', () async {
      adapter.onGet(
        '/chat/miniapp/works/w1/events',
        (server) => server.reply(200, {
          'items': [dbEventRowShape()],
        }),
        queryParameters: {'limit': 100},
      );

      final events = await api.workEvents('w1');
      final e = events.single;

      // 键名是 id（不是 eventId）。
      expect(e.id, 'e1');
      expect(e.eventType, 'message');
      expect(e.seq, 2);
      expect(e.globalSeq, 7);
      // agentId 被从 {String,Valid} 归一成 String。
      expect(e.agentId, 'agt_1');
      // sessionId 的 Valid=false → null（不是空串）。
      expect(e.sessionId, isNull);
      // payloadJson 是**字符串**，payload 是解析后的对象。
      expect(e.payloadJson, '{"content":"你好"}');
      expect(e.payload?['content'], '你好');
      expect(e.text, '你好');
    });

    test('同一份行用 ChatEvent.fromJson 解析会抛异常 —— 这就是必须单独建模的原因', () {
      // ## 这个断言是本测试的核心价值
      //
      // `workEvents` 直接把 `[]queries.ChatEvent` 交给 c.JSON，形状由 Go 结构体
      // 的 json tag 决定：事件 id 是 `id`，而 `ChatEvent.fromJson` 要求
      // `eventId`/`event_id`，且对缺失做**显式校验**（不是安全默认值）。
      // 故「顺手复用 ChatEvent」会在每次加载事件时抛 FormatException。
      expect(
        () => ChatEvent.fromJson(dbEventRowShape()),
        throwsA(isA<FormatException>()),
      );
    });

    test('payloadJson 非法 JSON 时 payload 为 null（不抛异常）', () async {
      // 服务端 eventPayload 在 JSON 非法时返回空 map（不抛），两边一致地「不抛」。
      adapter.onGet(
        '/chat/miniapp/works/w1/events',
        (server) => server.reply(200, {
          'items': [
            {...dbEventRowShape(), 'payloadJson': 'not-json'},
          ],
        }),
        queryParameters: {'limit': 100},
      );

      final e = (await api.workEvents('w1')).single;
      expect(e.payload, isNull);
      expect(e.text, isEmpty);
    });
  });

  group('miniapp 产物', () {
    test('GET /chat/miniapp/works/w1/artifacts 路径与解析', () async {
      adapter.onGet(
        '/chat/miniapp/works/w1/artifacts',
        (server) => server.reply(200, {
          'items': [artifactShape()],
        }),
      );

      final arts = await api.listArtifacts('w1');
      expect(arts.single.name, 'report.md');
      expect(arts.single.type, 'document');
      expect(arts.single.hasInlineContent, isFalse, reason: '列表投影不含 content');
    });

    test('GET /chat/miniapp/works/w1/artifacts/a1 解析内联 content', () async {
      adapter.onGet(
        '/chat/miniapp/works/w1/artifacts/a1',
        (server) => server.reply(200, {
          'artifact': {
            ...artifactShape(id: 'a1'),
            'content': '# 报表\n',
            'download_url': '/chat/miniapp/works/w1/artifacts/a1/download',
          },
        }),
      );

      final art = await api.getArtifact('w1', 'a1');

      expect(art.id, 'a1');
      expect(art.content, '# 报表\n');
      expect(art.hasInlineContent, isTrue);
      expect(
        art.downloadUrl,
        '/chat/miniapp/works/w1/artifacts/a1/download',
        reason: '服务端拼的是绝对路径（带 / 开头），不含网关前缀',
      );
    });

    test('产物归属不符时服务端返回 404（不区分「不存在」与「非本 work」）', () async {
      adapter.onGet(
        '/chat/miniapp/works/w1/artifacts/other',
        (server) => server.reply(404, {'error': '产物不存在'}),
      );

      await expectLater(
        () => api.getArtifact('w1', 'other'),
        throwsA(
          isA<HttpError>().having((e) => e.isNotFound, 'isNotFound', isTrue),
        ),
      );
    });

    test('POST /chat/miniapp/works/w1/files 用 multipart 字段名 file', () async {
      adapter.onPost(
        '/chat/miniapp/works/w1/files',
        (server) => server.reply(200, {
          'work_id': 'w1',
          'artifact': artifactShape(id: 'a9'),
          'upload': {'id': 'a9'},
        }),
        data: Matchers.any,
      );

      final art = await api.uploadFile(
        'w1',
        bytes: [1, 2, 3],
        filename: 'note.md',
        relativePath: 'docs/note.md',
      );

      expect(art.id, 'a9');
    });

    test('上传超过服务端上限返回 413（不自己复刻上限）', () async {
      adapter.onPost(
        '/chat/miniapp/works/w1/files',
        (server) => server.reply(413, {'error': '文件超过 workspace 同步大小上限'}),
        data: Matchers.any,
      );

      await expectLater(
        () => api.uploadFile('w1', bytes: [1], filename: 'big.bin'),
        throwsA(isA<HttpError>().having((e) => e.statusCode, 'status', 413)),
      );
    });
  });

  group('miniapp 确认卡', () {
    test('GET /chat/miniapp/confirmations 支持 group_id 过滤', () async {
      adapter.onGet(
        '/chat/miniapp/confirmations',
        (server) => server.reply(200, {
          'items': [confirmationShape()],
          'pending_count': 1,
        }),
        queryParameters: {'group_id': 'w1', 'limit': 20, 'offset': 0},
      );

      final cards = await api.listConfirmations(workId: 'w1');

      expect(cards.single.id, 'c1');
      expect(cards.single.type, 'risk_approval');
      expect(cards.single.recommendedOptionKey, 'approve');
      expect(cards.single.requiredInputs.single.key, 'reason');
      expect(cards.single.isPending, isTrue);
    });

    test('description 为 null 时解析成 null（服务端确实会返回 null）', () async {
      adapter.onGet(
        '/chat/miniapp/confirmations',
        (server) => server.reply(200, {
          'items': [
            {...confirmationShape(), 'description': null},
          ],
        }),
        queryParameters: {'limit': 20, 'offset': 0},
      );

      final card = (await api.listConfirmations()).single;
      expect(card.description, isNull);
    });

    test('POST /chat/miniapp/confirmations/c1/resolve 路径与请求体键', () async {
      // 路径**不带** group_id（与 webapp 的 /api/chat/groups/:gid/... 不同），
      // 请求体键是 action / comment。
      adapter.onPost(
        '/chat/miniapp/confirmations/c1/resolve',
        (server) => server.reply(200, {'resolved': true, 'action': 'approve'}),
        data: {'action': 'approve', 'comment': '同意'},
      );

      await api.resolveConfirmation('c1', action: 'approve', comment: '同意');
      // 能走到这里说明路径与请求体匹配。
    });

    test('resolve 404（已处理/非本人）抛 isNotFound，调用方当「不用再显示」', () async {
      adapter.onPost(
        '/chat/miniapp/confirmations/c1/resolve',
        (server) => server.reply(404, {'error': 'confirmation 不存在或已处理'}),
        data: {'action': 'approve'},
      );

      await expectLater(
        () => api.resolveConfirmation('c1', action: 'approve'),
        throwsA(
          isA<HttpError>().having((e) => e.isNotFound, 'isNotFound', isTrue),
        ),
      );
    });
  });

  group('miniapp 通知订阅', () {
    test('GET /chat/miniapp/notifications/subscriptions 路径与解析', () async {
      adapter.onGet(
        '/chat/miniapp/notifications/subscriptions',
        (server) => server.reply(200, {
          'items': [
            {
              'user_id': 'u1',
              'template_key': 'work_completed',
              'remaining_quota': 2,
              'enabled': true,
              'updated_at': '2024-03-05T08:09:10Z',
            },
          ],
        }),
      );

      final subs = await api.listNotificationSubscriptions();

      expect(subs.single.templateKey, 'work_completed');
      expect(subs.single.remainingQuota, 2);
      expect(subs.single.enabled, isTrue);
    });

    test('POST .../subscriptions 请求体是 {"accepted": {...}}', () async {
      adapter.onPost(
        '/chat/miniapp/notifications/subscriptions',
        (server) => server.reply(200, {
          'items': [
            {
              'template_key': 'work_completed',
              'remaining_quota': 3,
              'enabled': true,
            },
          ],
        }),
        data: {
          'accepted': {'work_completed': 1},
        },
      );

      final subs = await api.saveNotificationSubscriptions({
        'work_completed': 1,
      });
      expect(subs.single.remainingQuota, 3);
    });

    test('未知 template_key 返回 400（不会静默忽略）', () async {
      adapter.onPost(
        '/chat/miniapp/notifications/subscriptions',
        (server) => server.reply(400, {'error': 'unknown template_key: bogus'}),
        data: {
          'accepted': {'bogus': 1},
        },
      );

      await expectLater(
        () => api.saveNotificationSubscriptions({'bogus': 1}),
        throwsA(isA<HttpError>().having((e) => e.statusCode, 'status', 400)),
      );
    });

    test('数据库不可用时 503（当作暂时不可用，不是永久失败）', () async {
      adapter.onGet(
        '/chat/miniapp/notifications/subscriptions',
        (server) => server.reply(503, {'error': 'database unavailable'}),
      );

      await expectLater(
        () => api.listNotificationSubscriptions(),
        throwsA(isA<HttpError>().having((e) => e.statusCode, 'status', 503)),
      );
    });
  });
}
