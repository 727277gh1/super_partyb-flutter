import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 用户记忆（`/api/memories`）契约测试。
///
/// ## 为什么要专门测这三个形状
///
/// 服务端 `c.JSON(gin.H{"items": filtered})` 直接序列化 sqlc 的
/// `queries.UserMemory`，于是三个「看起来是字符串」的字段实际是对象：
///
/// | 字段 | Go 类型 | 实际 JSON |
/// |---|---|---|
/// | `contentJson` / `sourceGroupId` / `sourceTurnId` | `sql.NullString` | `{"String":"x","Valid":true}` |
/// | `lastReinforcedAt` | `sql.NullTime` | `{"Time":"…","Valid":true}` |
///
/// 直接当裸串读会拿到 `Map`（`toString()` 成 `{String: x, Valid: true}`），
/// 或者在 `DateTime.tryParse` 上失败 → 界面显示「从未强化」而实际有值。
/// 另有一份 snake_case 形状（webapp / 小程序的类型声明），故 `fromJson` 双读。
void main() {
  group('UserMemory.fromJson：camelCase（/api/memories 真实形状）', () {
    test('完整一行', () {
      final json = {
        'id': 'mem_1',
        'userId': 'usr_1',
        'category': 'preference',
        'topicKey': 'reply-language',
        'topicId': 'topic_9',
        'content': '用户偏好中文回复',
        'contentJson': {'String': '{}', 'Valid': true},
        'sourceGroupId': {'String': 'grp_1', 'Valid': true},
        'sourceTurnId': {'String': 'turn_2', 'Valid': true},
        'confidence': 0.8,
        'learnedFromTurns': 3,
        'status': 'active',
        'lastReinforcedAt': {'Time': '2026-11-20T10:00:00Z', 'Valid': true},
        'createdAt': '2026-11-01T08:00:00Z',
        'updatedAt': '2026-11-20T10:00:00Z',
      };

      final m = UserMemory.fromJson(json);

      expect(m.id, 'mem_1');
      expect(m.userId, 'usr_1');
      expect(m.category, UserMemoryCategory.preference);
      expect(m.topicKey, 'reply-language');
      expect(m.topicId, 'topic_9');
      expect(m.content, '用户偏好中文回复');
      expect(m.contentJson, '{}');
      expect(m.sourceGroupId, 'grp_1');
      expect(m.sourceTurnId, 'turn_2');
      expect(m.confidence, 0.8);
      expect(m.learnedFromTurns, 3);
      expect(m.status, UserMemoryStatus.active);
      expect(m.isActive, isTrue);
      expect(m.lastReinforcedAt, isNotNull);
      expect(m.lastReinforcedAt!.toUtc().year, 2026);
      expect(m.createdAt, isNotNull);
      expect(m.updatedAt, isNotNull);
    });

    test('sqll NullString / NullTime 的 Valid:false 必须归一成 null', () {
      final m = UserMemory.fromJson({
        'id': 'mem_2',
        'category': 'fact',
        'content': '用户住在杭州',
        'contentJson': {'String': '', 'Valid': false},
        'sourceGroupId': {'String': '', 'Valid': false},
        'sourceTurnId': {'String': '', 'Valid': false},
        'confidence': 0.5,
        'learnedFromTurns': 1,
        'status': 'active',
        'lastReinforcedAt': {'Time': '0001-01-01T00:00:00Z', 'Valid': false},
      });

      expect(m.contentJson, '');
      expect(m.sourceGroupId, isNull);
      expect(m.sourceTurnId, isNull);
      expect(m.hasSource, isFalse);
      // Valid:false 若被解析成时间会得到零值 → 界面显示「1970 年前强化」。
      expect(m.lastReinforcedAt, isNull);
    });

    test('NullTime 的零值即使 Valid:true 也当作无值', () {
      // SQLite NULL 被 Go 读成零值时间再写回时的残留形态。
      final m = UserMemory.fromJson({
        'id': 'mem_3',
        'content': 'x',
        'lastReinforcedAt': {'Time': '0001-01-01T00:00:00Z', 'Valid': true},
      });
      expect(m.lastReinforcedAt, isNull);
    });

    test('未知 category / status 不崩，落到 unknown 并可原样回写', () {
      final m = UserMemory.fromJson({
        'id': 'mem_4',
        'content': 'x',
        'category': 'brand_new_category',
        'status': 'brand_new_status',
      });
      expect(m.category, UserMemoryCategory.unknown);
      expect(m.status, UserMemoryStatus.unknown);
      // raw 保留未知字段，便于排障（服务端将来加分类时不会静默丢失）。
      expect(m.raw['category'], 'brand_new_category');
    });
  });

  group('UserMemory.fromJson：snake_case（webapp / 小程序形状）', () {
    test('同一条记忆的另一种写法解析结果一致', () {
      final m = UserMemory.fromJson({
        'id': 'mem_5',
        'user_id': 'usr_5',
        'category': 'goal',
        'topic_key': 'weekly-report',
        'topic_id': 'topic_5',
        'content': '用户想要每周出一份周报',
        'content_json': '{}',
        'source_group_id': 'grp_5',
        'source_turn_id': 'turn_5',
        'confidence': 0.9,
        'learned_from_turns': 4,
        'status': 'archived',
        'last_reinforced_at': '2026-11-20T10:00:00Z',
        'created_at': '2026-11-01T08:00:00Z',
        'updated_at': '2026-11-20T10:00:00Z',
      });

      expect(m.userId, 'usr_5');
      expect(m.topicKey, 'weekly-report');
      expect(m.sourceGroupId, 'grp_5');
      expect(m.confidence, 0.9);
      expect(m.learnedFromTurns, 4);
      expect(m.status, UserMemoryStatus.archived);
      expect(m.isActive, isFalse);
      expect(m.lastReinforcedAt, isNotNull);
    });

    test('裸串时间（domain.ISO 形状）也能解析', () {
      final m = UserMemory.fromJson({
        'id': 'mem_6',
        'content': 'x',
        'created_at': '2026-10-01T00:00:00Z',
      });
      expect(m.createdAt, isNotNull);
    });
  });

  test('copyWith 只改指定字段，其余保持', () {
    final m = UserMemory.fromJson({
      'id': 'mem_7',
      'userId': 'usr_7',
      'category': 'state',
      'content': '原内容',
      'status': 'active',
      'confidence': 0.7,
    });
    final updated = m.copyWith(status: UserMemoryStatus.archived);

    expect(updated.content, '原内容');
    expect(updated.category, UserMemoryCategory.state);
    expect(updated.confidence, 0.7);
    expect(updated.status, UserMemoryStatus.archived);
    expect(updated.id, m.id);
  });

  test('枚举 wire 值与文末 label', () {
    expect(UserMemoryCategory.preference.wire, 'preference');
    expect(UserMemoryCategory.preference.label, '偏好');
    expect(UserMemoryStatus.active.wire, 'active');
    expect(UserMemoryStatus.from('dismissed'), UserMemoryStatus.dismissed);
    expect(UserMemoryCategory.from(null), UserMemoryCategory.unknown);
  });
}
