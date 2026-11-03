import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// [ChatTurnSchedule] 的解析测试。
///
/// ## 这个测试防的是什么
///
/// 该端点的 DTO 在 Go `b2a54b5a`（2026-11）从「直接返回 sqlc 行（camelCase）」
/// 换成了统一 `scheduleToDTO`（**snake_case**，与 webapp 的
/// `ChatTurnScheduleDebugItem` 对齐）。客户端首版按旧契约写——按新 DTO 解析
/// **不报错**，只是全部字段落空（`?? ''` 兜底吞掉缺失），面板看起来像
/// 「没有排程」。故本测试以**真实新 DTO 形状**构造夹具，并专门钉住三个
/// 形态陷阱：
///
/// 1. 字段名是 snake_case；`policy` 是**对象**（`parseJSON` 已解析），
///    不是字符串；
/// 2. `trigger_status` / `last_error` 是 `nullStr` / `parseJSON`：串 / 对象 /
///    null 三态，**不再是** `{"String":..,"Valid":..}` 嵌套对象；
/// 3. `next_run_at` 等是 `timeOrNil`：RFC3339 串或 null；`created_at` 是
///    `iso()`：零值是**空串**（不是 null）——不归一会显示异常时间。
void main() {
  /// Go `scheduleToDTO`（`internal/server/schedules.go`）的真实 JSON 形状。
  Map<String, dynamic> shape({
    String id = 'sch_01HZ',
    String agentId = 'agt_1',
    Object? policy = const {
      'meta': {
        'user_id': 'usr_1',
        'group_id': 'grp_1',
        'parent_turn_id': 't_1',
      },
      'max_auto_turns': 5,
    },
    bool enabled = true,
    int runCount = 0,
    int maxRuns = 5,
    Object? triggerStatus = 'pending',
    Object? nextRunAt = '2026-10-04T09:00:00Z',
    Object? lastRunAt,
    Object? lastError,
    String scheduleState = 'pending',
  }) => {
    'id': id,
    'agent_id': agentId,
    'session_id': 'sess_1',
    'agent_type': 'pigo',
    'trigger_reason': 'goal_gate',
    'trigger_status': triggerStatus,
    'message': '继续推进目标',
    'policy': policy,
    'dedupe_key': 'goal_gate:grp_1:t_1',
    'enabled': enabled,
    'run_count': runCount,
    'max_runs': maxRuns,
    'next_run_at': nextRunAt,
    'last_run_at': lastRunAt,
    'last_error': lastError,
    'schedule_state': scheduleState,
    'created_at': '2026-10-04T08:00:00Z',
    'updated_at': '2026-10-04T08:30:00Z',
  };

  group('ChatTurnSchedule.fromJson：snake_case DTO（Go b2a54b5a）', () {
    test('全部字段按 snake_case 键名解析', () {
      final s = ChatTurnSchedule.fromJson(shape());

      expect(s.id, 'sch_01HZ');
      expect(s.agentId, 'agt_1');
      expect(s.sessionId, 'sess_1');
      expect(s.agentType, 'pigo');
      expect(s.triggerReason, 'goal_gate');
      expect(s.message, '继续推进目标');
      expect(s.dedupeKey, 'goal_gate:grp_1:t_1');
      expect(s.enabled, isTrue);
      expect(s.runCount, 0);
      expect(s.maxRuns, 5);
      expect(s.scheduleState, 'pending');
      expect(s.createdAt?.toUtc(), DateTime.utc(2026, 10, 4, 8));
      expect(s.updatedAt?.toUtc(), DateTime.utc(2026, 10, 4, 8, 30));
    });

    test('⚠️ 旧 sqlc camelCase 键（b2a54b5a 之前的契约）会静默落空', () {
      final s = ChatTurnSchedule.fromJson({
        'id': 'sch_1',
        'agentId': 'agt_1',
        'runCount': 3,
        'maxRuns': 5,
        'enabled': true,
      });

      // 保留这条负例：若有回归把键名改回 camelCase，它会立刻变红——
      // 而不是像首版缺陷那样静默解析成空值。
      expect(s.agentId, '');
      expect(s.runCount, 0);
      expect(s.maxRuns, 0);
    });
  });

  group('nullStr / parseJSON 归一（trigger_status / last_error）', () {
    test('trigger_status 串 → 取到字符串', () {
      final s = ChatTurnSchedule.fromJson(shape());

      expect(s.triggerStatus, 'pending');
    });

    test('trigger_status null → null', () {
      final s = ChatTurnSchedule.fromJson(shape(triggerStatus: null));

      expect(s.triggerStatus, isNull);
    });

    test('trigger_status 空串归 null（nullStr 恒不回空串，防御历史数据）', () {
      final s = ChatTurnSchedule.fromJson(shape(triggerStatus: ''));

      expect(s.triggerStatus, isNull);
    });

    test('last_error 是 parseJSON 的对象（不是 NullString 嵌套）', () {
      final s = ChatTurnSchedule.fromJson(
        shape(lastError: const {'error': 'boom'}, scheduleState: 'failed'),
      );

      expect(s.lastError, isA<Map<String, Object>>());
      expect((s.lastError as Map)['error'], 'boom');
    });

    test('last_error null → null', () {
      final s = ChatTurnSchedule.fromJson(shape(lastError: null));

      expect(s.lastError, isNull);
    });
  });

  group('schedule_state：服务端派生的展示态', () {
    test('直接透传（pending / triggered / disabled / failed 四态）', () {
      for (final state in const [
        'pending',
        'triggered',
        'disabled',
        'failed',
      ]) {
        expect(
          ChatTurnSchedule.fromJson(shape(scheduleState: state)).scheduleState,
          state,
        );
      }
    });

    test('缺失 → null（不派生，展示层自己兜底）', () {
      final s = ChatTurnSchedule.fromJson(shape()..remove('schedule_state'));

      expect(s.scheduleState, isNull);
    });
  });

  group('时间字段归一（timeOrNil / iso）', () {
    test('next_run_at RFC3339 串 → DateTime', () {
      final s = ChatTurnSchedule.fromJson(shape());

      expect(s.nextRunAt?.toUtc(), DateTime.utc(2026, 10, 4, 9));
    });

    test(
      'null → null',
      () => expect(
        ChatTurnSchedule.fromJson(shape(nextRunAt: null, lastRunAt: null)),
        isA<ChatTurnSchedule>(),
      ),
    );

    test('last_run_at 缺省（null）→ null', () {
      final s = ChatTurnSchedule.fromJson(shape());

      expect(s.lastRunAt, isNull);
    });

    test('created_at 空串（iso 的零值形态）→ null，不显示异常时间', () {
      final s = ChatTurnSchedule.fromJson(shape()..['created_at'] = '');

      expect(s.createdAt, isNull);
    });

    test('created_at 正常串 → DateTime', () {
      final s = ChatTurnSchedule.fromJson(shape());

      expect(s.createdAt?.toUtc(), DateTime.utc(2026, 10, 4, 8));
    });
  });

  group('groupId：从 policy.meta.group_id 解析', () {
    test('标准形状取到 group_id', () {
      final s = ChatTurnSchedule.fromJson(shape());

      expect(s.groupId, 'grp_1');
    });

    test('camelCase 变体 groupId 也接受', () {
      final s = ChatTurnSchedule.fromJson(
        shape(
          policy: const {
            'meta': {'groupId': 'grp_2'},
          },
        ),
      );

      expect(s.groupId, 'grp_2');
    });

    test('字符串形态（防御：原文透传）也能解析', () {
      final s = ChatTurnSchedule.fromJson(
        shape(policy: '{"meta":{"group_id":"grp_3"}}'),
      );

      expect(s.groupId, 'grp_3');
    });

    test('缺 meta / 缺 group_id / 非 Map → null（不抛异常）', () {
      expect(
        ChatTurnSchedule.fromJson(shape(policy: const {'other': 1})).groupId,
        isNull,
      );
      expect(
        ChatTurnSchedule.fromJson(
          shape(policy: const <String, Object>{'meta': <String, Object>{}}),
        ).groupId,
        isNull,
      );
      expect(ChatTurnSchedule.fromJson(shape(policy: null)).groupId, isNull);
      expect(ChatTurnSchedule.fromJson(shape(policy: 42)).groupId, isNull);
    });

    test('chatScheduleGroupIdFromPolicy 直接调用', () {
      expect(
        chatScheduleGroupIdFromPolicy(const {
          'meta': {'group_id': 'g'},
        }),
        'g',
      );
      expect(chatScheduleGroupIdFromPolicy(null), isNull);
      expect(chatScheduleGroupIdFromPolicy(42), isNull);
    });
  });

  group('isPending：与停用端点 SQL 谓词同口径', () {
    test('enabled && runCount < maxRuns → true', () {
      expect(ChatTurnSchedule.fromJson(shape()).isPending, isTrue);
    });

    test('已停用 → false', () {
      expect(
        ChatTurnSchedule.fromJson(shape(enabled: false)).isPending,
        isFalse,
      );
    });

    test('次数已用尽（runCount == maxRuns）→ false', () {
      expect(
        ChatTurnSchedule.fromJson(shape(runCount: 5, maxRuns: 5)).isPending,
        isFalse,
      );
    });

    test('超过上限（理论上不该出现）→ false', () {
      expect(
        ChatTurnSchedule.fromJson(shape(runCount: 9, maxRuns: 5)).isPending,
        isFalse,
      );
    });
  });

  group('容错：缺字段 / 类型漂移', () {
    test('空对象不抛异常，得到空串与 0', () {
      final s = ChatTurnSchedule.fromJson(const {});

      expect(s.id, '');
      expect(s.runCount, 0);
      expect(s.maxRuns, 0);
      expect(s.enabled, isFalse);
      expect(s.nextRunAt, isNull);
      expect(s.createdAt, isNull);
    });

    test('run_count 是 double / 字符串数字也能解析', () {
      final s = ChatTurnSchedule.fromJson({'run_count': 3.0, 'max_runs': '7'});

      expect(s.runCount, 3);
      expect(s.maxRuns, 7);
    });

    test('enabled 非 bool → false（不把 "false" 字符串当真）', () {
      expect(ChatTurnSchedule.fromJson({'enabled': 'true'}).enabled, isFalse);
    });
  });
}
