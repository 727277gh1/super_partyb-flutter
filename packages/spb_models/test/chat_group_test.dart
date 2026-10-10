import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// [ChatGroup] 的 metadata / goal 只读 getter 契约测试。
///
/// ## 这个测试防的是什么
///
/// 这些 getter 把「服务端 metadata 的删除语义」翻译成界面状态，而**键缺失**
/// 与**键为 false** 在界面上是同一个结果、在 metadata 里却是两种形态：
///
/// - `follow_up_suggest`：关闭时服务端**删键**（`chat_ext.go:314`）；
/// - `tts`：`enabled: false` 时服务端**整块删除** `metadata.tts`（`chat_ext.go:383`）；
///   子开关关闭时删各自的键（`narrate_thinking` / `file_summary`）；
/// - `goal_gate`：接管判定是 `enabled && continue_until_done`（服务端
///   `GoalGateConfig.CanTakeOver()`），只看 `enabled` 会谎报已接管。
///
/// 还有一类「手工写坏的 metadata」：`tts: false`（非对象）、
/// `narration_mode: 'weird'`（未知值）。服务端读取时会 clamp / 归一，客户端若
/// 不归一就会出现「界面显示 summary、服务端按 filler 播报」的偏差。
void main() {
  ChatGroup mkGroup({
    String? goal,
    Map<String, dynamic>? metadata,
    Map<String, dynamic>? currentGoal,
  }) => ChatGroup.fromJson({
    'id': 'grp_1',
    'user_id': 'usr_1',
    'title': '某个对话',
    'status': 'active',
    'goal': goal,
    'metadata': metadata,
    'current_goal': currentGoal,
    'created_at': '2024-03-05T08:00:00Z',
    'updated_at': '2024-03-05T08:09:10Z',
  });

  /// `goalSnapshotDTO`（`group_goal_snapshot.go`）的形状。
  Map<String, dynamic> snapshot(String text, {String status = 'active'}) => {
    'goal': {
      'id': 'goal_1',
      'group_id': 'grp_1',
      'goal_text': text,
      'status': status,
      'tasks_source': 'manual',
    },
    'tasks': <dynamic>[],
    'progress': <String, dynamic>{},
  };

  group('currentGoalText：结构化 goal 优先，旧列兜底', () {
    test('有结构化 goal 时取它（忽略 group.goal 旧列）', () {
      // 迁移 0022 后 group.goal 不再被写入，但存量 group 可能还留着旧文本。
      final g = mkGroup(goal: '旧列文本', currentGoal: snapshot('结构化文本'));
      expect(g.currentGoalText, '结构化文本');
    });

    test('无结构化 goal 时回退到 group.goal 旧列', () {
      expect(mkGroup(goal: '旧列文本').currentGoalText, '旧列文本');
    });

    test('两者都没有时是空串（不是 null）', () {
      expect(mkGroup().currentGoalText, '');
    });

    test('结构化 goal 为空串时也回退旧列', () {
      // 「有 goal 行但文本被清空」的异常状态：回退比显示空更好。
      final g = mkGroup(goal: '旧列文本', currentGoal: snapshot('   '));
      expect(g.currentGoalText, '旧列文本');
    });

    test('current_goal 为 null 时不抛异常', () {
      expect(mkGroup(goal: 'x', currentGoal: null).currentGoalText, 'x');
    });

    test('goal 快照结构不对（goal 不是对象）时不抛异常', () {
      final g = mkGroup(currentGoal: {'goal': 'oops'});
      expect(g.currentGoalText, '');
    });
  });

  group('goalGateEnabled：enabled && continue_until_done', () {
    test('键缺失 = 关闭', () {
      expect(mkGroup().goalGateEnabled, isFalse);
    });

    test('只有 enabled 时不算接管（服务端 CanTakeOver 取与）', () {
      final g = mkGroup(
        metadata: {
          'goal_gate': {'enabled': true},
        },
      );
      expect(g.goalGateEnabled, isFalse);
    });

    test('enabled + continue_until_done 才算接管', () {
      final g = mkGroup(
        metadata: {
          'goal_gate': {'enabled': true, 'continue_until_done': true},
        },
      );
      expect(g.goalGateEnabled, isTrue);
    });

    test('显式 false 与键缺失同结果', () {
      final g = mkGroup(
        metadata: {
          'goal_gate': {'enabled': false, 'continue_until_done': false},
        },
      );
      expect(g.goalGateEnabled, isFalse);
    });

    test('goal_gate 不是对象时不抛异常（视为关闭）', () {
      expect(mkGroup(metadata: {'goal_gate': false}).goalGateEnabled, isFalse);
    });
  });

  group('goalGateMaxAutoTurns：缺失取服务端默认 20', () {
    test('键缺失时返回 20（服务端 clampAnyInt 的默认值）', () {
      // 返回 null 会让面板显示空白，而「当前生效值」就是 20。
      expect(mkGroup().goalGateMaxAutoTurns, 20);
    });

    test('读取配置值', () {
      final g = mkGroup(
        metadata: {
          'goal_gate': {'max_auto_turns': 50},
        },
      );
      expect(g.goalGateMaxAutoTurns, 50);
    });

    test('越界值 clamp 到 1..200（与服务端读取口径一致）', () {
      expect(
        mkGroup(
          metadata: {
            'goal_gate': {'max_auto_turns': 999},
          },
        ).goalGateMaxAutoTurns,
        200,
      );
      expect(
        mkGroup(
          metadata: {
            'goal_gate': {'max_auto_turns': 0},
          },
        ).goalGateMaxAutoTurns,
        1,
      );
    });

    test('非数字值按默认值处理', () {
      final g = mkGroup(
        metadata: {
          'goal_gate': {'max_auto_turns': 'many'},
        },
      );
      expect(g.goalGateMaxAutoTurns, 20);
    });
  });

  group('followUpSuggestEnabled', () {
    test('键缺失 = 关闭（服务端关闭时删键）', () {
      expect(mkGroup().followUpSuggestEnabled, isFalse);
    });

    test('enabled: true 时为开启', () {
      final g = mkGroup(
        metadata: {
          'follow_up_suggest': {'enabled': true},
        },
      );
      expect(g.followUpSuggestEnabled, isTrue);
    });

    test('子对象结构不对时不抛异常', () {
      expect(
        mkGroup(metadata: {'follow_up_suggest': true}).followUpSuggestEnabled,
        isFalse,
      );
    });
  });

  group('TTS：键缺失 = 关闭，子开关随总开关归零', () {
    test('metadata 无 tts 时全部关闭', () {
      final g = mkGroup();
      expect(g.ttsEnabled, isFalse);
      expect(g.ttsNarrateThinking, isFalse);
      expect(g.ttsFileSummary, isFalse);
      expect(g.ttsNarrationMode, 'filler');
    });

    test('总开关开启时读出各子开关', () {
      final g = mkGroup(
        metadata: {
          'tts': {
            'enabled': true,
            'narrate_thinking': true,
            'narration_mode': 'summary',
            'file_summary': true,
          },
        },
      );
      expect(g.ttsEnabled, isTrue);
      expect(g.ttsNarrateThinking, isTrue);
      expect(g.ttsFileSummary, isTrue);
      expect(g.ttsNarrationMode, 'summary');
    });

    test('总开关关闭时子开关恒为 false（即便 metadata 残留旧键）', () {
      // 历史上先开子开关、后关总开关会留下这种残留。若如实读出 true，
      // 面板会在「语音回复已关闭」的状态下显示一个勾选的子开关。
      final g = mkGroup(
        metadata: {
          'tts': {
            'narrate_thinking': true,
            'narration_mode': 'summary',
            'file_summary': true,
          },
        },
      );
      expect(g.ttsEnabled, isFalse);
      expect(g.ttsNarrateThinking, isFalse);
      expect(g.ttsFileSummary, isFalse);
      // 模式也归一到默认值，避免「关闭状态下显示中文摘要」。
      expect(g.ttsNarrationMode, 'filler');
    });

    test('enabled: false 显式写出时同样全部关闭', () {
      final g = mkGroup(
        metadata: {
          'tts': {'enabled': false, 'narrate_thinking': true},
        },
      );
      expect(g.ttsEnabled, isFalse);
      expect(g.ttsNarrateThinking, isFalse);
    });

    test('未知 narration_mode 归一为 filler（与服务端 setTTS 一致）', () {
      final g = mkGroup(
        metadata: {
          'tts': {
            'enabled': true,
            'narrate_thinking': true,
            'narration_mode': 'weird',
          },
        },
      );
      expect(g.ttsNarrationMode, 'filler');
    });

    test('tts 不是对象时不抛异常（视为关闭）', () {
      expect(mkGroup(metadata: {'tts': false}).ttsEnabled, isFalse);
    });
  });

  group('容错：metadata 整体异常', () {
    test('metadata 为 null 时所有 getter 走「未配置」路径', () {
      final g = mkGroup(metadata: null);
      expect(g.followUpSuggestEnabled, isFalse);
      expect(g.goalGateEnabled, isFalse);
      expect(g.goalGateMaxAutoTurns, 20);
      expect(g.ttsEnabled, isFalse);
    });

    test('metadata 不是对象时不抛异常', () {
      final g = ChatGroup.fromJson({
        'id': 'g',
        'metadata': 'oops',
        'created_at': '2024-03-05T08:00:00Z',
        'updated_at': '2024-03-05T08:00:00Z',
      });
      expect(g.metadata, isNull);
      expect(g.ttsEnabled, isFalse);
      expect(g.goalGateMaxAutoTurns, 20);
    });
  });

  group('ChatGroup.toJson（本地缓存 round-trip，issue #26）', () {
    /// 断言 round-trip 后**关键字段**一致。
    ///
    /// 不能只比 `id`：`metadata` / `active_session` / `current_goal` 是嵌套结构，
    /// 键名不对称时它们会**静默变 null**（`fromJson` 对缺失键给默认值，不抛）。
    /// 而 `ChatGroup` 的关键 getter（`currentGoalText` / `goalGateEnabled` /
    /// `ttsEnabled`）正是读这些字段——缓存写坏会让界面显示假的「无 goal / 全部关闭」。
    void expectSameKeyFields(ChatGroup a, ChatGroup b) {
      expect(b.id, a.id);
      expect(b.userId, a.userId);
      expect(b.title, a.title);
      expect(b.status, a.status);
      expect(b.goal, a.goal);
      expect(b.metadata, a.metadata);
      expect(b.currentGoal, a.currentGoal);
      expect(b.createdAt, a.createdAt);
      expect(b.updatedAt, a.updatedAt);
      // 嵌套对象：比字段而不是比引用。
      expect(b.activeSession?.agentId, a.activeSession?.agentId);
      expect(b.activeSession?.sessionId, a.activeSession?.sessionId);
      expect(b.activeSession?.agentSessionId, a.activeSession?.agentSessionId);
      expect(b.activeSession?.role, a.activeSession?.role);
      expect(b.activeSession?.joinedAt, a.activeSession?.joinedAt);
    }

    test('全字段 round-trip：fromJson(toJson()) 关键字段全等', () {
      final original = ChatGroup.fromJson({
        'id': 'grp_1',
        'user_id': 'usr_1',
        'title': '某个对话',
        'status': 'active',
        'goal': '旧列目标',
        'metadata': {
          'tts': {'enabled': true, 'narration_mode': 'summary'},
          'goal_gate': {'enabled': true, 'continue_until_done': true},
        },
        'active_session': {
          'agent_id': 'agt_1',
          'session_id': 'ses_1',
          'agent_session_id': 'pigo_1',
          'role': 'primary',
          'joined_at': '2024-03-05T08:01:00Z',
        },
        'current_goal': snapshot('结构化目标'),
        'created_at': '2024-03-05T08:00:00Z',
        'updated_at': '2024-03-05T08:09:10Z',
      });

      final back = ChatGroup.fromJson(original.toJson());
      expectSameKeyFields(original, back);

      // getter 层也必须一致——这是「缓存写坏」在界面上的真实表现。
      expect(back.ttsEnabled, original.ttsEnabled);
      expect(back.ttsNarrationMode, original.ttsNarrationMode);
      expect(back.goalGateEnabled, original.goalGateEnabled);
      expect(back.currentGoalText, original.currentGoalText);
    });

    test('可选字段为 null 时不写键，读回仍是 null（不变成空串）', () {
      final original = ChatGroup.fromJson({
        'id': 'grp_2',
        'user_id': 'usr_1',
        'title': 't',
        'status': 'archived',
        'created_at': '2024-03-05T08:00:00Z',
        'updated_at': '2024-03-05T08:00:00Z',
      });

      final json = original.toJson();
      // 不能写出 `goal: null` 这类键：`fromJson` 里 `json['goal'] as String?`
      // 对 null 没问题，但多写无意义的键会让缓存行体积无谓变大。
      expect(json.containsKey('goal'), isFalse);
      expect(json.containsKey('metadata'), isFalse);
      expect(json.containsKey('active_session'), isFalse);
      expect(json.containsKey('current_goal'), isFalse);

      final back = ChatGroup.fromJson(json);
      expectSameKeyFields(original, back);
      expect(back.activeSession, isNull);
    });

    test('active_session 的 agent_id 为空时读回 null（与 maybeFromJson 一致）', () {
      // maybeFromJson 对空 agent_id 返回 null。toJson 不该把它写成一个
      // 「有 active_session 键但 agent_id 空」的半残对象——那种行读回是 null，
      // 但缓存里存着一块废数据。
      final original = ChatGroup.fromJson({
        'id': 'grp_3',
        'user_id': 'usr_1',
        'title': 't',
        'status': 'active',
        'active_session': {'agent_id': ''},
        'created_at': '2024-03-05T08:00:00Z',
        'updated_at': '2024-03-05T08:00:00Z',
      });
      expect(original.activeSession, isNull);
      final back = ChatGroup.fromJson(original.toJson());
      expect(back.activeSession, isNull);
    });

    test('键名是 snake_case（服务端形态），不是 camelCase', () {
      // 这条守着「toJson 与 fromJson 逐字对称」：若有人把 toJson 写成
      // `userId` / `createdAt`，fromJson 读不到（它只认 snake_case），
      // 缓存 round-trip 会静默丢字段。
      final json = mkGroup().toJson();
      expect(json.keys, contains('user_id'));
      expect(json.keys, contains('created_at'));
      expect(json.keys, contains('updated_at'));
      expect(json.keys, isNot(contains('userId')));
      expect(json.keys, isNot(contains('createdAt')));
    });
  });
}
