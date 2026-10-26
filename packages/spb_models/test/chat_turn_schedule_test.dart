import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// [ChatTurnSchedule] 的解析测试（issue #13）。
///
/// ## 这个测试防的是什么
///
/// 契约与客户端**默认直觉不一致**，且三种不一致都**不会报错**，只会静默
/// 解析成空值：
///
/// 1. 字段名是 **camelCase**（`runCount`），而 webapp 的 TS 类型是 snake_case
///    ——照抄 webapp 会得到 `runCount == 0`；
/// 2. `triggerStatus` / `lastErrorJson` 是 Go `sql.NullString`，JSON 形态是
///    `{"String":…,"Valid":…}` 嵌套对象——直接当 String 读会落空；
/// 3. `nextRunAt` / `lastRunAt` 是 Go `sql.NullTime`，JSON 形态是
///    `{"Time":…,"Valid":…}`——`DateTime.tryParse` 拿不到值，且 `Valid:false`
///    时 `Time` 是零值 `0001-01-01`，不管它 UI 会显示「公元 1 年」。
///
/// 故这里显式断言「用 snake_case 键解析会得到 0」与「嵌套 NullTime 被正确
/// 归一」，把两个陷阱钉成可执行的回归。
void main() {
  /// Go `ChatTurnSchedule` 的真实 JSON 形状（sqlc camelCase tag）。
  Map<String, dynamic> shape({
    String id = 'sch_01HZ',
    String agentId = 'agt_1',
    String policyJson = '{"meta":{"user_id":"usr_1","group_id":"grp_1","parent_turn_id":"t_1"}}',
    bool enabled = true,
    int runCount = 0,
    int maxRuns = 5,
    Object? triggerStatus = const {'String': 'pending', 'Valid': true},
    Object? nextRunAt = const {'Time': '2026-10-04T09:00:00Z', 'Valid': true},
    Object? lastRunAt = const {'Time': '0001-01-01T00:00:00Z', 'Valid': false},
    Object? lastErrorJson,
  }) => {
    'id': id,
    'agentId': agentId,
    'sessionId': 'sess_1',
    'agentType': 'pigo',
    'triggerReason': 'goal_gate',
    'triggerStatus': triggerStatus,
    'message': '继续推进目标',
    'policyJson': policyJson,
    'dedupeKey': 'goal_gate:grp_1:t_1',
    'enabled': enabled,
    'runCount': runCount,
    'maxRuns': maxRuns,
    'nextRunAt': nextRunAt,
    'lastRunAt': lastRunAt,
    'lastErrorJson': lastErrorJson,
    'createdAt': '2026-10-04T08:00:00Z',
    'updatedAt': '2026-10-04T08:30:00Z',
  };

  group('ChatTurnSchedule.fromJson：camelCase 契约', () {
    test('全部字段按 camelCase 键名解析', () {
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
      expect(s.createdAt.toUtc(), DateTime.utc(2026, 10, 4, 8));
      expect(s.updatedAt.toUtc(), DateTime.utc(2026, 10, 4, 8, 30));
    });

    test('⚠️ snake_case 键（照抄 webapp TS 类型）会静默落空', () {
      final s = ChatTurnSchedule.fromJson({
        'id': 'sch_1',
        'agent_id': 'agt_1',
        'run_count': 3,
        'max_runs': 5,
        'enabled': true,
      });

      // 这正是照抄 webapp 类型的后果：不报错，只是全空。
      expect(s.agentId, '');
      expect(s.runCount, 0);
      expect(s.maxRuns, 0);
    });
  });

  group('sql.NullString 归一（triggerStatus / lastErrorJson）', () {
    test('{"String":..,"Valid":true} → 取到字符串', () {
      final s = ChatTurnSchedule.fromJson(shape());

      expect(s.triggerStatus, 'pending');
    });

    test('Valid:false → null（不是空串，也不是那个 Map）', () {
      final s = ChatTurnSchedule.fromJson(
        shape(triggerStatus: const {'String': 'pending', 'Valid': false}),
      );

      expect(s.triggerStatus, isNull);
    });

    test('裸串形态也接受（服务端若改用自定义 MarshalJSON 仍可解析）', () {
      final s = ChatTurnSchedule.fromJson(shape(triggerStatus: 'triggered'));

      expect(s.triggerStatus, 'triggered');
    });

    test('null → null', () {
      final s = ChatTurnSchedule.fromJson(shape(triggerStatus: null));

      expect(s.triggerStatus, isNull);
    });

    test('lastErrorJson 同样是 NullString', () {
      final s = ChatTurnSchedule.fromJson(
        shape(
          lastErrorJson: const {'String': '{"error":"boom"}', 'Valid': true},
        ),
      );

      expect(s.lastErrorJson, '{"error":"boom"}');
    });
  });

  group('sql.NullTime 归一（nextRunAt / lastRunAt）', () {
    test('{"Time":..,"Valid":true} → 解析出 DateTime', () {
      final s = ChatTurnSchedule.fromJson(shape());

      expect(s.nextRunAt?.toUtc(), DateTime.utc(2026, 10, 4, 9));
    });

    test('⚠️ Valid:false 的零值 → null（不能显示「公元 1 年」）', () {
      final s = ChatTurnSchedule.fromJson(shape());

      expect(s.lastRunAt, isNull);
    });

    test('Valid:true 但 Time 是零值 → 也视为 null', () {
      final s = ChatTurnSchedule.fromJson(
        shape(nextRunAt: const {'Time': '0001-01-01T00:00:00Z', 'Valid': true}),
      );

      expect(s.nextRunAt, isNull);
    });

    test('裸 RFC3339 串也接受', () {
      final s = ChatTurnSchedule.fromJson(
        shape(nextRunAt: '2026-10-04T09:00:00Z'),
      );

      expect(s.nextRunAt?.toUtc(), DateTime.utc(2026, 10, 4, 9));
    });

    test('null → null', () {
      final s = ChatTurnSchedule.fromJson(
        shape(nextRunAt: null, lastRunAt: null),
      );

      expect(s.nextRunAt, isNull);
      expect(s.lastRunAt, isNull);
    });
  });

  group('groupId：从 policyJson.meta.group_id 解析', () {
    test('标准形状取到 group_id', () {
      final s = ChatTurnSchedule.fromJson(shape());

      expect(s.groupId, 'grp_1');
    });

    test('camelCase 变体 groupId 也接受', () {
      final s = ChatTurnSchedule.fromJson(
        shape(policyJson: '{"meta":{"groupId":"grp_2"}}'),
      );

      expect(s.groupId, 'grp_2');
    });

    test('非法 JSON → null（不抛异常）', () {
      final s = ChatTurnSchedule.fromJson(shape(policyJson: 'not json'));

      expect(s.groupId, isNull);
    });

    test('缺 meta / 缺 group_id → null', () {
      expect(
        ChatTurnSchedule.fromJson(shape(policyJson: '{"other":1}')).groupId,
        isNull,
      );
      expect(
        ChatTurnSchedule.fromJson(shape(policyJson: '{"meta":{}}')).groupId,
        isNull,
      );
    });

    test('policyJson 为空串 → null', () {
      expect(ChatTurnSchedule.fromJson(shape(policyJson: '')).groupId, isNull);
    });

    test('chatScheduleGroupIdFromPolicy 直接调用（字符串输入）', () {
      expect(chatScheduleGroupIdFromPolicy('{"meta":{"group_id":"g"}}'), 'g');
      expect(chatScheduleGroupIdFromPolicy(null), isNull);
      expect(chatScheduleGroupIdFromPolicy('[]'), isNull);
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
    });

    test('runCount 是 double / 字符串数字也能解析', () {
      final s = ChatTurnSchedule.fromJson({'runCount': 3.0, 'maxRuns': '7'});

      expect(s.runCount, 3);
      expect(s.maxRuns, 7);
    });

    test('enabled 非 bool → false（不把 "false" 字符串当真）', () {
      expect(ChatTurnSchedule.fromJson({'enabled': 'true'}).enabled, isFalse);
    });
  });
}
