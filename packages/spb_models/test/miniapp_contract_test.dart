import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 小程序 BFF（`/chat/miniapp/*`）契约测试。
///
/// ## 为什么这批模型此前几乎零覆盖
///
/// `miniapp.dart` 有 15 个类，此前只有一个测试文件覆盖了 `NotificationTemplates`
/// 与 `NotificationSubscription`（见 `miniapp_test.dart`）。其余 13 个类的
/// `fromJson` 与语义 getter 零覆盖。
///
/// ## 三个命名陷阱（都在本文件钉住）
///
/// 1. **`work` 就是 `chat_groups` 行**——`id` 是 group id，不是独立的 works 表；
/// 2. **`cursor` 其实是 offset**——`next_cursor` 是 `strconv.Itoa(offset+n)`，
///    当 id 游标用会翻页错乱；
/// 3. **`/events` 返回数据库原始行**——`id`（不是 `eventId`）、
///    `payloadJson`（字符串，不是 `payload` 对象）、`agentId` 是
///    `sql.NullString` 的 `{String,Valid}` 形态。用 `ChatEvent.fromJson` 解析
///    会抛 `FormatException`。
void main() {
  group('MiniappWork（buildWorkItem）', () {
    Map<String, dynamic> workJson({
      Object? statusLabel = '运行中',
      Object? goal = '做完它',
      Object? pendingConfirmationCount = 2,
      Object? latestSummary = '结果',
      Object? latestArtifact,
      Object? progress = const {'total': 4, 'completed': 1, 'percent': 25},
    }) => {
      'id': 'grp_1',
      'title': '某个工作',
      'status': 'running',
      'status_label': statusLabel,
      'progress': progress,
      'goal': goal,
      'pending_confirmation_count': pendingConfirmationCount,
      'latest_summary': latestSummary,
      'latest_artifact': latestArtifact,
      'created_at': '2024-03-05T08:00:00Z',
      'updated_at': '2024-03-05T08:09:10Z',
    };

    test('基本字段（snake_case，全部照抄服务端）', () {
      final w = MiniappWork.fromJson(workJson());
      expect(w.id, 'grp_1');
      expect(w.title, '某个工作');
      expect(w.status, 'running');
      expect(w.statusLabel, '运行中');
      expect(w.goal, '做完它');
      expect(w.pendingConfirmationCount, 2);
      expect(w.latestSummary, '结果');
      expect(w.progress.total, 4);
      expect(w.createdAt, DateTime.parse('2024-03-05T08:00:00Z').toLocal());
    });

    test('displayStatus：status_label 空时回落原始 status', () {
      // 服务端未登记的状态返回空串（刻意不回落成 status 本身）。
      expect(MiniappWork.fromJson(workJson()).displayStatus, '运行中');
      expect(
        MiniappWork.fromJson(workJson(statusLabel: '')).displayStatus,
        'running',
      );
    });

    test('hasPendingConfirmation 按计数', () {
      expect(MiniappWork.fromJson(workJson()).hasPendingConfirmation, isTrue);
      expect(
        MiniappWork.fromJson(workJson(pendingConfirmationCount: 0))
            .hasPendingConfirmation,
        isFalse,
      );
    });

    test('latest_artifact 为 null 时不解析（无产物）', () {
      expect(MiniappWork.fromJson(workJson()).latestArtifact, isNull);
      final w = MiniappWork.fromJson(
        workJson(
          latestArtifact: {'id': 'a1', 'name': '报告.md', 'type': 'document'},
        ),
      );
      expect(w.latestArtifact?.name, '报告.md');
    });

    test('缺字段回安全默认值（progress 缺失也建得出）', () {
      final w = MiniappWork.fromJson(const {});
      expect(w.id, '');
      expect(w.pendingConfirmationCount, 0);
      expect(w.goal, isNull);
      expect(w.latestSummary, isNull);
      expect(w.progress.total, 0);
    });
  });

  group('MiniappProgress：fraction 比 percent 精确', () {
    test('fraction = completed/total（total=0 时为 0）', () {
      expect(
        const MiniappProgress(total: 3, completed: 1).fraction,
        closeTo(1 / 3, 1e-9),
      );
      // 服务端 percent 是整数（33），有 total 时用比例更精确。
      expect(
        const MiniappProgress(total: 3, completed: 1, percent: 33).fraction,
        closeTo(0.3333, 1e-4),
      );
    });

    test('total=0 时 fraction 为 0 且 hasSteps 为 false', () {
      const p = MiniappProgress();
      expect(p.fraction, 0);
      expect(p.hasSteps, isFalse);
    });

    test('completed > total 时 clamp 到 1.0（不越界）', () {
      expect(const MiniappProgress(total: 2, completed: 5).fraction, 1.0);
    });

    test('hasSteps 按 total（「无任务」与「0%」数值不可区分）', () {
      expect(const MiniappProgress(total: 1, percent: 0).hasSteps, isTrue);
      expect(const MiniappProgress(percent: 0).hasSteps, isFalse);
    });
  });

  group('MiniappStep：服务端已把六态归一成五态', () {
    MiniappStep step(String status) => MiniappStep.fromJson({
      'id': 's1',
      'title': '步骤',
      'status': status,
      'description': '说明',
      'order_index': 2,
    });

    test('字段解析', () {
      final s = MiniappStep.fromJson({
        'id': 's1',
        'title': '步骤',
        'status': 'running',
        'description': '说明',
        'phase': 'phase1',
        'order_index': 2,
      });
      expect(s.id, 's1');
      expect(s.status, 'running');
      expect(s.phase, 'phase1');
      expect(s.orderIndex, 2);
    });

    test('isDone 含 completed 与 skipped（跳过也算完成）', () {
      expect(step('completed').isDone, isTrue);
      expect(step('skipped').isDone, isTrue);
      expect(step('running').isDone, isFalse);
      expect(step('pending').isDone, isFalse);
      expect(step('failed').isDone, isFalse);
    });

    test('isRunning / isFailed 各自只认一个状态', () {
      expect(step('running').isRunning, isTrue);
      expect(step('failed').isRunning, isFalse);
      expect(step('failed').isFailed, isTrue);
      expect(step('completed').isFailed, isFalse);
    });
  });

  group('MiniappArtifact（两种来源，字段一致）', () {
    Map<String, dynamic> artJson({
      Object? content,
      Object? previewMode = 'text',
      Object? type = 'document',
    }) => {
      'id': 'a1',
      'name': '报告.md',
      'type': type,
      'work_id': 'grp_1',
      'mime_type': 'text/markdown',
      'size_bytes': 2048,
      'preview_mode': previewMode,
      'url': 'http://x/a1',
      'thumbnail_url': null,
      'content': content,
      'download_url': '/chat/miniapp/works/grp_1/artifacts/a1/download',
      'webview_url': null,
      'created_at': '2024-03-05T08:00:00Z',
    };

    test('基本字段', () {
      final a = MiniappArtifact.fromJson(artJson());
      expect(a.id, 'a1');
      expect(a.name, '报告.md');
      expect(a.type, 'document');
      expect(a.mimeType, 'text/markdown');
      expect(a.sizeBytes, 2048);
      expect(a.previewMode, 'text');
      expect(a.url, 'http://x/a1');
      expect(a.downloadUrl, contains('/download'));
    });

    test('isImage 只认 type=image；hasInlineContent 要求非空', () {
      expect(MiniappArtifact.fromJson(artJson(type: 'image')).isImage, isTrue);
      expect(
        MiniappArtifact.fromJson(artJson(type: 'document')).isImage,
        isFalse,
      );
      expect(
        MiniappArtifact.fromJson(artJson(content: '# hi')).hasInlineContent,
        isTrue,
      );
      // content 为 null 不代表「没有内容」，只代表「本次没内联」。
      expect(MiniappArtifact.fromJson(artJson()).hasInlineContent, isFalse);
      expect(
        MiniappArtifact.fromJson(artJson(content: '')).hasInlineContent,
        isFalse,
      );
    });

    test('content 非字符串时归一成 null（服务端类型是 any）', () {
      expect(MiniappArtifact.fromJson(artJson(content: 42)).content, isNull);
    });
  });

  group('MiniappConfirmation：type 是归一后的结果', () {
    Map<String, dynamic> confJson({
      Object? description = '要继续吗？',
      Object? options = const [
        {'key': 'approve', 'label': '批准', 'recommended': true},
        {'key': 'reject', 'label': '拒绝', 'recommended': false},
      ],
      Object? requiredInputs = const [
        {
          'key': 'note',
          'label': '备注',
          'placeholder': '写点什么',
          'required': false,
        },
      ],
    }) => {
      'id': 'cfm_1',
      'work_id': 'grp_1',
      'type': 'risk_approval',
      'title': '需要批准',
      'status': 'pending',
      'description': description,
      'options': options,
      'required_inputs': requiredInputs,
      'created_at': '2024-03-05T08:00:00Z',
    };

    test('基本字段与嵌套 options / required_inputs', () {
      final c = MiniappConfirmation.fromJson(confJson());
      expect(c.id, 'cfm_1');
      expect(c.workId, 'grp_1');
      expect(c.type, 'risk_approval');
      expect(c.title, '需要批准');
      expect(c.isPending, isTrue);
      expect(c.options, hasLength(2));
      expect(c.requiredInputs, hasLength(1));
      expect(c.requiredInputs.first.key, 'note');
      // required 默认 true，显式 false 才为 false。
      expect(c.requiredInputs.first.required, isFalse);
    });

    test('recommendedOptionKey：找到推荐的 key，无推荐为 null', () {
      expect(
        MiniappConfirmation.fromJson(confJson()).recommendedOptionKey,
        'approve',
      );
      expect(
        MiniappConfirmation.fromJson(
          confJson(
            options: const [
              {'key': 'a', 'label': 'A', 'recommended': false},
            ],
          ),
        ).recommendedOptionKey,
        isNull,
      );
      expect(
        MiniappConfirmation.fromJson(confJson(options: const []))
            .recommendedOptionKey,
        isNull,
      );
    });

    test('description 可为 null（服务端无 reason 时返回 nil）', () {
      expect(
        MiniappConfirmation.fromJson(confJson(description: null)).description,
        isNull,
      );
    });

    test('required 缺省为 true（服务端约束是「必须填」）', () {
      final c = MiniappConfirmation.fromJson(
        confJson(
          requiredInputs: const [
            {'key': 'k', 'label': 'L'},
          ],
        ),
      );
      expect(c.requiredInputs.first.required, isTrue);
    });

    test('非 pending 状态不判 pending', () {
      expect(
        MiniappConfirmation.fromJson(confJson()..['status'] = 'resolved')
            .isPending,
        isFalse,
      );
    });
  });

  group('MiniappWorkDetail：能力位由服务端下发', () {
    Map<String, dynamic> detailJson({
      Object? canSendMessage = true,
      Object? canStop = false,
      Object? canComplete = true,
      Object? latestResult = const {'title': '结果', 'content': '正文'},
      Object? activeSession = const {'agent_id': 'a1'},
    }) => {
      'id': 'grp_1',
      'title': '某个工作',
      'status': 'running',
      'status_label': '运行中',
      'progress': const {'total': 1, 'completed': 0},
      'can_send_message': canSendMessage,
      'can_stop': canStop,
      'can_complete': canComplete,
      'goal': '目标',
      'steps': const [
        {'id': 's1', 'title': '步1', 'status': 'pending'},
      ],
      'latest_result': latestResult,
      'pending_confirmations': const [
        {
          'id': 'c1',
          'work_id': 'grp_1',
          'type': 'continue',
          'title': 't',
          'status': 'pending',
        },
      ],
      'artifacts': const [
        {'id': 'a1', 'name': 'n', 'type': 'document'},
      ],
      'recent_events': const [
        {'id': 'e1', 'type': 'result', 'title': '完成', 'work_id': 'grp_1'},
      ],
      'active_session': activeSession,
      'created_at': '2024-03-05T08:00:00Z',
    };

    test('能力位照抄服务端（不自己推状态）', () {
      final d = MiniappWorkDetail.fromJson(detailJson());
      expect(d.canSendMessage, isTrue);
      expect(d.canStop, isFalse);
      expect(d.canComplete, isTrue);
    });

    test('嵌套列表全部解析', () {
      final d = MiniappWorkDetail.fromJson(detailJson());
      expect(d.steps, hasLength(1));
      expect(d.pendingConfirmations.first.id, 'c1');
      expect(d.artifacts.first.id, 'a1');
      expect(d.recentEvents.first.id, 'e1');
      expect(d.activeSession?['agent_id'], 'a1');
    });

    test('latestResultText：取 content 字符串，缺失/空/非字符串为 null', () {
      expect(MiniappWorkDetail.fromJson(detailJson()).latestResultText, '正文');
      expect(
        MiniappWorkDetail.fromJson(detailJson(latestResult: null))
            .latestResultText,
        isNull,
      );
      expect(
        MiniappWorkDetail.fromJson(
          detailJson(latestResult: const {'content': 42}),
        ).latestResultText,
        isNull,
      );
      expect(
        MiniappWorkDetail.fromJson(
          detailJson(latestResult: const {'content': ''}),
        ).latestResultText,
        isNull,
      );
    });

    test('能力位缺省为 false（不是「默认允许」）', () {
      // 缺省 true 会在服务端漏发字段时让按钮可点 → 请求被拒。
      final d = MiniappWorkDetail.fromJson(const {});
      expect(d.canSendMessage, isFalse);
      expect(d.canStop, isFalse);
      expect(d.canComplete, isFalse);
      expect(d.steps, isEmpty);
      expect(d.activeSession, isNull);
    });
  });

  group('MiniappEventItem（buildWorkEvent 投影）', () {
    test('content 是 any：字符串取得到，artifact_created 为 null', () {
      final e = MiniappEventItem.fromJson({
        'id': 'e1',
        'work_id': 'grp_1',
        'type': 'result',
        'title': '完成',
        'content': '正文',
        'created_at': '2024-03-05T08:00:00Z',
      });
      expect(e.contentText, '正文');
      expect(e.isArtifact, isFalse);
      expect(e.isFailure, isFalse);
      expect(e.needsUser, isFalse);
    });

    test('content 非字符串时 contentText 为 null（不抛）', () {
      final e = MiniappEventItem.fromJson({
        'id': 'e1',
        'type': 'artifact_created',
        'title': '产出',
        'content': {'id': 'a1'},
      });
      expect(e.contentText, isNull);
      expect(e.isArtifact, isTrue);
    });

    test('语义 getter：failed / artifact_created / waiting_confirmation', () {
      MiniappEventItem ev(String type) =>
          MiniappEventItem.fromJson({'id': 'x', 'type': type, 'title': 't'});
      expect(ev('failed').isFailure, isTrue);
      expect(ev('artifact_created').isArtifact, isTrue);
      expect(ev('waiting_confirmation').needsUser, isTrue);
      expect(ev('result').isFailure, isFalse);
    });
  });

  group('MiniappWorkEvent（/events 返回数据库原始行）', () {
    /// DB 行形状：`id`（不是 eventId）、`payloadJson`（字符串）、
    /// `agentId` 是 `sql.NullString` 的 `{String,Valid}`。
    Map<String, dynamic> rowJson({
      Object? agentId = const {'String': 'a1', 'Valid': true},
      Object? sessionId = const {'String': '', 'Valid': false},
      Object? payloadJson = '{"content":"你好"}',
      Object? globalSeq = 7,
    }) => {
      'id': 'e1',
      'eventType': 'message',
      'seq': 3,
      'turnId': 'turn_1',
      'groupId': 'grp_1',
      'userId': 'usr_1',
      'agentId': agentId,
      'sessionId': sessionId,
      'globalSeq': globalSeq,
      'source': 'pigo',
      'payloadJson': payloadJson,
      'createdAt': '2024-03-05T08:00:00Z',
    };

    test('键名是 id / payloadJson（不是 eventId / payload 对象）', () {
      final e = MiniappWorkEvent.fromJson(rowJson());
      expect(e.id, 'e1');
      expect(e.eventType, 'message');
      expect(e.seq, 3);
      expect(e.turnId, 'turn_1');
      expect(e.globalSeq, 7);
      expect(e.payloadJson, '{"content":"你好"}');
    });

    test('sql.NullString 归一：Valid:true 取值，Valid:false 为 null', () {
      final e = MiniappWorkEvent.fromJson(rowJson());
      expect(e.agentId, 'a1');
      expect(e.sessionId, isNull, reason: 'Valid:false → null');
    });

    test('裸字符串形态也容忍（服务端将来可能改）', () {
      expect(MiniappWorkEvent.fromJson(rowJson(agentId: 'a2')).agentId, 'a2');
    });

    test('payload：解析成对象；非法 JSON / 空 → null（不抛）', () {
      expect(MiniappWorkEvent.fromJson(rowJson()).payload?['content'], '你好');
      expect(
        MiniappWorkEvent.fromJson(rowJson(payloadJson: '{not json')).payload,
        isNull,
      );
      expect(
        MiniappWorkEvent.fromJson(rowJson(payloadJson: '')).payload,
        isNull,
      );
      // 合法 JSON 但不是对象（如数组）→ null。
      expect(
        MiniappWorkEvent.fromJson(rowJson(payloadJson: '[1,2]')).payload,
        isNull,
      );
    });

    test('text：按 content / text / message 顺序取第一个非空', () {
      String textOf(String json) =>
          MiniappWorkEvent.fromJson(rowJson(payloadJson: json)).text;

      expect(textOf('{"content":"C"}'), 'C');
      expect(textOf('{"text":"T"}'), 'T');
      expect(textOf('{"message":"M"}'), 'M');
      // content 优先。
      expect(textOf('{"content":"C","text":"T"}'), 'C');
      // 空串跳过，落到下一个键。
      expect(textOf('{"content":"","text":"T"}'), 'T');
      // 都没有 → 空串。
      expect(textOf('{"other":"x"}'), '');
      expect(textOf('{not json'), '');
    });

    test('globalSeq 为 null 时保留 null（不造 0）', () {
      // 0 是 transient 事件的 globalSeq 值，造 0 会与真实值混淆。
      expect(
        MiniappWorkEvent.fromJson(rowJson(globalSeq: null)).globalSeq,
        isNull,
      );
    });
  });

  group('MiniappWorkPage：next_cursor 其实是 offset', () {
    test('解析 items 与 next_cursor；hasMore 按非空串', () {
      final p = MiniappWorkPage.fromJson({
        'items': [
          {
            'id': 'g1',
            'title': 't',
            'status': 'running',
            'status_label': '',
            'progress': <String, dynamic>{},
          },
        ],
        'next_cursor': '20',
      });
      expect(p.items, hasLength(1));
      // ⚠️ 是 offset 的字符串形式，不是 id 游标——当不透明 token 用会翻页错乱。
      expect(p.nextCursor, '20');
      expect(p.hasMore, isTrue);
    });

    test('next_cursor 缺失/空串 → hasMore 为 false', () {
      expect(
        MiniappWorkPage.fromJson(const {'items': <dynamic>[]}).hasMore,
        isFalse,
      );
      expect(
        MiniappWorkPage.fromJson(const {
          'items': <dynamic>[],
          'next_cursor': '',
        }).hasMore,
        isFalse,
      );
    });
  });

  group('MiniappDispatchResult：错误嵌在 200 响应体里', () {
    test('成功：turn_id 有值 → isQueued', () {
      final r = MiniappDispatchResult.fromJson(const {
        'turn_id': 'turn_1',
        'group_id': 'grp_1',
        'status': 'queued',
        'agent_id': 'a1',
        'route_source': 'manual',
      });
      expect(r.turnId, 'turn_1');
      expect(r.agentId, 'a1');
      expect(r.isQueued, isTrue);
      expect(r.hasError, isFalse);
    });

    test('反馈回执：不建 turn（turn_id 空，feedback_recorded=true）', () {
      final r = MiniappDispatchResult.fromJson(const {
        'turn_id': '',
        'status': 'feedback_recorded',
        'feedback_recorded': true,
      });
      expect(r.feedbackRecorded, isTrue);
      expect(r.isQueued, isFalse, reason: '反馈回执不算建了 turn');
    });

    test('失败嵌在 200 响应体（{error}）→ hasError，不判 isQueued', () {
      // 服务端把派发失败嵌在 200 而非错误码，故必须检查 error 字段——
      // 否则「派发失败」会被当成「成功但没有 turn_id」。
      final r = MiniappDispatchResult.fromJson(const {
        'error': 'no agent available',
      });
      expect(r.hasError, isTrue);
      expect(r.error, 'no agent available');
      expect(r.isQueued, isFalse);
    });

    test('缺字段 → 空 turn_id，既不 queued 也无 error', () {
      final r = MiniappDispatchResult.fromJson(const {});
      expect(r.turnId, '');
      expect(r.hasError, isFalse);
      expect(r.isQueued, isFalse);
      expect(r.feedbackRecorded, isFalse);
    });

    test('error 空串不算错误（服务端 nullStr 归一）', () {
      final r = MiniappDispatchResult.fromJson(const {'error': ''});
      expect(r.error, isNull);
      expect(r.hasError, isFalse);
    });
  });
}
